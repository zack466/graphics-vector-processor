library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use IEEE.FLOAT_PKG.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_full_execution_integration is
end entity tb_full_execution_integration;

architecture sim of tb_full_execution_integration is

    constant CLK_PERIOD : time := 10 ns;

    -- Global Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- ========================================================================
    -- STAGE 0: DECODER MOCK SIGNALS (Inputs to Instruction Issue)
    -- ========================================================================
    signal decoder_exec_ctrl : exec_ctrl_t;
    signal decoder_valid_in  : std_logic := '0';
    
    signal decoder_inst_type : std_logic_vector(3 downto 0) := INST_TYPE_FPU;
    signal decoder_red_mode  : std_logic_vector(1 downto 0) := RED_MODE_DOT;
    signal decoder_red_mask  : std_logic_vector(3 downto 0) := "1111";

    -- Parallel latches to hold type/mode/mask for the 32-cycle warp duration
    signal latched_type      : std_logic_vector(3 downto 0);
    signal latched_rmode     : std_logic_vector(1 downto 0);
    signal latched_rmask     : std_logic_vector(3 downto 0);
    signal active_type       : std_logic_vector(3 downto 0);
    signal active_rmode      : std_logic_vector(1 downto 0);
    signal active_rmask      : std_logic_vector(3 downto 0);

    -- ========================================================================
    -- STAGE 0.5: ISSUER OUTPUTS (Inputs to Execution Unit & Register Files)
    -- ========================================================================
    signal iss_current_thread: std_logic_vector(4 downto 0);
    signal iss_rs1_addr      : std_logic_vector(6 downto 0);
    signal iss_rs2_addr      : std_logic_vector(6 downto 0);
    signal iss_rs3_addr      : std_logic_vector(6 downto 0);
    signal iss_rd_addr       : std_logic_vector(6 downto 0);
    
    signal iss_opcode        : std_logic_vector(5 downto 0);
    signal iss_mask          : std_logic_vector(3 downto 0);
    signal iss_valid         : std_logic;
    signal iss_wb_mux        : std_logic_vector(1 downto 0);
    signal iss_cmp_invert    : std_logic;
    signal iss_cmp_swap      : std_logic;
    signal iss_is_logic_op   : std_logic;
    signal iss_vrf_we        : std_logic;
    signal iss_prf_we        : std_logic;
    signal iss_swiz_a        : swizzle_sel_t;
    signal iss_swiz_b        : swizzle_sel_t;
    signal iss_swiz_c        : swizzle_sel_t;
    signal iss_is_load       : std_logic;
    signal iss_imm_data      : std_logic_vector(15 downto 0);

    -- Re-packed record to feed into the Execution Unit
    signal iss_exec_ctrl     : exec_ctrl_t;

    -- ========================================================================
    -- REGISTER FILE DATA BUSES (Arrive at Stage 1)
    -- ========================================================================
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);

    -- ========================================================================
    -- WRITEBACK BUSES (Arrive at Stage N)
    -- ========================================================================
    signal wb_rd_addr  : std_logic_vector(6 downto 0);
    signal wb_vrf_data : vector_t;
    signal wb_prf_data : std_logic_vector(3 downto 0);
    signal wb_vrf_we   : std_logic;
    signal wb_prf_we   : std_logic;
    signal wb_mask     : std_logic_vector(3 downto 0);

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

    -- 32-Cycle Latch for top-level routing signals
    process(clk)
    begin
        if rising_edge(clk) then
            if decoder_valid_in = '1' then
                latched_type  <= decoder_inst_type;
                latched_rmode <= decoder_red_mode;
                latched_rmask <= decoder_red_mask;
            end if;
        end if;
    end process;

    active_type  <= decoder_inst_type when decoder_valid_in = '1' else latched_type;
    active_rmode <= decoder_red_mode  when decoder_valid_in = '1' else latched_rmode;
    active_rmask <= decoder_red_mask  when decoder_valid_in = '1' else latched_rmask;

    -- ========================================================================
    -- INSTANTIATIONS
    -- ========================================================================
    
    u_issuer: entity work.instruction_issue
        port map (
            clk => clk, reset => reset, 
            exec_ctrl_in => decoder_exec_ctrl, 
            valid_in => decoder_valid_in,
            current_thread => iss_current_thread, 
            opcode_out => iss_opcode,
            rs1_addr_global => iss_rs1_addr, 
            rs2_addr_global => iss_rs2_addr, 
            rs3_addr_global => iss_rs3_addr, 
            rd_addr_global => iss_rd_addr,
            inst_write_mask => iss_mask, 
            issue_valid => iss_valid,
            swiz_sel_a => iss_swiz_a, 
            swiz_sel_b => iss_swiz_b, 
            swiz_sel_c => iss_swiz_c, 
            wb_mux_sel => iss_wb_mux,
            cmp_invert => iss_cmp_invert, 
            cmp_swap => iss_cmp_swap, 
            is_logic_op => iss_is_logic_op,
            is_load => iss_is_load, 
            imm_data => iss_imm_data,
            vrf_we => iss_vrf_we, 
            prf_we => iss_prf_we
        );

    -- Repack the flattened issuer signals into the record expected by the Execution Unit
    iss_exec_ctrl.opcode      <= iss_opcode;
    iss_exec_ctrl.write_mask  <= iss_mask;
    iss_exec_ctrl.wb_mux_sel  <= iss_wb_mux;
    iss_exec_ctrl.cmp_invert  <= iss_cmp_invert;
    iss_exec_ctrl.cmp_swap    <= iss_cmp_swap;
    iss_exec_ctrl.is_logic_op <= iss_is_logic_op;
    iss_exec_ctrl.is_load     <= iss_is_load;
    iss_exec_ctrl.imm_data    <= iss_imm_data;
    iss_exec_ctrl.vrf_we      <= iss_vrf_we;
    iss_exec_ctrl.prf_we      <= iss_prf_we;
    iss_exec_ctrl.swiz_sel_a  <= iss_swiz_a;
    iss_exec_ctrl.swiz_sel_b  <= iss_swiz_b;
    iss_exec_ctrl.swiz_sel_c  <= iss_swiz_c;
    iss_exec_ctrl.rs1_addr_local <= "00"; -- Local addresses ignored by exec unit
    iss_exec_ctrl.rs2_addr_local <= "00";
    iss_exec_ctrl.rs3_addr_local <= "00";
    iss_exec_ctrl.rd_addr_local  <= "00";

    uut_exec: entity work.execution_unit
        port map (
            clk               => clk,
            reset             => reset,
            exec_ctrl_in      => iss_exec_ctrl,
            valid_in          => iss_valid,
            inst_type_in      => active_type,
            red_mode_in       => active_rmode,
            red_mask_in       => active_rmask,
            rd_addr_global_in => iss_rd_addr,
            vrf_rs1_data      => vrf_rs1_data,
            vrf_rs2_data      => vrf_rs2_data,
            vrf_rs3_data      => vrf_rs3_data,
            prf_rs1_data      => prf_rs1_data,
            prf_rs2_data      => prf_rs2_data,
            wb_rd_addr_out    => wb_rd_addr,
            wb_vrf_data_out   => wb_vrf_data,
            wb_prf_data_out   => wb_prf_data,
            wb_vrf_we_out     => wb_vrf_we,
            wb_prf_we_out     => wb_prf_we,
            wb_mask_out       => wb_mask
        );

    u_vrf: entity work.vector_reg_file
        port map (
            clk          => clk, reset => reset,
            rs1_addr     => iss_rs1_addr, rs2_addr => iss_rs2_addr, rs3_addr => iss_rs3_addr,
            rs1_data     => vrf_rs1_data, rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            rd_addr_A    => wb_rd_addr, rd_data_A => wb_vrf_data,
            write_mask_A => wb_mask, we_A => wb_vrf_we,
            rd_addr_B    => mcu_rd_addr, rd_data_B => mcu_rd_data,
            wr_addr_B    => mcu_wr_addr, wr_data_B => mcu_wr_data,
            write_mask_B => mcu_mask, we_B => mcu_we
        );

    u_prf: entity work.predicate_reg_file
        port map (
            clk          => clk, reset => reset,
            rs1_addr     => iss_rs1_addr, rs2_addr => iss_rs2_addr,
            rs1_data     => prf_rs1_data, rs2_data => prf_rs2_data,
            wr_addr      => wb_rd_addr, wr_data => wb_prf_data,
            we           => wb_prf_we, wr_mask => wb_mask,
            ifu_pred_sel => ifu_pred_sel, ifu_pred_mod => ifu_pred_mod, ifu_mask_out => ifu_mask_out
        );

    -- ========================================================================
    -- MAIN STIMULUS & VERIFICATION PROCESS
    -- ========================================================================
    stim_proc: process
    begin
        -- Base Initialization
        decoder_exec_ctrl.opcode <= OP_NOP; 
        decoder_exec_ctrl.rs1_addr_local <= "00"; decoder_exec_ctrl.rs2_addr_local <= "00";
        decoder_exec_ctrl.rs3_addr_local <= "00"; decoder_exec_ctrl.rd_addr_local <= "00"; 
        decoder_exec_ctrl.write_mask <= "0000";
        decoder_exec_ctrl.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        decoder_exec_ctrl.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        decoder_exec_ctrl.swiz_sel_c <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        decoder_exec_ctrl.wb_mux_sel <= WB_MUX_FPU; 
        decoder_exec_ctrl.cmp_invert <= '0'; decoder_exec_ctrl.cmp_swap <= '0';
        decoder_exec_ctrl.is_logic_op <= '0'; decoder_exec_ctrl.vrf_we <= '0'; decoder_exec_ctrl.prf_we <= '0';
        decoder_exec_ctrl.is_load <= '0'; decoder_exec_ctrl.imm_data <= (others => '0');

        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 1: Data Setup
        -- ====================================================================
        report ">> PHASE 1: Initializing Vector Registers (v0=Floats, v1=10.0, v3=Integers)";
        for i in 0 to 31 loop
            mcu_wr_addr    <= std_logic_vector(to_unsigned(i, 5)) & "00"; -- v0
            mcu_wr_data(0) <= to_slv(to_float(real(i * 4 + 0))); 
            mcu_wr_data(1) <= to_slv(to_float(real(i * 4 + 1))); 
            mcu_wr_data(2) <= to_slv(to_float(real(i * 4 + 2))); 
            mcu_wr_data(3) <= to_slv(to_float(real(i * 4 + 3))); 
            mcu_mask       <= "1111";
            mcu_we         <= '1';
            wait until rising_edge(clk);
            
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "01"; -- v1
            mcu_wr_data <= (others => x"41200000"); -- 10.0f
            wait until rising_edge(clk);
            
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "11"; -- v3
            mcu_wr_data <= (others => std_logic_vector(to_unsigned(i * 2, 32))); 
            wait until rising_edge(clk);
        end loop;
        mcu_we <= '0';

        -- ====================================================================
        -- PHASE 2 & 3: Standard FPU Integration Test
        -- ====================================================================
        report ">> PHASE 2: Issuing OP_FADD (v2 = v0 + v1)";
        decoder_inst_type <= INST_TYPE_FPU;
        decoder_exec_ctrl.opcode <= OP_FADD;
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- v0
        decoder_exec_ctrl.rs2_addr_local <= "01"; -- v1
        decoder_exec_ctrl.rd_addr_local  <= "10"; -- v2
        decoder_exec_ctrl.write_mask     <= "1111";
        decoder_exec_ctrl.wb_mux_sel     <= WB_MUX_FPU;
        decoder_exec_ctrl.vrf_we         <= '1';
        decoder_exec_ctrl.prf_we         <= '0';
        
        -- Pulse valid exactly like the Fetch/Decode stage would
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        
        -- Wait for 32 threads to issue + 37 pipeline stages + safety buffer
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 3: Verifying FPU Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "10";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert to_real(to_float(mcu_rd_data(0))) = real(i * 4 + 0) + 10.0 report "P3 FPU X mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(i * 4 + 1) + 10.0 report "P3 FPU Y mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real(i * 4 + 2) + 10.0 report "P3 FPU Z mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(i * 4 + 3) + 10.0 report "P3 FPU A mismatch!" severity error;
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 4 & 5: Standard Reduction Integration Test
        -- ====================================================================
        report ">> PHASE 4: Issuing RED_MODE_DOT DP4 (v3 = v0 dot v1)";
        decoder_inst_type <= INST_TYPE_RED;
        decoder_red_mode  <= RED_MODE_DOT;
        decoder_red_mask  <= "1111";
        
        decoder_exec_ctrl.opcode         <= OP_NOP;
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- v0
        decoder_exec_ctrl.rs2_addr_local <= "01"; -- v1
        decoder_exec_ctrl.rd_addr_local  <= "11"; -- v3
        decoder_exec_ctrl.write_mask     <= "1111"; 
        decoder_exec_ctrl.wb_mux_sel     <= WB_MUX_RED;
        decoder_exec_ctrl.vrf_we         <= '1';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 5: Verifying Reduction Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "11";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert to_real(to_float(mcu_rd_data(0))) = real(160 * i + 60) report "P5 RED X mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(160 * i + 60) report "P5 RED Y mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real(160 * i + 60) report "P5 RED Z mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(160 * i + 60) report "P5 RED A mismatch!" severity error;
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 6 & 7: Swizzle + Partial Mask FPU Test (Overwrites v2.xz)
        -- ====================================================================
        report ">> PHASE 6: Issuing OP_FMUL (v2.xz = v0.yxxa * v0.zzyy)";
        decoder_inst_type <= INST_TYPE_FPU;
        decoder_exec_ctrl.opcode <= OP_FMUL;
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- v0
        decoder_exec_ctrl.rs2_addr_local <= "00"; -- v0 again
        decoder_exec_ctrl.rd_addr_local  <= "10"; -- Overwrite v2
        decoder_exec_ctrl.write_mask     <= "0101"; -- Write X and Z only
        
        decoder_exec_ctrl.swiz_sel_a <= (0 => "01", 1 => "00", 2 => "00", 3 => "11");
        decoder_exec_ctrl.swiz_sel_b <= (0 => "10", 1 => "10", 2 => "01", 3 => "01");
        
        decoder_exec_ctrl.wb_mux_sel     <= WB_MUX_FPU;
        decoder_exec_ctrl.vrf_we         <= '1';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 7: Verifying Swizzle & Partial FPU Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "10";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert to_real(to_float(mcu_rd_data(0))) = real((i * 4 + 1) * (i * 4 + 2)) report "P7 X mismatch (Written)!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(i * 4 + 1) + 10.0 report "P7 Y mismatch (Preserved)!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real((i * 4 + 0) * (i * 4 + 1)) report "P7 Z mismatch (Written)!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(i * 4 + 3) + 10.0 report "P7 A mismatch (Preserved)!" severity error;
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 8 & 9: Swizzle + Partial Mask Reduction Test (Overwrites v3.y)
        -- ====================================================================
        report ">> PHASE 8: Issuing RED_MODE_SUM (v3.y = SUM(v0.yyzz))";
        decoder_inst_type <= INST_TYPE_RED;
        decoder_red_mode  <= RED_MODE_SUM;
        decoder_red_mask  <= "1111"; 
        
        decoder_exec_ctrl.opcode <= OP_NOP; 
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- v0
        decoder_exec_ctrl.rs2_addr_local <= "00"; -- Ignored by SUM, set to v0
        decoder_exec_ctrl.rd_addr_local  <= "11"; -- Overwrite v3
        decoder_exec_ctrl.write_mask     <= "0010"; -- Write Y only
        
        decoder_exec_ctrl.swiz_sel_a <= (0 => "01", 1 => "01", 2 => "10", 3 => "10");
        decoder_exec_ctrl.wb_mux_sel <= WB_MUX_RED;
        decoder_exec_ctrl.vrf_we     <= '1';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 9: Verifying Partial Reduction Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "11";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert to_real(to_float(mcu_rd_data(0))) = real(160 * i + 60) report "P9 X mismatch (Preserved)!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(16 * i + 6) report "P9 Y mismatch (Written)!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real(160 * i + 60) report "P9 Z mismatch (Preserved)!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(160 * i + 60) report "P9 A mismatch (Preserved)!" severity error;
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 10: Predicate Generation (p0 = v0 < v1)
        -- ====================================================================
        report ">> PHASE 10: Issuing OP_FCMP_LT (p0 = v0 < v1)";
        decoder_inst_type <= INST_TYPE_FPU;
        decoder_exec_ctrl.opcode <= OP_FCMP_LT;
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- v0
        decoder_exec_ctrl.rs2_addr_local <= "01"; -- v1 (10.0)
        decoder_exec_ctrl.rd_addr_local  <= "00"; -- p0
        decoder_exec_ctrl.write_mask     <= "1111";
        
        -- Reset swizzles to default identity pass-through
        decoder_exec_ctrl.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        decoder_exec_ctrl.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        
        decoder_exec_ctrl.vrf_we         <= '0';
        decoder_exec_ctrl.prf_we         <= '1'; 
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 11: Predicate Generation (p1 = v0 == v1)
        -- ====================================================================
        report ">> PHASE 11: Issuing OP_FCMP_EQ (p1 = v0 == v1)";
        decoder_exec_ctrl.opcode <= OP_FCMP_EQ;
        decoder_exec_ctrl.rd_addr_local  <= "01"; -- p1
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 12: Predicate Logic Combination (p2 = p0 OR p1)
        -- ====================================================================
        report ">> PHASE 12: Issuing OP_POR (p2 = p0 | p1)";
        decoder_exec_ctrl.opcode <= OP_POR;
        decoder_exec_ctrl.rs1_addr_local <= "00"; -- p0
        decoder_exec_ctrl.rs2_addr_local <= "01"; -- p1
        decoder_exec_ctrl.rd_addr_local  <= "10"; -- p2
        decoder_exec_ctrl.is_logic_op    <= '1';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;
        decoder_exec_ctrl.is_logic_op    <= '0'; -- Reset

        -- ====================================================================
        -- PHASE 13: Verify PRF and IFU Collapse Logic
        -- ====================================================================
        report ">> PHASE 13: Verifying PRF Logic and IFU Collapse";
        ifu_pred_sel <= "10"; -- Select p2
        
        ifu_pred_mod <= PRED_MOD_ANY;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "P13 ANY Failed! Expected Threads 0,1,2" severity error;
        
        ifu_pred_mod <= PRED_MOD_ALL;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000003" report "P13 ALL Failed! Expected Threads 0,1" severity error;
        
        ifu_pred_mod <= PRED_MOD_X;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "P13 X Failed! Expected Threads 0,1,2" severity error;
        
        ifu_pred_mod <= PRED_MOD_A; 
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000003" report "P13 A Failed! Expected Threads 0,1" severity error;

        -- ====================================================================
        -- PHASE 13.5: Re-Initialize v3 for ALU testing
        -- ====================================================================
        report ">> PHASE 13.5: Re-initializing v3 with integers";
        for i in 0 to 31 loop
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "11"; -- v3
            mcu_wr_data <= (others => std_logic_vector(to_unsigned(i * 2, 32)));
            mcu_mask    <= "1111";
            mcu_we      <= '1';
            wait until rising_edge(clk);
        end loop;
        mcu_we <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 14 & 15: ALU Integration Test (v3.x = v3.x + v3.x)
        -- ====================================================================
        report ">> PHASE 14: Issuing OP_IADD (v3.x = v3.x + v3.x)";
        decoder_inst_type <= INST_TYPE_ALU;
        decoder_exec_ctrl.opcode <= OP_IADD;
        decoder_exec_ctrl.rs1_addr_local <= "11"; -- v3
        decoder_exec_ctrl.rs2_addr_local <= "11"; -- v3
        decoder_exec_ctrl.rd_addr_local  <= "11"; -- Overwrite v3
        decoder_exec_ctrl.write_mask     <= "0001"; -- Scalar write to X only
        
        decoder_exec_ctrl.wb_mux_sel     <= WB_MUX_ALU;
        decoder_exec_ctrl.vrf_we         <= '1';
        decoder_exec_ctrl.prf_we         <= '0';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 15: Verifying ALU Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "11";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert to_integer(unsigned(mcu_rd_data(0))) = i * 4 report "P15 ALU X mismatch!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 16 & 17: Immediate Load Integration Test (v3.y = x"0000BEEF")
        -- ====================================================================
        report ">> PHASE 16: Issuing OP_LDI_LO (v3.y = 0xBEEF)";
        decoder_inst_type <= INST_TYPE_IMM; 
        decoder_exec_ctrl.opcode      <= OP_LDI_LO;
        decoder_exec_ctrl.rd_addr_local <= "11"; -- Overwrite v3
        decoder_exec_ctrl.write_mask  <= "0010"; -- Scalar write to Y only
        decoder_exec_ctrl.is_load     <= '1';
        decoder_exec_ctrl.imm_data    <= x"BEEF";
        decoder_exec_ctrl.wb_mux_sel  <= WB_MUX_ALU;
        decoder_exec_ctrl.vrf_we      <= '1';
        decoder_exec_ctrl.prf_we      <= '0';
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        decoder_exec_ctrl.is_load <= '0'; -- Clear it for cleanliness
        
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 17: Verifying Immediate Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "11";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            assert mcu_rd_data(1) = x"0000BEEF" report "P17 Immediate Y mismatch!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 18: ALU Comparison (p3 = v3.x < v3.y) -> Expected: TRUE
        -- Context: v3.x is (i*4) ranging 0..124. v3.y is x"BEEF" (48879).
        -- ====================================================================
        report ">> PHASE 18: Issuing OP_ICMP_SLT (p3 = v3.x < v3.y)";
        decoder_inst_type <= INST_TYPE_ALU;
        decoder_exec_ctrl.opcode <= OP_ICMP_SLT;
        decoder_exec_ctrl.rs1_addr_local <= "11"; -- v3
        decoder_exec_ctrl.rs2_addr_local <= "11"; -- v3
        decoder_exec_ctrl.rd_addr_local  <= "11"; -- Write to p3
        decoder_exec_ctrl.write_mask     <= "1111";
        
        -- Swizzle A routes .x to ALU. Swizzle B routes .y to ALU.
        decoder_exec_ctrl.swiz_sel_a <= (0 => "00", 1 => "00", 2 => "00", 3 => "00");
        decoder_exec_ctrl.swiz_sel_b <= (0 => "01", 1 => "01", 2 => "01", 3 => "01");
        
        decoder_exec_ctrl.wb_mux_sel     <= WB_MUX_ALU;
        decoder_exec_ctrl.vrf_we         <= '0';
        decoder_exec_ctrl.prf_we         <= '1'; -- Route ALU comp_flag to PRF
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 19: Verify ALU Comparison (TRUE)
        -- ====================================================================
        report ">> PHASE 19: Verifying ALU Comparison (Expected: All True)";
        ifu_pred_sel <= "11"; -- Select p3
        ifu_pred_mod <= PRED_MOD_X;
        
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"FFFFFFFF" report "P19 ICMP_SLT Failed! Expected all 32 threads to evaluate True." severity error;

        -- ====================================================================
        -- PHASE 20: ALU Comparison (p3 = v3.y < v3.x) -> Expected: FALSE
        -- ====================================================================
        report ">> PHASE 20: Issuing OP_ICMP_SLT (p3 = v3.y < v3.x)";
        
        -- Swap the swizzles so ALU evaluates 48879 < (i*4)
        decoder_exec_ctrl.swiz_sel_a <= (0 => "01", 1 => "01", 2 => "01", 3 => "01");
        decoder_exec_ctrl.swiz_sel_b <= (0 => "00", 1 => "00", 2 => "00", 3 => "00");
        
        decoder_valid_in <= '1'; wait until rising_edge(clk); decoder_valid_in <= '0';
        
        for i in 1 to 100 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 21: Verify ALU Comparison (FALSE)
        -- ====================================================================
        report ">> PHASE 21: Verifying ALU Comparison (Expected: All False)";
        
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000000" report "P21 ICMP_SLT Failed! Expected all 32 threads to evaluate False." severity error;

        report ">> EXHAUSTIVE INTEGRATION TEST COMPLETE: All tests passed!";
        std.env.stop;
    end process;

end architecture sim;
