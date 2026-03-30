library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_instruction_issue is
end entity tb_instruction_issue;

architecture sim of tb_instruction_issue is

    signal clk             : std_logic := '0';
    signal reset           : std_logic := '1';
    
    signal fpu_ctrl_in     : fpu_ctrl_t;
    signal valid_in        : std_logic := '0';
    
    signal current_thread  : std_logic_vector(4 downto 0);
    signal opcode_out      : std_logic_vector(5 downto 0);
    signal rs1_addr_global : std_logic_vector(6 downto 0);
    signal rs2_addr_global : std_logic_vector(6 downto 0);
    signal rs3_addr_global : std_logic_vector(6 downto 0);
    signal rd_addr_global  : std_logic_vector(6 downto 0);
    signal swiz_sel_a      : swizzle_sel_t;
    signal swiz_sel_b      : swizzle_sel_t;
    signal swiz_sel_c      : swizzle_sel_t;
    signal inst_write_mask : std_logic_vector(3 downto 0);
    signal wb_mux_sel      : std_logic_vector(1 downto 0);
    signal reg_we          : std_logic;
    signal issue_valid     : std_logic;

    constant CLK_PERIOD : time := 10 ns;

begin

    uut: entity work.instruction_issue
        generic map ( THREAD_WIDTH => 5, REG_WIDTH => 2 )
        port map (
            clk => clk, reset => reset, fpu_ctrl_in => fpu_ctrl_in, valid_in => valid_in,
            current_thread => current_thread, opcode_out => opcode_out,
            rs1_addr_global => rs1_addr_global, rs2_addr_global => rs2_addr_global,
            rs3_addr_global => rs3_addr_global, rd_addr_global => rd_addr_global,
            swiz_sel_a => swiz_sel_a, swiz_sel_b => swiz_sel_b, swiz_sel_c => swiz_sel_c,
            inst_write_mask => inst_write_mask, wb_mux_sel => wb_mux_sel,
            reg_we => reg_we, issue_valid => issue_valid
        );

    clk_process : process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    stim_proc: process
    begin
        -- Default Initialization
        fpu_ctrl_in.opcode         <= OP_NOP;
        fpu_ctrl_in.rs1_addr_local <= "00";
        fpu_ctrl_in.rs2_addr_local <= "00";
        fpu_ctrl_in.rs3_addr_local <= "00";
        fpu_ctrl_in.rd_addr_local  <= "00";
        fpu_ctrl_in.swiz_sel_a     <= ("00", "00", "00", "00");
        fpu_ctrl_in.swiz_sel_b     <= ("00", "00", "00", "00");
        fpu_ctrl_in.swiz_sel_c     <= ("00", "00", "00", "00");
        fpu_ctrl_in.write_mask     <= "0000";
        fpu_ctrl_in.wb_mux_sel     <= "00";
        fpu_ctrl_in.reg_we         <= '0';
        
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- TEST 1: Full 32-Thread Issuance
        -- ====================================================================
        report ">> TEST 1: Issuing Full 32 Threads";
        
        fpu_ctrl_in.opcode         <= OP_FMADD;
        fpu_ctrl_in.rs1_addr_local <= "01";
        valid_in <= '1'; 

        for i in 0 to 31 loop
            -- 1. Verify stability safely in the middle of the clock cycle
            wait until falling_edge(clk);
            
            assert issue_valid = '1' report "issue_valid dropped early!" severity error;
            assert to_integer(unsigned(current_thread)) = i report "Thread mismatch!" severity error;
            assert rs1_addr_global = std_logic_vector(to_unsigned(i, 5)) & "01" report "Global Addr mismatch" severity error;
            assert opcode_out = OP_FMADD report "Opcode latch mismatch" severity error;

            -- 2. Wait for the next active edge
            wait until rising_edge(clk);
            
            -- 3. Modify inputs exactly on the rising edge
            if i = 0 then
                valid_in <= '0';
                
                -- Scramble the input to rigorously prove that the latch is working
                fpu_ctrl_in.opcode <= OP_NOP;
                fpu_ctrl_in.rs1_addr_local <= "00";
            end if;
        end loop;

        -- Check Cycle 32 (Should be dead/idle)
        wait until falling_edge(clk);
        assert issue_valid = '0' report "Issuer failed to stop after 32 threads!" severity error;
        wait until rising_edge(clk);
        
        
        -- ====================================================================
        -- TEST 2: Interruption Behavior
        -- ====================================================================
        report ">> TEST 2: Interruption / Restart Behavior";
        
        fpu_ctrl_in.opcode <= OP_FSUB;
        valid_in <= '1';
        
        -- Let it run for 10 cycles
        for i in 0 to 9 loop
            wait until falling_edge(clk);
            assert to_integer(unsigned(current_thread)) = i report "Interrupted thread mismatch!" severity error;
            wait until rising_edge(clk);
            if i = 0 then valid_in <= '0'; end if;
        end loop;
        
        -- Force a new valid_in right now (Overriding Thread 10)
        report "   -> Forcing Restart";
        fpu_ctrl_in.opcode <= OP_FMUL;
        valid_in <= '1';
        
        for i in 0 to 3 loop
            wait until falling_edge(clk);
            assert to_integer(unsigned(current_thread)) = i report "Restart failed!" severity error;
            assert opcode_out = OP_FMUL report "Latched opcode failed to update!" severity error;
            wait until rising_edge(clk);
            if i = 0 then valid_in <= '0'; end if;
        end loop;

        report ">> SIMULATION COMPLETE: All assertions passed synchronously!";
        std.env.stop;
    end process;

end architecture sim;
