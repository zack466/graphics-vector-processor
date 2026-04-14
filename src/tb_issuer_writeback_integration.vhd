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
    signal exec_ctrl_in    : exec_ctrl_t;
    signal valid_in        : std_logic := '0';
    
    signal current_thread  : std_logic_vector(4 downto 0);
    signal iss_rs1_addr    : std_logic_vector(8 downto 0);
    signal iss_rs2_addr    : std_logic_vector(8 downto 0);
    signal iss_rs3_addr    : std_logic_vector(8 downto 0);
    signal iss_rd_addr     : std_logic_vector(8 downto 0);
    signal iss_valid       : std_logic;
    
    -- The new unified execution control record from the issuer
    signal iss_exec_record : exec_ctrl_t;

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
    
    -- Stage 1 Immediate Load signals
    signal s1_is_load      : std_logic := '0';
    signal s1_imm_data     : std_logic_vector(15 downto 0) := (others => '0');
    
    signal s1_swiz_a       : swizzle_sel_t;
    signal s1_swiz_b       : swizzle_sel_t;
    signal s1_prf_rs1      : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2      : std_logic_vector(3 downto 0) := "0000";
    -- S1-registered WB control signals: drive writeback_controller from S1 so
    -- its depth of FPU_MAX_LATENCY aligns with the FPU lanes that also start at S1.
    signal s1_rd_addr      : std_logic_vector(8 downto 0) := (others => '0');
    signal s1_wb_mask      : std_logic_vector(3 downto 0) := "0000";
    signal s1_wb_mux       : std_logic_vector(1 downto 0) := "00";
    signal s1_vrf_we       : std_logic := '0';
    signal s1_prf_we       : std_logic := '0';
    
    signal swiz_a_out, swiz_b_out                   : vector_t;

    -- ========================================================================
    -- STAGE 2: EXECUTION LANES (FPU_MAX_LATENCY = 37 Cycles)
    -- ========================================================================
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;
    signal fpu_valid_x : std_logic; 
    
    signal alu_res     : word_t;
    signal alu_valid   : std_logic;
    
    signal vrf_wb_data : vector_t;
    signal prf_wb_data : std_logic_vector(3 downto 0);

    signal wb_rd_addr  : std_logic_vector(8 downto 0);
    signal wb_mask     : std_logic_vector(3 downto 0);
    signal wb_mux_sel  : std_logic_vector(1 downto 0);
    signal wb_vrf_we   : std_logic;
    signal wb_prf_we   : std_logic;

    -- ========================================================================
    -- MCU / IFU VERIFICATION PORTS
    -- ========================================================================
    signal mcu_rd_addr, mcu_wr_addr : std_logic_vector(8 downto 0) := (others => '0');
    signal mcu_rd_data, mcu_wr_data : vector_t := (others => (others => '0'));
    signal mcu_we                   : std_logic := '0';
    signal mcu_mask                 : std_logic_vector(3 downto 0) := "0000";
    
    signal ifu_pred_sel : std_logic_vector(3 downto 0) := "0000";
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
        generic map ( THREAD_WIDTH => 5, REG_WIDTH => 4 )
        port map (
            clk => clk, reset => reset, 
            exec_ctrl_in => exec_ctrl_in, 
            valid_in => valid_in,
            current_thread => current_thread, 
            rs1_addr_global => iss_rs1_addr, rs2_addr_global => iss_rs2_addr, 
            rs3_addr_global => iss_rs3_addr, rd_addr_global => iss_rd_addr,
            exec_ctrl_out => iss_exec_record,
            issue_valid => iss_valid
        );

    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk         => clk, reset => reset,
            iss_rd_addr => s1_rd_addr,
            iss_mask    => s1_wb_mask,
            iss_wb_mux  => s1_wb_mux,
            iss_vrf_we  => s1_vrf_we,
            iss_prf_we  => s1_prf_we,
            wb_rd_addr  => wb_rd_addr,
            wb_mask     => wb_mask,
            wb_mux_sel  => wb_mux_sel,
            wb_vrf_we   => wb_vrf_we,
            wb_prf_we   => wb_prf_we
        );

    u_vrf: entity work.vector_reg_file
        generic map ( ADDR_WIDTH => 9 )
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr, rs3_addr => iss_rs3_addr,
            rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            wr_addr_A => wb_rd_addr, wr_data_A => vrf_wb_data,
            write_mask_A => wb_mask, we_A => wb_vrf_we,
            rd_addr_B => mcu_rd_addr, rd_data_B => mcu_rd_data,
            wr_addr_B => mcu_wr_addr, wr_data_B => mcu_wr_data,
            write_mask_B => mcu_mask, we_B => mcu_we
        );

    u_prf: entity work.predicate_reg_file
        generic map ( ADDR_WIDTH => 9 )
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

    -- ========================================================================
    -- FPU & ALU PIPELINE INSTANTIATIONS
    -- ========================================================================
    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(0), op_b=>swiz_b_out(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>fpu_valid_x, comp_flag=>comp_flag_x, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(1), op_b=>swiz_b_out(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open,        comp_flag=>comp_flag_y, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(2), op_b=>swiz_b_out(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open,        comp_flag=>comp_flag_z, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>swiz_a_out(3), op_b=>swiz_b_out(3), op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open,        comp_flag=>comp_flag_w, cmp_invert=>s1_cmp_inv, cmp_swap=>s1_cmp_swap);

    u_alu: entity work.alu_lane
        port map (
            clk         => clk,
            reset       => reset,
            opcode      => s1_opcode,
            valid_in    => s1_valid,
            is_load     => s1_is_load,
            imm_data    => s1_imm_data,
            op_a        => swiz_a_out(0),
            op_b        => swiz_b_out(0),
            thread_id   => (others => '0'),
            warp_offset => (others => '0'),
            frame_width => (others => '0'),
            frame_height=> (others => '0'),
            time_ms     => (others => '0'),
            result      => alu_res,
            comp_flag   => open,
            valid_out   => alu_valid
        );

    vrf_wb_data <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w) when wb_mux_sel = WB_MUX_FPU else
                   (alu_res, alu_res, alu_res, alu_res)         when wb_mux_sel = WB_MUX_ALU else
                   (others => (others => '0'));

    prf_wb_data <= comp_flag_w & comp_flag_z & comp_flag_y & comp_flag_x;

    pipeline_sync: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid   <= '0';
                s1_is_load <= '0';
            else
                -- Unpack fields from the new unified record
                s1_opcode      <= iss_exec_record.opcode;
                s1_valid       <= iss_valid;
                s1_cmp_inv     <= iss_exec_record.cmp_invert;
                s1_cmp_swap    <= iss_exec_record.cmp_swap;
                s1_is_logic_op <= iss_exec_record.is_logic_op;
                
                s1_is_load     <= iss_exec_record.is_load;
                s1_imm_data    <= iss_exec_record.imm_data;
                
                s1_swiz_a      <= iss_exec_record.swiz_sel_a;
                s1_swiz_b      <= iss_exec_record.swiz_sel_b;
                s1_prf_rs1     <= prf_rs1_data;
                s1_prf_rs2     <= prf_rs2_data;

                s1_rd_addr     <= iss_rd_addr;
                s1_wb_mask     <= iss_exec_record.write_mask;
                s1_wb_mux      <= iss_exec_record.wb_mux_sel;
                s1_vrf_we      <= iss_exec_record.vrf_we and iss_valid;
                s1_prf_we      <= iss_exec_record.prf_we and iss_valid;
            end if;
        end if;
    end process;


    -- ========================================================================
    -- MAIN STIMULUS & VERIFICATION PROCESS
    -- ========================================================================
    stim_proc: process
    begin
        -- Base Initialization using exec_ctrl_t
        exec_ctrl_in.opcode <= OP_NOP; exec_ctrl_in.rs1_addr_local <= "0000"; exec_ctrl_in.rs2_addr_local <= "0000";
        exec_ctrl_in.rs3_addr_local <= "0000"; exec_ctrl_in.rd_addr_local <= "0000"; exec_ctrl_in.write_mask <= "0000";
        
        exec_ctrl_in.swiz_sel_a <= SWIZ_PASS;
        exec_ctrl_in.swiz_sel_b <= SWIZ_PASS;
        exec_ctrl_in.swiz_sel_c <= SWIZ_PASS;
        
        exec_ctrl_in.wb_mux_sel <= WB_MUX_FPU; 
        exec_ctrl_in.cmp_invert <= '0'; exec_ctrl_in.cmp_swap <= '0';
        exec_ctrl_in.is_logic_op <= '0'; exec_ctrl_in.vrf_we <= '0'; exec_ctrl_in.prf_we <= '0';
        exec_ctrl_in.is_load    <= '0'; 
        exec_ctrl_in.imm_data   <= (others => '0');

        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 1: Load Initial Data via MCU Port
        -- ====================================================================
        report ">> PHASE 1: Initializing Vector Registers (v0=Floats, v1=10.0, v3=Integers)";
        for i in 0 to 31 loop
            mcu_wr_addr    <= std_logic_vector(to_unsigned(i, 5)) & "0000";
            mcu_wr_data(0) <= to_slv(to_float(real(i * 4 + 0))); 
            mcu_wr_data(1) <= to_slv(to_float(real(i * 4 + 1))); 
            mcu_wr_data(2) <= to_slv(to_float(real(i * 4 + 2))); 
            mcu_wr_data(3) <= to_slv(to_float(real(i * 4 + 3))); 
            mcu_mask       <= "1111";
            mcu_we         <= '1';
            wait until rising_edge(clk);
            
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "0001";
            mcu_wr_data <= (others => x"41200000"); -- Float representation of 10.0
            wait until rising_edge(clk);

            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "0011";
            mcu_wr_data <= (others => std_logic_vector(to_unsigned(i * 2, 32))); 
            wait until rising_edge(clk);
        end loop;
        mcu_we <= '0';

        -- ====================================================================
        -- PHASE 2: Issue SIMT Math Instruction (FPU)
        -- ====================================================================
        report ">> PHASE 2: Issuing OP_FADD (v2 = v0 + v1)";
        exec_ctrl_in.opcode <= OP_FADD;
        exec_ctrl_in.rs1_addr_local <= "0000"; -- v0
        exec_ctrl_in.rs2_addr_local <= "0001"; -- v1
        exec_ctrl_in.rd_addr_local  <= "0010"; -- Store in v2
        exec_ctrl_in.write_mask     <= "1111";
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_FPU;
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 

        report ">> Waiting for FADD pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 3: Issue SIMT Predicate Generation (v0 < 10.0)
        -- ====================================================================
        report ">> PHASE 3: Issuing OP_FCMP_LT (p0 = v0 < v1)";
        exec_ctrl_in.opcode <= OP_FCMP_LT;
        exec_ctrl_in.rs1_addr_local <= "0000"; -- v0
        exec_ctrl_in.rs2_addr_local <= "0001"; -- v1
        exec_ctrl_in.rd_addr_local  <= "0000"; -- Store in predicate p0
        exec_ctrl_in.write_mask     <= "1111";
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_FPU;
        exec_ctrl_in.vrf_we         <= '0';
        exec_ctrl_in.prf_we         <= '1';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 

        report ">> Waiting for FCMP pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 4: Verify Vector Reg File (Math Results)
        -- ====================================================================
        report ">> PHASE 4: Verifying VRF Writeback Results (FPU)";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "0010";
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
        -- ====================================================================
        report ">> PHASE 5: Verifying PRF and IFU Collapse Logic";
        ifu_pred_sel <= "0000"; -- Read p0

        ifu_pred_mod <= PRED_MOD_ALL;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000003" report "PRED_MOD_ALL Failed! Expected Threads 0,1" severity error;

        ifu_pred_mod <= PRED_MOD_ANY;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "PRED_MOD_ANY Failed! Expected Threads 0,1,2" severity error;

        ifu_pred_mod <= PRED_MOD_X;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000007" report "PRED_MOD_X Failed! Expected Threads 0,1,2" severity error;

        ifu_pred_mod <= PRED_MOD_A;
        wait until rising_edge(clk); wait until falling_edge(clk);
        assert ifu_mask_out = x"00000003" report "PRED_MOD_A Failed! Expected Threads 0,1" severity error;

        -- ====================================================================
        -- PHASE 6: Issue SIMT Integer ALU Operation (v3.x = v3.x + v3.x)
        -- ====================================================================
        report ">> PHASE 6: Issuing OP_IADD (v3.x = v3.x + v3.x)";
        exec_ctrl_in.opcode <= OP_IADD;
        exec_ctrl_in.rs1_addr_local <= "0011"; -- v3
        exec_ctrl_in.rs2_addr_local <= "0011"; -- v3
        exec_ctrl_in.rd_addr_local  <= "0011"; -- Overwrite v3
        exec_ctrl_in.write_mask     <= "0001"; -- Scalar write to X only
        
        exec_ctrl_in.wb_mux_sel     <= WB_MUX_ALU;
        exec_ctrl_in.vrf_we         <= '1';
        exec_ctrl_in.prf_we         <= '0';
        exec_ctrl_in.is_logic_op    <= '0';
        
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 

        report ">> Waiting for IADD pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 7: Verify Vector Reg File (ALU Results)
        -- ====================================================================
        report ">> PHASE 7: Verifying VRF Writeback Results (ALU)";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "0011";
            wait until rising_edge(clk); 
            wait until falling_edge(clk); 
            
            assert to_integer(unsigned(mcu_rd_data(0))) = i * 4 report "Thread " & integer'image(i) & " ALU X mismatch!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 8: Issue SIMT Immediate Load (v3.y = x"0000BEEF")
        -- ====================================================================
        report ">> PHASE 8: Issuing OP_LDI_LO (v3.y = 0xBEEF)";
        exec_ctrl_in.opcode      <= OP_LDI_LO;
        exec_ctrl_in.rd_addr_local <= "0011"; -- Overwrite v3
        exec_ctrl_in.write_mask  <= "0010"; -- Scalar write to Y only
        exec_ctrl_in.is_load     <= '1';
        exec_ctrl_in.imm_data    <= x"BEEF";
        exec_ctrl_in.wb_mux_sel  <= WB_MUX_ALU;
        exec_ctrl_in.vrf_we      <= '1';
        exec_ctrl_in.prf_we      <= '0';
        exec_ctrl_in.is_logic_op <= '0';
        
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0'; 
        exec_ctrl_in.is_load <= '0'; -- Ensure it is cleared for future instructions

        report ">> Waiting for LDI pipelined execution to complete...";
        for i in 1 to 75 loop wait until rising_edge(clk); end loop;

        -- ====================================================================
        -- PHASE 9: Verify Vector Reg File (Immediate Results)
        -- ====================================================================
        report ">> PHASE 9: Verifying VRF Writeback Results (Immediates)";
        for i in 0 to 31 loop
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "0011";
            wait until rising_edge(clk); 
            wait until falling_edge(clk); 
            
            assert mcu_rd_data(1) = x"0000BEEF" report "Thread " & integer'image(i) & " ALU Y mismatch (Immediate)!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        report ">> INTEGRATION TEST COMPLETE: FPU, PRF, and ALU Pipelines are synced!";
        std.env.stop;
    end process;

end architecture sim;
