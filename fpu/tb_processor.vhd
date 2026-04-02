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
    
    -- NEW: Host IRQ Pin
    signal host_irq      : std_logic;

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
            csr_writedata => csr_writedata, csr_read => csr_read, csr_readdata => csr_readdata,
            host_irq_out => host_irq -- NEW: Wire up the interrupt pin
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
    
        -- --------------------------------------------------------------------
        -- IN-TESTBENCH ASSEMBLER FUNCTIONS
        -- --------------------------------------------------------------------
        function asm_flush return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "111110"; -- OP_FLUSH
            res(3 downto 0) := "0110";     -- INST_TYPE_SYS
            return res;
        end function;

        function asm_return return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "111111"; -- OP_RETURN
            res(3 downto 0) := "0110";     -- INST_TYPE_SYS
            return res;
        end function;

        function asm_break return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "111100"; -- OP_BREAK
            res(3 downto 0) := "0110";     -- INST_TYPE_SYS
            return res;
        end function;
        
        function asm_int return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "111101"; -- OP_INT
            res(3 downto 0) := "0110";     -- INST_TYPE_SYS
            return res;
        end function;

        function asm_ldi(is_hi : boolean; dest_reg : integer; imm : std_logic_vector(15 downto 0)) return word_t is
            variable res : word_t := (others => '0');
        begin
            if is_hi then res(31 downto 26) := "000001"; else res(31 downto 26) := "000000"; end if;
            res(25 downto 10) := imm;
            res(9 downto 6)   := "1111"; 
            res(5 downto 4)   := std_logic_vector(to_unsigned(dest_reg, 2));
            res(3 downto 0)   := "0100"; 
            return res;
        end function;

        function asm_store(base : std_logic_vector(15 downto 0); off_reg : integer; src_reg : integer) return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "100001"; 
            res(25 downto 10) := base;
            res(9 downto 8)   := std_logic_vector(to_unsigned(off_reg, 2));
            res(7 downto 6)   := std_logic_vector(to_unsigned(src_reg, 2));
            res(5 downto 4)   := "00";
            res(3 downto 0)   := "0101"; 
            return res;
        end function;

        -- --------------------------------------------------------------------
        -- HELPER PROCEDURES
        -- --------------------------------------------------------------------
        procedure write_csr(addr : integer; data : std_logic_vector(31 downto 0)) is
        begin
            csr_address <= std_logic_vector(to_unsigned(addr, 2));
            csr_writedata <= data; csr_write <= '1';
            wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
        end procedure;

        procedure read_memory(addr : std_logic_vector(31 downto 0)) is
        begin
            tb_avm_address <= addr; tb_avm_read <= '1';
            wait until rising_edge(clk);
            while mem_avm_waitrequest = '1' loop wait until rising_edge(clk); end loop;
            tb_avm_read <= '0';
            while mem_avm_readdatavalid = '0' loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure wait_for_halt(poll_interval : time) is
        begin
            loop
                -- 1. CHECK FOR HARDWARE INTERRUPT (Unchanged)
                if host_irq = '1' then
                    report "[HOST ISR] GPU Hardware Interrupt Detected! Clearing IRQ Pin...";
                    csr_address <= "10"; csr_writedata <= x"00000001"; csr_write <= '1';
                    wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
                end if;
            
                -- 2. CHECK IF PROCESSOR HAS HALTED
                csr_address <= "00"; csr_read <= '1';
                wait until rising_edge(clk); csr_read <= '0'; wait until rising_edge(clk);
                
                if csr_readdata(0) = '0' then
                    
                    -- It halted! Let's check CSR[3] to see if it was a breakpoint
                    csr_address <= "11"; csr_read <= '1';
                    wait until rising_edge(clk); csr_read <= '0'; wait until rising_edge(clk);
                    
                    if csr_readdata(0) = '1' then
                        report "[DEBUGGER] Breakpoint Hit! Resuming execution...";
                        
                        -- A real debugger would read the VRF and PC here to inspect state.
                        -- For now, we just clear the break flag and resume.
                        
                        -- Clear the Break Flag (Write 1 to CSR[3])
                        csr_address <= "11"; csr_writedata <= x"00000001"; csr_write <= '1';
                        wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
                        
                        -- Resume the Processor (Write 1 to CSR[0])
                        csr_address <= "00"; csr_writedata <= x"00000001"; csr_write <= '1';
                        wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
                        
                        report "[DEBUGGER] Processor resumed.";
                        -- Do NOT exit the loop, keep polling!
                    else
                        -- It wasn't a breakpoint, so it must be a normal RETURN
                        report "[HOST] GPU execution complete (Normal Return).";
                        exit;
                    end if;
                end if;
                
                wait for poll_interval;
            end loop;
        end procedure;
        
        variable rom_ptr : integer := 0;

    begin
        wait for 50 ns; wait until rising_edge(clk); reset <= '0';
        wait for 50 ns; wait until rising_edge(clk);
        report "--- STARTING END-TO-END PROCESSOR TEST ---";

        -- ====================================================================
        -- 1. LOAD ASSEMBLY PROGRAM
        -- ====================================================================
        report "Loading instruction memory...";
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_ldi(false, 0, x"0000"); prog_we <= '1'; wait until rising_edge(clk); rom_ptr := rom_ptr + 1;
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_ldi(false, 1, x"BEEF"); wait until rising_edge(clk); rom_ptr := rom_ptr + 1;
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_flush; wait until rising_edge(clk); rom_ptr := rom_ptr + 1;

        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_ldi(true,  1, x"DEAD"); wait until rising_edge(clk); rom_ptr := rom_ptr + 1;
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_flush; wait until rising_edge(clk); rom_ptr := rom_ptr + 1;

        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_store(x"0000", 0, 1); wait until rising_edge(clk); rom_ptr := rom_ptr + 1;
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_break; wait until rising_edge(clk); rom_ptr := rom_ptr + 1;
        
        prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
        prog_wr_data <= asm_return; wait until rising_edge(clk); rom_ptr := rom_ptr + 1;

        prog_we <= '0'; wait for 50 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 2. START PROCESSOR
        -- ====================================================================
        report "Setting Start PC and running processor...";
        write_csr(1, x"00000000"); -- CSR[1] = Start PC (0)
        write_csr(0, x"00000001"); -- CSR[0] = Run (1)

        report "Waiting for processor to finish executing...";
        -- Using a short 100ns poll interval so the simulated ISR catches the IRQ quickly!
        wait_for_halt(100 ns); 
        
        wait for 100 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 3. VERIFY MEMORY CONTENTS
        -- ====================================================================
        report "Taking over Avalon Bus and checking DDR3 Memory...";
        tb_takeover <= '1'; wait until rising_edge(clk);
        
        read_memory(x"00000000");

        assert mem_avm_readdata(31 downto 0)   = x"DEADBEEF" report "Mismatch Element 0" severity error;
        assert mem_avm_readdata(63 downto 32)  = x"DEADBEEF" report "Mismatch Element 1" severity error;
        assert mem_avm_readdata(95 downto 64)  = x"DEADBEEF" report "Mismatch Element 2" severity error;
        assert mem_avm_readdata(127 downto 96) = x"DEADBEEF" report "Mismatch Element 3" severity error;

        report "--- FULL PROCESSOR EXECUTION VERIFIED ---";
        std.env.stop;
    end process;

end architecture sim;
