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
    signal iss_valid       : std_logic;
    signal iss_wb_mux      : std_logic_vector(1 downto 0);
    
    signal iss_cmp_invert  : std_logic;
    signal iss_cmp_swap    : std_logic;
    signal iss_is_logic_op : std_logic;
    signal iss_vrf_we      : std_logic;
    signal iss_prf_we      : std_logic;
    
    -- FIXED: Extracted Swizzle Selectors
    signal iss_swiz_a      : swizzle_sel_t;
    signal iss_swiz_b      : swizzle_sel_t;

    -- ========================================================================
    -- STAGE 1: REG FILE READS (1 Cycle Latency)
    -- ========================================================================
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    
    signal s1_opcode       : std_logic_vector(5 downto 0);
    signal s1_valid        : std_logic;
    signal s1_cmp_inv      : std_logic;
    signal s1_cmp_swap     : std_logic;
    signal s1_is_logic_op  : std_logic;
    
    -- FIXED: Stage 1 isolated Swizzle and PRF Registers
    signal s1_swiz_a       : swizzle_sel_t;
    signal s1_swiz_b       : swizzle_sel_t;
    signal s1_prf_rs1      : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2      : std_logic_vector(3 downto 0) := "0000";
    
    signal swiz_a_out, swiz_b_out                   : vector_t;

    -- ========================================================================
    -- STAGE 2: FPU LANES (FPU_MAX_LATENCY = 37 Cycles)
    -- ========================================================================
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;
    signal fpu_valid_x : std_logic; 
    
    signal vrf_wb_data : vector_t;
    signal prf_wb_data : std_logic_vector(3 downto 0);

    signal wb_rd_addr  : std_logic_vector(6 downto 0);
    signal wb_mask     : std_logic_vector(3 downto 0);
    signal wb_mux_sel  : std_logic_vector(1 downto 0);
    signal wb_vrf_we   : std_logic;
    signal wb_prf_we   : std_logic;

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

    -- ========================================================================
    -- INSTANTIATIONS
    -- ========================================================================
    u_issuer: entity work.instruction_issue
        port map (
            clk => clk, reset => reset, fpu_ctrl_in => fpu_ctrl_in, valid_in => valid_in,
            current_thread => current_thread, opcode_out => iss_opcode,
            rs1_addr_global => iss_rs1_addr, rs2_addr_global => iss_rs2_addr, 
            rs3_addr_global => iss_rs3_addr, rd_addr_global => iss_rd_addr,
            inst_write_mask => iss_mask, issue_valid => iss_valid,
            cmp_invert => iss_cmp_invert, cmp_swap => iss_cmp_swap, is_logic_op => iss_is_logic_op,
            vrf_we => iss_vrf_we, prf_we => iss_prf_we,
            swiz_sel_a => iss_swiz_a, swiz_sel_b => iss_swiz_b, swiz_sel_c => open, wb_mux_sel => iss_wb_mux
        );

    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk         => clk, reset => reset,
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
            rd_addr_A => wb_rd_addr, rd_data_A => vrf_wb_data,
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
            prf_a_in    => s1_prf_rs1,     -- Using correctly aligned S1 PRF data
            swiz_sel_a  => s1_swiz_a,      -- Using pipelined swizzle selectors
            vec_a_out   => swiz_a_out,
            
            vec_b_in    => vrf_rs2_data, 
            prf_b_in    => s1_prf_rs2,     -- Using correctly aligned S1 PRF data
            swiz_sel_b  => s1_swiz_b,      -- Using pipelined swizzle selectors
            vec_b_out   => swiz_b_out
        );

    -- ========================================================================
    -- FPU PIPELINE INSTANTIATION
    -- ========================================================================
    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(0), op_b=>swiz_b_out(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>fpu_valid_x, comp_flag=>comp_flag_x, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(1), op_b=>swiz_b_out(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open,        comp_flag=>comp_flag_y, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(2), op_b=>swiz_b_out(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open,        comp_flag=>comp_flag_z, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(3), op_b=>swiz_b_out(3), op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open,        comp_flag=>comp_flag_w, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);

    vrf_wb_data <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w);
    prf_wb_data <= comp_flag_w & comp_flag_z & comp_flag_y & comp_flag_x;

    pipeline_sync: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
            else
                -- Latch control signals into Stage 1
                s1_opcode      <= iss_opcode;
                s1_valid       <= iss_valid;
                s1_cmp_inv     <= iss_cmp_invert;
                s1_cmp_swap    <= iss_cmp_swap;
                s1_is_logic_op <= iss_is_logic_op;
                
                -- FIXED: Latch Swizzle and Async PRF data to align with Sync VRF data
                s1_swiz_a      <= iss_swiz_a;
                s1_swiz_b      <= iss_swiz_b;
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
        fpu_ctrl_in.opcode <= OP_NOP; fpu_ctrl_in.rs1_addr_local <= "00"; fpu_ctrl_in.rs2_addr_local <= "00";
        fpu_ctrl_in.rs3_addr_local <= "00"; fpu_ctrl_in.rd_addr_local <= "00"; fpu_ctrl_in.write_mask <= "0000";
        
        -- FIXED: Default to Identity Swizzle (X->X, Y->Y, Z->Z, W->W)
        fpu_ctrl_in.swiz_sel_a <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        fpu_ctrl_in.swiz_sel_b <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        fpu_ctrl_in.swiz_sel_c <= (0 => "00", 1 => "01", 2 => "10", 3 => "11");
        
        fpu_ctrl_in.wb_mux_sel <= "00"; 
        fpu_ctrl_in.cmp_invert <= '0'; fpu_ctrl_in.cmp_swap <= '0';
        fpu_ctrl_in.is_logic_op <= '0'; fpu_ctrl_in.vrf_we <= '0'; fpu_ctrl_in.prf_we <= '0';

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
        
        -- MOCKING DECODER FLAGS
        fpu_ctrl_in.vrf_we         <= '1';
        fpu_ctrl_in.prf_we         <= '0';
        fpu_ctrl_in.is_logic_op    <= '0';
        
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
        
        -- MOCKING DECODER FLAGS (Compares route purely to PRF)
        fpu_ctrl_in.vrf_we         <= '0';
        fpu_ctrl_in.prf_we         <= '1';
        fpu_ctrl_in.is_logic_op    <= '0';
        
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
        assert ifu_mask_out = x"00000003" report "PRED_MOD_ALL Failed! Expected Threads 0,1" severity error;

        -- 2. Test ANY Modifier
        ifu_pred_mod <= PRED_MOD_ANY;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "PRED_MOD_ANY Failed! Expected Threads 0,1,2" severity error;

        -- 3. Test X_ONLY Modifier
        ifu_pred_mod <= PRED_MOD_X;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "PRED_MOD_X Failed! Expected Threads 0,1,2" severity error;

        -- 4. Test A_ONLY Modifier
        ifu_pred_mod <= PRED_MOD_A;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000003" report "PRED_MOD_A Failed! Expected Threads 0,1" severity error;

        report ">> INTEGRATION TEST COMPLETE: Dual VRF/PRF Pipeline is perfectly synced!";
        std.env.stop;
    end process;

end architecture sim;
