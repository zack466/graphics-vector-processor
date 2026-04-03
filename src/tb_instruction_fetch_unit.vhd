library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_instruction_fetch_unit is
end entity tb_instruction_fetch_unit;

architecture sim of tb_instruction_fetch_unit is

    constant CLK_PERIOD : time := 10 ns;

    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    
    signal imem_addr      : std_logic_vector(15 downto 0);
    signal imem_data      : word_t := x"12345678"; -- Dummy Instruction
    signal imem_valid     : std_logic := '1';
    signal stall          : std_logic := '0';
    
    signal pc_ctrl        : pc_ctrl_t;
    signal predicate_mask : std_logic_vector(31 downto 0) := (others => '1');
    
    signal inst_out       : word_t;
    signal exec_mask_out  : std_logic_vector(31 downto 0);
    signal fetch_valid    : std_logic;

    -- Helper procedure to create a default pc_ctrl
    procedure reset_pc_ctrl(signal ctrl : out pc_ctrl_t) is
    begin
        ctrl.branch_type   <= BR_NONE;
        ctrl.target_addr   <= (others => '0');
        ctrl.predicate_sel <= "00";
        ctrl.predicate_mod <= PRED_MOD_ANY;
    end procedure;

begin

    clk_process: process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    uut: entity work.instruction_fetch_unit
        port map (
            clk => clk, reset => reset,
            imem_addr => imem_addr, imem_data => imem_data, imem_valid => imem_valid,
            stall => stall, pc_ctrl => pc_ctrl, predicate_mask => predicate_mask,
            instruction_out => inst_out, exec_mask_out => exec_mask_out, fetch_valid => fetch_valid
        );

    -- ========================================================================
    -- CYCLE-BY-CYCLE TEXT MONITOR
    -- ========================================================================
    monitor_proc: process(clk)
        variable action : string(1 to 20);
    begin
        if falling_edge(clk) and reset = '0' then
            -- Determine the action being evaluated for the NEXT rising edge
            if pc_ctrl.branch_type = BR_JMP then
                action := "JMP Taken           ";
            elsif pc_ctrl.branch_type = BR_BRA_Z then
                if predicate_mask = x"00000000" then action := "BRA_Z (Taken)       ";
                else action := "BRA_Z (Not Taken)   "; end if;
            elsif pc_ctrl.branch_type = BR_BRA_NZ then
                if predicate_mask = x"00000000" then action := "BRA_NZ (Not Taken)  ";
                else action := "BRA_NZ (Taken)      "; end if;
            elsif pc_ctrl.branch_type = BR_BRA_DIV then
                action := "BRA_DIV (Diverge)   ";
            elsif pc_ctrl.branch_type = BR_SSY then
                action := "SSY (Set Sync PC)   ";
            elsif pc_ctrl.branch_type = BR_SYNC then
                action := "SYNC (Pop Stack)    ";
            else
                action := "Increment PC        ";
            end if;

            -- Print the current steady-state of the cycle
            report "[CYCLE] PC: 0x" & to_hstring(imem_addr) & 
                   " | ExecMask: 0x" & to_hstring(exec_mask_out) & 
                   " | Action: " & action;
        end if;
    end process;

    -- ========================================================================
    -- MAIN STIMULUS PROCESS
    -- ========================================================================
    stim_proc: process
    begin
        reset_pc_ctrl(pc_ctrl);
        
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- TEST 1: Unconditional Jump
        -- ====================================================================
        report ">> TEST 1: Unconditional Jump";
        pc_ctrl.branch_type <= BR_JMP;
        pc_ctrl.target_addr <= x"00A0";
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        
        wait until falling_edge(clk);
        assert imem_addr = x"00A0" report "T1: JMP Failed!" severity error;


        -- ====================================================================
        -- TEST 2: Branch Zero (Not Taken vs Taken)
        -- ====================================================================
        report ">> TEST 2A: BRA_Z (Not Taken - Predicates are 1)";
        pc_ctrl.branch_type <= BR_BRA_Z;
        pc_ctrl.target_addr <= x"00B0";
        predicate_mask <= x"FFFFFFFF"; -- None are zero
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        wait until falling_edge(clk);
        assert imem_addr = x"00A1" report "T2A: BRA_Z improperly taken!" severity error;

        wait until rising_edge(clk); -- advance clock

        report ">> TEST 2B: BRA_Z (Taken - Predicates are 0)";
        pc_ctrl.branch_type <= BR_BRA_Z;
        pc_ctrl.target_addr <= x"00C0";
        predicate_mask <= x"00000000"; -- All are zero
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        wait until falling_edge(clk);
        assert imem_addr = x"00C0" report "T2B: BRA_Z failed to take branch!" severity error;


        -- ====================================================================
        -- TEST 3: Branch Not Zero (Not Taken vs Taken)
        -- ====================================================================
        report ">> TEST 3A: BRA_NZ (Not Taken - Predicates are 0)";
        pc_ctrl.branch_type <= BR_BRA_NZ;
        pc_ctrl.target_addr <= x"00D0";
        predicate_mask <= x"00000000"; -- None are 1
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        wait until falling_edge(clk);
        assert imem_addr = x"00C1" report "T3A: BRA_NZ improperly taken!" severity error;

        wait until rising_edge(clk);

        report ">> TEST 3B: BRA_NZ (Taken - Predicates contain 1s)";
        pc_ctrl.branch_type <= BR_BRA_NZ;
        pc_ctrl.target_addr <= x"00E0";
        predicate_mask <= x"F0000000"; -- Some are 1
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        wait until falling_edge(clk);
        assert imem_addr = x"00E0" report "T3B: BRA_NZ failed to take branch!" severity error;


        -- ====================================================================
        -- TEST 4: Full SIMT Divergence & Reconvergence Stack
        -- ====================================================================
        report ">> TEST 4A: SSY (Set Sync Reconvergence Point to 0x0200)";
        pc_ctrl.branch_type <= BR_SSY;
        pc_ctrl.target_addr <= x"0200";
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);

        wait until rising_edge(clk);

        report ">> TEST 4B: BRA_DIV (Divergent Branch to 0x0100)";
        pc_ctrl.branch_type <= BR_BRA_DIV;
        pc_ctrl.target_addr <= x"0100";
        predicate_mask <= x"FFFF0000"; -- Top half taken, bottom half deferred
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        
        wait until falling_edge(clk);
        -- Check Stage 0 (Address)
        assert imem_addr = x"0100" report "T4B: Divergent PC jump failed!" severity error;
        
        -- Let pipeline advance 1 cycle
        wait until rising_edge(clk);
        wait until falling_edge(clk);
        -- Check Stage 1 (Mask)
        assert exec_mask_out = x"FFFF0000" report "T4B: Active mask not updated!" severity error;


        report ">> TEST 4C: SYNC (End of IF Block - Swap to Deferred ELSE block)";
        pc_ctrl.branch_type <= BR_SYNC;
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        
        wait until falling_edge(clk);
        -- Check Stage 0 (Address)
        assert imem_addr = x"00E3" report "T4C: Failed to jump to Deferred PC!" severity error;
        
        -- Let pipeline advance 1 cycle
        wait until rising_edge(clk);
        wait until falling_edge(clk);
        -- Check Stage 1 (Mask)
        assert exec_mask_out = x"0000FFFF" report "T4C: Failed to restore deferred mask!" severity error;


        report ">> TEST 4D: SYNC (End of ELSE Block - Full Warp Reconvergence)";
        pc_ctrl.branch_type <= BR_SYNC;
        wait until rising_edge(clk);
        reset_pc_ctrl(pc_ctrl);
        
        wait until falling_edge(clk);
        -- Check Stage 0 (Address)
        assert imem_addr = x"0200" report "T4D: Failed to jump to Reconvergence PC!" severity error;
        
        -- Let pipeline advance 1 cycle
        wait until rising_edge(clk);
        wait until falling_edge(clk);
        -- Check Stage 1 (Mask)
        assert exec_mask_out = x"FFFFFFFF" report "T4D: Failed to restore outer warp mask!" severity error;

        report ">> ALL INSTRUCTION FETCH TESTS PASSED!";
        std.env.stop;
    end process;

end architecture sim;
