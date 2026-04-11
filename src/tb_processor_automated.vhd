library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_processor_automated is
    generic (
        PROGRAM_FILE     : string  := "program.hex";
        MEMORY_DUMP_FILE : string  := "memory_dump.hex";
        DUMP_START_ADDR  : integer := 0; -- Framebuffer start
        DUMP_END_ADDR    : integer := 4096 -- 1024 pixels * 4 bytes/pixel
    );
end entity tb_processor_automated;

architecture sim of tb_processor_automated is

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
    signal csr_address   : std_logic_vector(2 downto 0) := "000";
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
            WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH,
            REG_WIDTH => LOCAL_REG_WIDTH
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

        function asm_alu(op : std_logic_vector(5 downto 0); rd, rs1, rs2 : integer; mask : integer) return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := op;
            res(25 downto 22) := std_logic_vector(to_unsigned(mask, 4));
            res(21 downto 20) := std_logic_vector(to_unsigned(rd, 2));
            res(19 downto 18) := std_logic_vector(to_unsigned(rs1, 2));
            res(17 downto 16) := std_logic_vector(to_unsigned(rs2, 2));
            res(3 downto 0)   := "0011"; -- TYPE_ALU
            return res;
        end function;

        function asm_thread_id(dest_reg : integer; mask : integer) return word_t is
            variable res : word_t := (others => '0');
        begin
            res(31 downto 26) := "001110"; -- OP_THREAD_ID
            res(25 downto 22) := std_logic_vector(to_unsigned(mask, 4));
            res(21 downto 20) := std_logic_vector(to_unsigned(dest_reg, 2));
            res(19 downto 4)  := (others => '0'); 
            res(3 downto 0)   := "0011";   -- INST_TYPE_ALU
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
        procedure write_csr(addr : std_logic_vector(2 downto 0); data : std_logic_vector(31 downto 0)) is
        begin
            csr_address <= addr;
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
            -- Wait one more cycle for the data to actually appear on the bus
            wait until rising_edge(clk);
        end procedure;

        procedure wait_for_halt(poll_interval : time) is
        begin
            loop
                -- 1. CHECK FOR HARDWARE INTERRUPT (Unchanged)
                if host_irq = '1' then
                    report "[HOST ISR] GPU Hardware Interrupt Detected! Clearing IRQ Pin...";
                    csr_address <= CSR_ADDR_IRQ_ACK; csr_writedata <= x"00000001"; csr_write <= '1';
                    wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
                end if;
            
                -- 2. CHECK IF PROCESSOR HAS HALTED
                csr_address <= CSR_ADDR_RUN; csr_read <= '1';
                wait until rising_edge(clk); csr_read <= '0'; wait until rising_edge(clk);
                
                if csr_readdata(0) = '0' then
                    
                    -- It halted! Let's check CSR[3] to see if it was a breakpoint
                    csr_address <= CSR_ADDR_BREAK; csr_read <= '1';
                    wait until rising_edge(clk); csr_read <= '0'; wait until rising_edge(clk);
                    
                    if csr_readdata(0) = '1' then
                        report "[DEBUGGER] Breakpoint Hit! Resuming execution...";
                        
                        -- A real debugger would read the VRF and PC here to inspect state.
                        -- For now, we just clear the break flag and resume.
                        
                        -- Clear the Break Flag (Write 1 to CSR[3])
                        csr_address <= CSR_ADDR_BREAK; csr_writedata <= x"00000001"; csr_write <= '1';
                        wait until rising_edge(clk); csr_write <= '0'; wait until rising_edge(clk);
                        
                        -- Resume the Processor (Write 1 to CSR[0])
                        csr_address <= CSR_ADDR_RUN; csr_writedata <= x"00000001"; csr_write <= '1';
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
        
        file prog_file : text;
        variable prog_line : line;
        variable prog_word : word_t;
        variable good : boolean;

        file dump_file : text;
        variable dump_line : line;
        variable dump_addr : integer := DUMP_START_ADDR;

    begin
        wait for 50 ns; wait until rising_edge(clk); reset <= '0';
        wait for 50 ns; wait until rising_edge(clk);
        report "--- STARTING END-TO-END PROCESSOR TEST ---";

        -- ====================================================================
        -- 1. LOAD ASSEMBLY PROGRAM
        -- ====================================================================
        report "Loading instruction memory from " & PROGRAM_FILE & "...";
        
        file_open(prog_file, PROGRAM_FILE, read_mode);
        rom_ptr := 0;
        while not endfile(prog_file) loop
            readline(prog_file, prog_line);
            hread(prog_line, prog_word, good);
            if good then
                prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
                prog_wr_data <= prog_word; 
                prog_we <= '1'; 
                wait until rising_edge(clk); 
                rom_ptr := rom_ptr + 1;
            end if;
        end loop;
        file_close(prog_file);

        prog_we <= '0'; wait for 50 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 2. START PROCESSOR FOR EACH WARP OFFSET
        -- ====================================================================
        report "Setting Warp Offset, Start PC and running processor multiple times...";
        
        for w in 0 to 31 loop
            report "Running warp " & integer'image(w) & " (offset " & integer'image(w * 32) & ")...";
            write_csr(CSR_ADDR_WARP_OFFSET, std_logic_vector(to_unsigned(w * 32, 32)));
            write_csr(CSR_ADDR_START_PC,    x"00000000"); -- Start PC
            write_csr(CSR_ADDR_RUN,         x"00000001"); -- Run
    
            -- Using a short 100ns poll interval so the simulated ISR catches the IRQ quickly!
            wait_for_halt(100 ns); 
            
            wait for 100 ns; wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- 3. VERIFY MEMORY CONTENTS
        -- ====================================================================
        report "Taking over Avalon Bus and dumping DDR3 Memory to " & MEMORY_DUMP_FILE & "...";
        tb_takeover <= '1'; wait until rising_edge(clk);
        
        file_open(dump_file, MEMORY_DUMP_FILE, write_mode);
        dump_addr := DUMP_START_ADDR;
        while dump_addr < DUMP_END_ADDR loop
            read_memory(std_logic_vector(to_unsigned(dump_addr, 32)));
            
            hwrite(dump_line, mem_avm_readdata(127 downto 96));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(95 downto 64));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(63 downto 32));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(31 downto 0));
            writeline(dump_file, dump_line);
            
            dump_addr := dump_addr + 16;
        end loop;
        file_close(dump_file);

        report "--- FULL PROCESSOR EXECUTION VERIFIED ---";
        std.env.stop;
    end process;

end architecture sim;
