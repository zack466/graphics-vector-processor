library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use IEEE.FLOAT_PKG.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_issuer_writeback_integration is
end entity tb_issuer_writeback_integration;

architecture sim of tb_issuer_writeback_integration is

    constant CLK_PERIOD : time := 10 ns;

    -- Global Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ========================================================================
    -- STAGE 0: INSTRUCTION ISSUE (Outputs)
    -- ========================================================================
    signal fpu_ctrl_in     : fpu_ctrl_t;
    signal valid_in        : std_logic := '0';
    
    signal current_thread  : std_logic_vector(4 downto 0);
    signal iss_opcode      : std_logic_vector(5 downto 0);
    signal iss_rs1_addr    : std_logic_vector(6 downto 0);
    signal iss_rs2_addr    : std_logic_vector(6 downto 0);
    signal iss_rs3_addr    : std_logic_vector(6 downto 0);
    signal iss_rd_addr     : std_logic_vector(6 downto 0);
    signal iss_mask        : std_logic_vector(3 downto 0);
    signal iss_we          : std_logic;
    signal iss_valid       : std_logic;
    
    -- Extracted Control Signals for Predicates (Now native to Issuer)
    signal iss_cmp_invert  : std_logic;
    signal iss_cmp_swap    : std_logic;
    signal iss_prf_we      : std_logic;

    -- ========================================================================
    -- STAGE 1: REG FILE READS (1 Cycle Latency)
    -- ========================================================================
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    
    -- Delay registers to align control signals with VRF/PRF data output
    signal s1_opcode     : std_logic_vector(5 downto 0);
    signal s1_valid      : std_logic;
    signal s1_cmp_inv    : std_logic;
    signal s1_cmp_swap   : std_logic;
    
    -- Multiplexed FPU Inputs (Injects PRF data if opcode is a logic op)
    signal is_logic_op   : std_logic;
    signal op_a_x, op_b_x, op_c_x : word_t;
    signal op_a_y, op_b_y, op_c_y : word_t;
    signal op_a_z, op_b_z, op_c_z : word_t;
    signal op_a_w, op_b_w, op_c_w : word_t;

    -- ========================================================================
    -- STAGE 2: FPU LANES (FPU_MAX_LATENCY = 37 Cycles)
    -- ========================================================================
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;
    signal fpu_valid_x : std_logic; 
    
    signal vrf_wb_data : vector_t;
    signal prf_wb_data : std_logic_vector(3 downto 0);

    -- Massive delay line to carry writeback control signals alongside FPU math
    type addr_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(6 downto 0);
    type mask_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(3 downto 0);
    type we_pipe_t   is array (0 to FPU_MAX_LATENCY) of std_logic;
    
    signal s2_rd_addr_pipe : addr_pipe_t := (others => (others => '0'));
    signal s2_mask_pipe    : mask_pipe_t := (others => "0000");
    signal s2_vrf_we_pipe  : we_pipe_t   := (others => '0');
    signal s2_prf_we_pipe  : we_pipe_t   := (others => '0');

    -- ========================================================================
    -- MCU / IFU VERIFICATION PORTS
    -- ========================================================================
    signal mcu_rd_addr, mcu_wr_addr : std_logic_vector(6 downto 0) := (others => '0');
    signal mcu_rd_data, mcu_wr_data : vector_t := (others => (others => '0'));
    signal mcu_we                   : std_logic := '0';
    signal mcu_mask                 : std_logic_vector(3 downto 0) := "0000";
    
    signal ifu_pred_sel : std_logic_vector(1 downto 0) := "00";
    signal ifu_pred_mod : std_logic_vector(1 downto 0) := "00";
    signal ifu_mask_out : std_logic_vector(31 downto 0);

begin

    clk_process: process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    -- Dynamically route Write Enable based on opcode type
    iss_prf_we <= '1' when (iss_opcode = OP_FCMP_LT or iss_opcode = OP_FCMP_EQ or 
                            iss_opcode = OP_PAND or iss_opcode = OP_POR or iss_opcode = OP_PXOR) else '0';

    -- ========================================================================
    -- INSTANTIATIONS
    -- ========================================================================
    u_issuer: entity work.instruction_issue
        port map (
            clk => clk, reset => reset, fpu_ctrl_in => fpu_ctrl_in, valid_in => valid_in,
            current_thread => current_thread, opcode_out => iss_opcode,
            rs1_addr_global => iss_rs1_addr, rs2_addr_global => iss_rs2_addr, 
            rs3_addr_global => iss_rs3_addr, rd_addr_global => iss_rd_addr,
            inst_write_mask => iss_mask, reg_we => iss_we, issue_valid => iss_valid,
            cmp_invert => iss_cmp_invert, cmp_swap => iss_cmp_swap,
            swiz_sel_a => open, swiz_sel_b => open, swiz_sel_c => open, wb_mux_sel => open
        );

    u_vrf: entity work.vector_reg_file
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr, rs3_addr => iss_rs3_addr,
            rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            -- Port A (Writeback from FPU)
            rd_addr_A => s2_rd_addr_pipe(FPU_MAX_LATENCY), rd_data_A => vrf_wb_data,
            write_mask_A => s2_mask_pipe(FPU_MAX_LATENCY), we_A => s2_vrf_we_pipe(FPU_MAX_LATENCY),
            -- Port B (MCU)
            rd_addr_B => mcu_rd_addr, rd_data_B => mcu_rd_data,
            wr_addr_B => mcu_wr_addr, wr_data_B => mcu_wr_data,
            write_mask_B => mcu_mask, we_B => mcu_we
        );

    u_prf: entity work.predicate_reg_file
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr,
            rs1_data => prf_rs1_data, rs2_data => prf_rs2_data,
            -- Writeback Port
            wr_addr => s2_rd_addr_pipe(FPU_MAX_LATENCY), wr_data => prf_wb_data,
            we => s2_prf_we_pipe(FPU_MAX_LATENCY), wr_mask => s2_mask_pipe(FPU_MAX_LATENCY),
            -- IFU Interface
            ifu_pred_sel => ifu_pred_sel, ifu_pred_mod => ifu_pred_mod, ifu_mask_out => ifu_mask_out
        );

    -- ========================================================================
    -- PIPELINE SYNCHRONIZATION & FPU MUXING
    -- ========================================================================
    is_logic_op <= '1' when (s1_opcode = OP_PAND or s1_opcode = OP_POR or s1_opcode = OP_PXOR) else '0';

    -- Override LSBs with PRF data if doing a logic operation
    op_a_x <= x"0000000" & "000" & prf_rs1_data(0) when is_logic_op = '1' else vrf_rs1_data(0);
    op_b_x <= x"0000000" & "000" & prf_rs2_data(0) when is_logic_op = '1' else vrf_rs2_data(0);
    op_a_y <= x"0000000" & "000" & prf_rs1_data(1) when is_logic_op = '1' else vrf_rs1_data(1);
    op_b_y <= x"0000000" & "000" & prf_rs2_data(1) when is_logic_op = '1' else vrf_rs2_data(1);
    op_a_z <= x"0000000" & "000" & prf_rs1_data(2) when is_logic_op = '1' else vrf_rs1_data(2);
    op_b_z <= x"0000000" & "000" & prf_rs2_data(2) when is_logic_op = '1' else vrf_rs2_data(2);
    op_a_w <= x"0000000" & "000" & prf_rs1_data(3) when is_logic_op = '1' else vrf_rs1_data(3);
    op_b_w <= x"0000000" & "000" & prf_rs2_data(3) when is_logic_op = '1' else vrf_rs2_data(3);

    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>op_a_x, op_b=>op_b_x, op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>fpu_valid_x, comp_flag=>comp_flag_x, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>op_a_y, op_b=>op_b_y, op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open,        comp_flag=>comp_flag_y, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>op_a_z, op_b=>op_b_z, op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open,        comp_flag=>comp_flag_z, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>op_a_w, op_b=>op_b_w, op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open,        comp_flag=>comp_flag_w, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);

    vrf_wb_data <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w);
    prf_wb_data <= comp_flag_w & comp_flag_z & comp_flag_y & comp_flag_x;

    pipeline_sync: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
                s2_vrf_we_pipe <= (others => '0');
                s2_prf_we_pipe <= (others => '0');
            else
                -- Stage 1: Delay math control signals 1 cycle to align with Register File Outputs
                s1_opcode   <= iss_opcode;
                s1_valid    <= iss_valid;
                s1_cmp_inv  <= iss_cmp_invert;
                s1_cmp_swap <= iss_cmp_swap;

                -- Writeback Delay Line Setup
                s2_rd_addr_pipe(0) <= iss_rd_addr;
                s2_mask_pipe(0)    <= iss_mask;
                s2_vrf_we_pipe(0)  <= iss_we and iss_valid and (not iss_prf_we);
                s2_prf_we_pipe(0)  <= iss_prf_we and iss_valid;
                
                for i in 1 to FPU_MAX_LATENCY loop
                    s2_rd_addr_pipe(i) <= s2_rd_addr_pipe(i-1);
                    s2_mask_pipe(i)    <= s2_mask_pipe(i-1);
                    s2_vrf_we_pipe(i)  <= s2_vrf_we_pipe(i-1);
                    s2_prf_we_pipe(i)  <= s2_prf_we_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;


    -- ========================================================================
    -- MAIN STIMULUS & VERIFICATION PROCESS
    -- ========================================================================
    stim_proc: process
    begin
        -- Default Issuer Record
        fpu_ctrl_in.opcode <= OP_NOP; fpu_ctrl_in.rs1_addr_local <= "00"; fpu_ctrl_in.rs2_addr_local <= "00";
        fpu_ctrl_in.rs3_addr_local <= "00"; fpu_ctrl_in.rd_addr_local <= "00"; fpu_ctrl_in.write_mask <= "0000";
        fpu_ctrl_in.swiz_sel_a <= ("00", "00", "00", "00"); fpu_ctrl_in.swiz_sel_b <= ("00", "00", "00", "00");
        fpu_ctrl_in.swiz_sel_c <= ("00", "00", "00", "00"); fpu_ctrl_in.wb_mux_sel <= "00"; fpu_ctrl_in.reg_we <= '0';
        fpu_ctrl_in.cmp_invert <= '0'; fpu_ctrl_in.cmp_swap <= '0';

        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 1: Load Initial Data via MCU Port
        -- ====================================================================
        report ">> PHASE 1: Initializing Vector Registers (v0 = Thread*4 + Comp_ID, v1 = 10.0)";
        for i in 0 to 31 loop
            mcu_wr_addr    <= std_logic_vector(to_unsigned(i, 5)) & "00";
            mcu_wr_data(0) <= to_slv(to_float(real(i * 4 + 0))); 
            mcu_wr_data(1) <= to_slv(to_float(real(i * 4 + 1))); 
            mcu_wr_data(2) <= to_slv(to_float(real(i * 4 + 2))); 
            mcu_wr_data(3) <= to_slv(to_float(real(i * 4 + 3))); 
            mcu_mask       <= "1111";
            mcu_we         <= '1';
            wait until rising_edge(clk);
            
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "01";
            mcu_wr_data <= (others => x"41200000"); -- Float representation of 10.0
            wait until rising_edge(clk);
        end loop;
        mcu_we <= '0';

        -- ====================================================================
        -- PHASE 2: Issue SIMT Math Instruction
        -- ====================================================================
        report ">> PHASE 2: Issuing OP_FADD (v2 = v0 + v1)";
        fpu_ctrl_in.opcode <= OP_FADD;
        fpu_ctrl_in.rs1_addr_local <= "00"; -- v0
        fpu_ctrl_in.rs2_addr_local <= "01"; -- v1
        fpu_ctrl_in.rd_addr_local  <= "10"; -- Store in v2
        fpu_ctrl_in.write_mask     <= "1111";
        fpu_ctrl_in.reg_we         <= '1';
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 

        report ">> Waiting for FADD pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 3: Issue SIMT Predicate Generation (v0 < 10.0)
        -- ====================================================================
        report ">> PHASE 3: Issuing OP_FCMP_LT (p0 = v0 < v1)";
        fpu_ctrl_in.opcode <= OP_FCMP_LT;
        fpu_ctrl_in.rs1_addr_local <= "00"; -- v0
        fpu_ctrl_in.rs2_addr_local <= "01"; -- v1
        fpu_ctrl_in.rd_addr_local  <= "00"; -- Store in predicate p0
        fpu_ctrl_in.write_mask     <= "1111";
        fpu_ctrl_in.reg_we         <= '0';  -- Disabled for VRF, handled by logic
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 

        report ">> Waiting for FCMP pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;


        -- ====================================================================
        -- PHASE 4: Verify Vector Reg File (Math Results)
        -- ====================================================================
        report ">> PHASE 4: Verifying VRF Writeback Results";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "10";
            wait until rising_edge(clk); 
            wait until falling_edge(clk); 
            
            assert to_real(to_float(mcu_rd_data(0))) = real(i * 4 + 0) + 10.0 report "Thread " & integer'image(i) & " X mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(i * 4 + 1) + 10.0 report "Thread " & integer'image(i) & " Y mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real(i * 4 + 2) + 10.0 report "Thread " & integer'image(i) & " Z mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(i * 4 + 3) + 10.0 report "Thread " & integer'image(i) & " W mismatch!" severity error;
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 5: Verify Predicate Reg File & IFU Collapsing
        -- Context: v0 is an incrementing sequence. v1 is 10.0.
        -- T0 (0,1,2,3) < 10 -> Mask = 1111
        -- T1 (4,5,6,7) < 10 -> Mask = 1111
        -- T2 (8,9,10,11) < 10 -> Mask = 0011 (X, Y are True. Z, W are False)
        -- T3...T31 -> Mask = 0000
        -- ====================================================================
        report ">> PHASE 5: Verifying PRF and IFU Collapse Logic";
        ifu_pred_sel <= "00"; -- Read p0

        -- 1. Test ALL Modifier
        ifu_pred_mod <= PRED_MOD_ALL;
        wait until rising_edge(clk); wait until falling_edge(clk);
        -- Expecting only Threads 0 and 1 to be fully true.
        assert ifu_mask_out = x"00000003" report "PRED_MOD_ALL Failed! Expected Threads 0,1" severity error;

        -- 2. Test ANY Modifier
        ifu_pred_mod <= PRED_MOD_ANY;
        wait until rising_edge(clk); wait until falling_edge(clk);
        -- Expecting Threads 0, 1, and 2 to have at least one true component.
        assert ifu_mask_out = x"00000007" report "PRED_MOD_ANY Failed! Expected Threads 0,1,2" severity error;

        -- 3. Test X_ONLY Modifier
        ifu_pred_mod <= PRED_MOD_X;
        wait until rising_edge(clk); wait until falling_edge(clk);
        -- Thread 2's X component is 8, which is < 10, so T2 should be true.
        assert ifu_mask_out = x"00000007" report "PRED_MOD_X Failed! Expected Threads 0,1,2" severity error;

        -- 4. Test A_ONLY Modifier
        ifu_pred_mod <= PRED_MOD_A;
        wait until rising_edge(clk); wait until falling_edge(clk);
        -- Thread 2's A (W) component is 11, which is NOT < 10, so T2 should be false.
        assert ifu_mask_out = x"00000003" report "PRED_MOD_A Failed! Expected Threads 0,1" severity error;

        report ">> INTEGRATION TEST COMPLETE: Dual VRF/PRF Pipeline is perfectly synced!";
        std.env.stop;
    end process;

end architecture sim;
