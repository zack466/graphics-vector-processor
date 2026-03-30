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
    -- STAGE 0: INSTRUCTION ISSUE & PARALLEL LATCH
    -- ========================================================================
    signal exec_ctrl_in    : exec_ctrl_t; -- UPDATED: Unified Execution Record
    signal valid_in        : std_logic := '0';
    
    signal inst_type_in    : std_logic_vector(3 downto 0) := INST_TYPE_FPU;
    signal red_mode_in     : std_logic_vector(1 downto 0) := RED_MODE_DOT;
    signal red_mask_in     : std_logic_vector(3 downto 0) := "1111";
    
    signal latched_type    : std_logic_vector(3 downto 0);
    signal latched_rmode   : std_logic_vector(1 downto 0);
    signal latched_rmask   : std_logic_vector(3 downto 0);
    
    signal active_type     : std_logic_vector(3 downto 0);
    signal active_rmode    : std_logic_vector(1 downto 0);
    signal active_rmask    : std_logic_vector(3 downto 0);

    signal current_thread  : std_logic_vector(4 downto 0);
    signal iss_opcode      : std_logic_vector(5 downto 0);
    signal iss_rs1_addr    : std_logic_vector(6 downto 0);
    signal iss_rs2_addr    : std_logic_vector(6 downto 0);
    signal iss_rs3_addr    : std_logic_vector(6 downto 0);
    signal iss_rd_addr     : std_logic_vector(6 downto 0);
    signal iss_mask        : std_logic_vector(3 downto 0);
    signal iss_valid       : std_logic;
    signal iss_swiz_a      : swizzle_sel_t;
    signal iss_swiz_b      : swizzle_sel_t;
    signal iss_wb_mux      : std_logic_vector(1 downto 0);
    signal iss_cmp_invert  : std_logic;
    signal iss_cmp_swap    : std_logic;
    signal iss_is_logic_op : std_logic;
    signal iss_vrf_we      : std_logic;
    signal iss_prf_we      : std_logic;

    -- ========================================================================
    -- STAGE 1: VRF READ & SWIZZLE NETWORK (Strictly Pipelined)
    -- ========================================================================
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    
    -- STAGE 1 ISOLATION REGISTERS
    signal s1_opcode       : std_logic_vector(5 downto 0);
    signal s1_valid        : std_logic;
    signal s1_type         : std_logic_vector(3 downto 0);
    signal s1_rmode        : std_logic_vector(1 downto 0);
    signal s1_rmask        : std_logic_vector(3 downto 0);
    signal s1_cmp_inv      : std_logic;
    signal s1_cmp_swap     : std_logic;
    signal s1_swiz_a       : swizzle_sel_t;
    signal s1_swiz_b       : swizzle_sel_t;
    signal s1_is_logic_op  : std_logic;
    
    signal s1_prf_rs1      : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2      : std_logic_vector(3 downto 0) := "0000";
    
    signal swiz_a_out, swiz_b_out                   : vector_t;

    -- ========================================================================
    -- STAGE 2: PARALLEL EXECUTION (FPU, ALU, REDUCTION)
    -- ========================================================================
    signal fpu_en, red_en, alu_en : std_logic;
    
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_a : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_a : std_logic;
    signal fpu_valid_x : std_logic;
    signal red_res_scalar : word_t;
    
    signal alu_res   : word_t;
    signal alu_valid : std_logic;
    
    signal wb_data     : vector_t;
    signal prf_wb_data : std_logic_vector(3 downto 0);

    -- ========================================================================
    -- STAGE N: WRITEBACK SIGNALS (From Controller)
    -- ========================================================================
    signal wb_rd_addr : std_logic_vector(6 downto 0);
    signal wb_mask    : std_logic_vector(3 downto 0);
    signal wb_mux_sel : std_logic_vector(1 downto 0);
    signal wb_vrf_we  : std_logic;
    signal wb_prf_we  : std_logic;

    -- ========================================================================
    -- MCU / VERIFICATION PORT (VRF PORT B)
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

    process(clk)
    begin
        if rising_edge(clk) then
            if valid_in = '1' then
                latched_type  <= inst_type_in;
                latched_rmode <= red_mode_in;
                latched_rmask <= red_mask_in;
            end if;
        end if;
    end process;

    active_type  <= inst_type_in when valid_in = '1' else latched_type;
    active_rmode <= red_mode_in  when valid_in = '1' else latched_rmode;
    active_rmask <= red_mask_in  when valid_in = '1' else latched_rmask;
    
    -- ========================================================================
    -- INSTANTIATIONS
    -- ========================================================================
    u_issuer: entity work.instruction_issue
        port map (
            clk => clk, reset => reset, exec_ctrl_in => exec_ctrl_in, valid_in => valid_in,
            current_thread => current_thread, opcode_out => iss_opcode,
            rs1_addr_global => iss_rs1_addr, rs2_addr_global => iss_rs2_addr, 
            rs3_addr_global => iss_rs3_addr, rd_addr_global => iss_rd_addr,
            inst_write_mask => iss_mask, issue_valid => iss_valid,
            swiz_sel_a => iss_swiz_a, swiz_sel_b => iss_swiz_b, swiz_sel_c => open, wb_mux_sel => iss_wb_mux,
            cmp_invert => iss_cmp_invert, cmp_swap => iss_cmp_swap, is_logic_op => iss_is_logic_op,
            vrf_we => iss_vrf_we, prf_we => iss_prf_we
        );

    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk         => clk,
            reset       => reset,
            iss_rd_addr => iss_rd_addr,
            iss_mask    => iss_mask,
            iss_wb_mux  => iss_wb_mux,
            iss_vrf_we  => (iss_vrf_we and iss_valid),
            iss_prf_we  => (iss_prf_we and iss_valid),
            wb_rd_addr  => wb_rd_addr,
            wb_mask     => wb_mask,
            wb_mux_sel  => wb_mux_sel,
            wb_vrf_we   => wb_vrf_we,
            wb_prf_we   => wb_prf_we
        );

    u_vrf: entity work.vector_reg_file
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr, rs3_addr => iss_rs3_addr,
            rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            rd_addr_A => wb_rd_addr, rd_data_A => wb_data,
            write_mask_A => wb_mask, we_A => wb_vrf_we,
            rd_addr_B => mcu_rd_addr, rd_data_B => mcu_rd_data,
            wr_addr_B => mcu_wr_addr, wr_data_B => mcu_wr_data,
            write_mask_B => mcu_mask, we_B => mcu_we
        );

    u_prf: entity work.predicate_reg_file
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr,
            rs1_data => prf_rs1_data, rs2_data => prf_rs2_data,
            wr_addr => wb_rd_addr, wr_data => prf_wb_data,
            we => wb_prf_we, wr_mask => wb_mask,
            ifu_pred_sel => ifu_pred_sel, ifu_pred_mod => ifu_pred_mod, ifu_mask_out => ifu_mask_out
        );

    u_swizzle: entity work.swizzle_network
        port map (
            is_logic_op => s1_is_logic_op,
            vec_a_in    => vrf_rs1_data, 
            prf_a_in    => s1_prf_rs1,
            swiz_sel_a  => s1_swiz_a, 
            vec_a_out   => swiz_a_out,
            
            vec_b_in    => vrf_rs2_data, 
            prf_b_in    => s1_prf_rs2,
            swiz_sel_b  => s1_swiz_b, 
            vec_b_out   => swiz_b_out
        );

    fpu_en <= '1' when (s1_valid = '1' and s1_type = INST_TYPE_FPU) else '0';
    red_en <= '1' when (s1_valid = '1' and s1_type = INST_TYPE_RED) else '0';
    alu_en <= '1' when (s1_valid = '1' and s1_type = INST_TYPE_ALU) else '0';

    -- FPU lanes just receive opcode as a dumb ALU selector
    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>fpu_en, op_a=>swiz_a_out(0), op_b=>swiz_b_out(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>fpu_valid_x, comp_flag=>comp_flag_x, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>fpu_en, op_a=>swiz_a_out(1), op_b=>swiz_b_out(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open,        comp_flag=>comp_flag_y, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>fpu_en, op_a=>swiz_a_out(2), op_b=>swiz_b_out(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open,        comp_flag=>comp_flag_z, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_a: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>fpu_en, op_a=>swiz_a_out(3), op_b=>swiz_b_out(3), op_c=>vrf_rs3_data(3), result=>fpu_res_a, valid_out=>open,        comp_flag=>comp_flag_a, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);

    u_reduction: entity work.vector_reduction_unit
        port map (
            clk => clk, reset => reset, valid_in => red_en,
            vec_a => swiz_a_out, vec_b => swiz_b_out,
            reduce_mask => s1_rmask, red_mode => s1_rmode,
            result => red_res_scalar, valid_out => open
        );

    -- NEW: ALU Lane (Scalar, tapped into .x channel)
    u_alu: entity work.alu_lane 
        port map (
            clk       => clk, reset => reset, opcode => s1_opcode, valid_in => alu_en,
            op_a      => swiz_a_out(0), op_b => swiz_b_out(0),
            result    => alu_res, valid_out => alu_valid
        );

    wb_data <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_a) when wb_mux_sel = WB_MUX_FPU else 
               (red_res_scalar, red_res_scalar, red_res_scalar, red_res_scalar) when wb_mux_sel = WB_MUX_RED else
               (alu_res, alu_res, alu_res, alu_res);
               
    prf_wb_data <= comp_flag_a & comp_flag_z & comp_flag_y & comp_flag_x;

    pipeline_sync: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
            else
                -- STRICLY LATCH ALL STAGE 0 SIGNALS INTO STAGE 1
                s1_opcode      <= iss_opcode;
                s1_valid       <= iss_valid;
                s1_type        <= active_type;
                s1_rmode       <= active_rmode;
                s1_rmask       <= active_rmask;
                s1_cmp_inv     <= iss_cmp_invert;
                s1_cmp_swap    <= iss_cmp_swap;
                s1_swiz_a      <= iss_swiz_a;
                s1_swiz_b      <= iss_swiz_b;
                s1_is_logic_op <= iss_is_logic_op;
                
                -- Latch Async PRF data to align with Sync VRF data
                s1_prf_rs1     <= prf_rs1_data;
                s1_prf_rs2     <= prf_rs2_data;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- MAIN STIMULUS & VERIFICATION PROCESS
    -- ========================================================================
    stim_proc: process
    begin
        -- Base Initialization matching Decoder Defaults
        exec_ctrl_in.opcode <= OP_NOP; 
        exec_ctrl_in.rs1_addr_local <= "00"; exec_ctrl_in.rs2_addr_local <= "00";
        exec_ctrl_in.rs3_addr_local <= "00"; exec_ctrl_in.rd_addr_local <= "00"; 
        exec_ctrl_in.write_mask <= "0000";
        exec_ctrl_in.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        exec_ctrl_in.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        exec_ctrl_in.swiz_sel_c <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        exec_ctrl_in.wb_mux_sel <= WB_MUX_FPU; 
        exec_ctrl_in.cmp_invert <= '0';
        exec_ctrl_in.cmp_swap <= '0';
        exec_ctrl_in.is_logic_op <= '0';
        exec_ctrl_in.vrf_we <= '0';
        exec_ctrl_in.prf_we <= '0';

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
        inst_type_in <= INST_TYPE_FPU;
        exec_ctrl_in.opcode <= OP_FADD;
        exec_ctrl_in.rs1_addr_local <= "00"; -- v0
        exec_ctrl_in.rs2_addr_local <= "01"; -- v1
        exec_ctrl_in.rd_addr_local  <= "10"; -- v2
        exec_ctrl_in.write_mask     <= "1111";
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_FPU;
        
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0'; 
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

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
        inst_type_in <= INST_TYPE_RED;
        red_mode_in  <= RED_MODE_DOT;
        red_mask_in  <= "1111";
        
        exec_ctrl_in.opcode <= OP_NOP;
        exec_ctrl_in.rs1_addr_local <= "00"; -- v0
        exec_ctrl_in.rs2_addr_local <= "01"; -- v1
        exec_ctrl_in.rd_addr_local  <= "11"; -- v3
        exec_ctrl_in.write_mask     <= "1111"; 
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_RED;
        
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

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
        inst_type_in <= INST_TYPE_FPU;
        exec_ctrl_in.opcode <= OP_FMUL;
        exec_ctrl_in.rs1_addr_local <= "00"; -- v0
        exec_ctrl_in.rs2_addr_local <= "00"; -- v0 again
        exec_ctrl_in.rd_addr_local  <= "10"; -- Overwrite v2
        exec_ctrl_in.write_mask     <= "0101"; -- Write X and Z only
        
        exec_ctrl_in.swiz_sel_a <= (0 => "01", 1 => "00", 2 => "00", 3 => "11");
        exec_ctrl_in.swiz_sel_b <= (0 => "10", 1 => "10", 2 => "01", 3 => "01");
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_FPU;
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

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
        inst_type_in <= INST_TYPE_RED;
        red_mode_in  <= RED_MODE_SUM;
        red_mask_in  <= "1111"; 
        
        exec_ctrl_in.opcode <= OP_NOP; 
        exec_ctrl_in.rs1_addr_local <= "00"; -- v0
        exec_ctrl_in.rs2_addr_local <= "00"; -- Ignored by SUM, set to v0
        exec_ctrl_in.rd_addr_local  <= "11"; -- Overwrite v3
        exec_ctrl_in.write_mask     <= "0010"; -- Write Y only
        
        exec_ctrl_in.swiz_sel_a <= (0 => "01", 1 => "01", 2 => "10", 3 => "10");
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_RED;
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

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
        inst_type_in <= INST_TYPE_FPU;
        exec_ctrl_in.opcode <= OP_FCMP_LT;
        exec_ctrl_in.rs1_addr_local <= "00"; -- v0
        exec_ctrl_in.rs2_addr_local <= "01"; -- v1 (10.0)
        exec_ctrl_in.rd_addr_local  <= "00"; -- p0
        exec_ctrl_in.write_mask     <= "1111";
        exec_ctrl_in.cmp_invert     <= '0';
        exec_ctrl_in.cmp_swap       <= '0';
        
        exec_ctrl_in.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        exec_ctrl_in.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        
        exec_ctrl_in.vrf_we         <= '0';
        exec_ctrl_in.prf_we         <= '1'; 
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 11: Predicate Generation (p1 = v0 == v1)
        -- ====================================================================
        report ">> PHASE 11: Issuing OP_FCMP_EQ (p1 = v0 == v1)";
        exec_ctrl_in.opcode <= OP_FCMP_EQ;
        exec_ctrl_in.rd_addr_local  <= "01"; -- p1
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 12: Predicate Logic Combination (p2 = p0 OR p1)
        -- ====================================================================
        report ">> PHASE 12: Issuing OP_POR (p2 = p0 | p1)";
        exec_ctrl_in.opcode <= OP_POR;
        exec_ctrl_in.rs1_addr_local <= "00"; -- p0
        exec_ctrl_in.rs2_addr_local <= "01"; -- p1
        exec_ctrl_in.rd_addr_local  <= "10"; -- p2
        
        exec_ctrl_in.vrf_we         <= '0';
        exec_ctrl_in.prf_we         <= '1'; 
        exec_ctrl_in.is_logic_op    <= '1';
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

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
        inst_type_in <= INST_TYPE_ALU;
        exec_ctrl_in.opcode <= OP_IADD;
        exec_ctrl_in.rs1_addr_local <= "11"; -- v3
        exec_ctrl_in.rs2_addr_local <= "11"; -- v3
        exec_ctrl_in.rd_addr_local  <= "11"; -- Overwrite v3
        exec_ctrl_in.write_mask     <= "0001"; -- Scalar write to X only
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_ALU;
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        -- Reset swizzles to default identity pass-through
        exec_ctrl_in.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        exec_ctrl_in.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        
        valid_in <= '1'; wait until rising_edge(clk); valid_in <= '0';
        for i in 1 to 80 loop wait until rising_edge(clk); end loop;

        report ">> PHASE 15: Verifying ALU Writeback";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "11";
            wait until rising_edge(clk); wait until falling_edge(clk);
            
            -- Thread `i` started with v3.x = i * 2. After IADD, it should be (i*2) + (i*2) = i*4
            assert to_integer(unsigned(mcu_rd_data(0))) = i * 4 report "P15 ALU X mismatch!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        report ">> EXHAUSTIVE INTEGRATION TEST COMPLETE: All tests passed!";
        std.env.stop;
    end process;

end architecture sim;
