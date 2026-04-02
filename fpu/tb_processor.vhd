library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_processor is
end entity tb_processor;

architecture sim of tb_processor is

    constant PC_WIDTH        : integer := 16;
    constant IMEM_ADDR_WIDTH : integer := 8;
    constant WARP_SIZE       : integer := 32;
    constant ADDR_WIDTH      : integer := 32;
    constant DATA_WIDTH      : integer := 128;
    constant CLK_PERIOD      : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Processor Avalon-MM Master Signals
    signal proc_avm_address       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal proc_avm_burstcount    : std_logic_vector(7 downto 0);
    signal proc_avm_write         : std_logic;
    signal proc_avm_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal proc_avm_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal proc_avm_read          : std_logic;
    
    -- Testbench Avalon-MM Master Signals (For backdoor reading)
    signal tb_takeover            : std_logic := '0';
    signal tb_avm_address         : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal tb_avm_burstcount      : std_logic_vector(7 downto 0) := "00000001";
    signal tb_avm_read            : std_logic := '0';
    
    -- Shared Memory Slave Signals
    signal mem_avm_address        : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal mem_avm_burstcount     : std_logic_vector(7 downto 0);
    signal mem_avm_write          : std_logic;
    signal mem_avm_writedata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_byteenable     : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal mem_avm_read           : std_logic;
    signal mem_avm_readdata       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_readdatavalid  : std_logic;
    signal mem_avm_waitrequest    : std_logic;

    -- Instruction Memory Programming
    signal prog_we      : std_logic := '0';
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : word_t := (others => '0');

    -- CSR Interface
    signal csr_address   : std_logic_vector(1 downto 0) := "00";
    signal csr_write     : std_logic := '0';
    signal csr_writedata : std_logic_vector(31 downto 0) := (others => '0');
    signal csr_read      : std_logic := '0';
    signal csr_readdata  : std_logic_vector(31 downto 0);

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- ========================================================================
    -- BUS MULTIPLEXER (Allows TB to read memory when processor is stopped)
    -- ========================================================================
    mem_avm_address    <= tb_avm_address    when tb_takeover = '1' else proc_avm_address;
    mem_avm_burstcount <= tb_avm_burstcount when tb_takeover = '1' else proc_avm_burstcount;
    mem_avm_write      <= '0'               when tb_takeover = '1' else proc_avm_write;
    mem_avm_writedata  <= (others => '0')   when tb_takeover = '1' else proc_avm_writedata;
    mem_avm_byteenable <= (others => '1')   when tb_takeover = '1' else proc_avm_byteenable;
    mem_avm_read       <= tb_avm_read       when tb_takeover = '1' else proc_avm_read;

    -- ========================================================================
    -- INSTANTIATIONS
    -- ========================================================================
    u_processor : entity work.processor
        generic map (
            PC_WIDTH => PC_WIDTH, IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk => clk, reset => reset,
            avm_address => proc_avm_address, avm_burstcount => proc_avm_burstcount,
            avm_write => proc_avm_write, avm_writedata => proc_avm_writedata,
            avm_byteenable => proc_avm_byteenable, avm_read => proc_avm_read,
            avm_readdata => mem_avm_readdata, avm_readdatavalid => mem_avm_readdatavalid,
            avm_waitrequest => mem_avm_waitrequest,
            prog_we => prog_we, prog_wr_addr => prog_wr_addr, prog_wr_data => prog_wr_data,
            csr_address => csr_address, csr_write => csr_write, 
            csr_writedata => csr_writedata, csr_read => csr_read, csr_readdata => csr_readdata
        );

    u_memory : entity work.avm_sim_memory
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk => clk, reset => reset,
            avs_address => mem_avm_address, avs_burstcount => mem_avm_burstcount,
            avs_write => mem_avm_write, avs_writedata => mem_avm_writedata,
            avs_byteenable => mem_avm_byteenable, avs_read => mem_avm_read,
            avs_readdata => mem_avm_readdata, avs_readdatavalid => mem_avm_readdatavalid,
            avs_waitrequest => mem_avm_waitrequest
        );

    -- ========================================================================
    -- MAIN STIMULUS PROCESS
    -- ========================================================================
    p_main : process
    
        -- Helper Procedure: Write to Processor CSR
        procedure write_csr(addr : integer; data : std_logic_vector(31 downto 0)) is
        begin
            csr_address <= std_logic_vector(to_unsigned(addr, 2));
            csr_writedata <= data;
            csr_write <= '1';
            wait until rising_edge(clk);
            csr_write <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Helper Procedure: Load instruction into ROM
        procedure load_inst(addr : integer; data : std_logic_vector(31 downto 0)) is
        begin
            prog_wr_addr <= std_logic_vector(to_unsigned(addr, IMEM_ADDR_WIDTH));
            prog_wr_data <= data;
            prog_we <= '1';
            wait until rising_edge(clk);
            prog_we <= '0';
        end procedure;

        -- Helper Procedure: Read from DDR3 via Avalon Bus
        procedure read_memory(addr : std_logic_vector(31 downto 0)) is
        begin
            tb_avm_address <= addr;
            tb_avm_read <= '1';
            wait until rising_edge(clk);
            while mem_avm_waitrequest = '1' loop
                wait until rising_edge(clk);
            end loop;
            tb_avm_read <= '0';
            while mem_avm_readdatavalid = '0' loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

    begin
        -- System Initialization
        wait for 50 ns; wait until rising_edge(clk);
        reset <= '0';
        wait for 50 ns; wait until rising_edge(clk);
        
        report "--- STARTING END-TO-END PROCESSOR TEST ---";

        -- ====================================================================
        -- 1. LOAD ASSEMBLY PROGRAM
        -- NOPs are inserted between Immediate Loads to ensure 37-cycle
        -- execution pipeline writes back before the next load relies on it.
        -- ====================================================================
        report "Loading instruction memory...";
        load_inst(0, x"000000F4"); -- LDI_LO v0, 0x0000 (Set Thread Offsets to 0)
        load_inst(1, x"00000000"); -- NOP
        load_inst(2, x"040000F4"); -- LDI_HI v0, 0x0000 
        load_inst(3, x"00000000"); -- NOP
        load_inst(4, x"02FBBFD4"); -- LDI_LO v1, 0xBEEF (Load lower half of target data)
        load_inst(5, x"00000000"); -- NOP
        load_inst(6, x"077ABFD4"); -- LDI_HI v1, 0xDEAD (Load upper half of target data)
        load_inst(7, x"00000000"); -- NOP
        load_inst(8, x"84000015"); -- STORE v1, Base: 0x0000, Offsets: v0
        load_inst(9, x"C0000901"); -- JMP 9 (Infinite Loop)
        wait for 50 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 2. START PROCESSOR
        -- ====================================================================
        report "Setting Start PC and running processor...";
        write_csr(1, x"00000000"); -- CSR[1] = Start PC (0)
        write_csr(0, x"00000001"); -- CSR[0] = Run (1)

        -- Let the processor run for enough time to execute 10 instructions 
        -- across 32 threads, plus memory simulation delays.
        wait for 8000 ns; 
        wait until rising_edge(clk);

        report "Halting processor...";
        write_csr(0, x"00000000"); -- CSR[0] = Run (0)
        wait for 100 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 3. VERIFY MEMORY CONTENTS
        -- ====================================================================
        report "Taking over Avalon Bus and checking DDR3 Memory...";
        tb_takeover <= '1';
        wait until rising_edge(clk);

        read_memory(x"00000000");

        -- Check that all 4 vector elements contain 0xDEADBEEF
        report to_hstring(mem_avm_readdata(31 downto 0));
        report to_hstring(mem_avm_readdata(63 downto 32));
        report to_hstring(mem_avm_readdata(95 downto 64));
        report to_hstring(mem_avm_readdata(127 downto 96));
        assert mem_avm_readdata(31 downto 0)   = x"DEADBEEF" report "Mismatch Element 0" severity error;
        assert mem_avm_readdata(63 downto 32)  = x"DEADBEEF" report "Mismatch Element 1" severity error;
        assert mem_avm_readdata(95 downto 64)  = x"DEADBEEF" report "Mismatch Element 2" severity error;
        assert mem_avm_readdata(127 downto 96) = x"DEADBEEF" report "Mismatch Element 3" severity error;

        report "--- FULL PROCESSOR EXECUTION VERIFIED ---";
        std.env.stop;
    end process;

end architecture sim;
