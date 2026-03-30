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

    -- ========================================================================
    -- STAGE 1: VECTOR REG FILE READ (1 Cycle Latency)
    -- ========================================================================
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    
    -- Delay registers to align control signals with VRF data output
    signal s1_opcode   : std_logic_vector(5 downto 0);
    signal s1_valid    : std_logic;

    -- ========================================================================
    -- STAGE 2: FPU LANES (FPU_MAX_LATENCY = 28 Cycles)
    -- ========================================================================
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal fpu_valid_x : std_logic; 
    signal wb_data     : vector_t;

    -- Massive delay line to carry writeback control signals alongside FPU math
    type addr_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(6 downto 0);
    type mask_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(3 downto 0);
    type we_pipe_t   is array (0 to FPU_MAX_LATENCY) of std_logic;
    
    signal s2_rd_addr_pipe : addr_pipe_t := (others => (others => '0'));
    signal s2_mask_pipe    : mask_pipe_t := (others => "0000");
    signal s2_we_pipe      : we_pipe_t   := (others => '0');

    -- ========================================================================
    -- MCU / VERIFICATION PORT (VRF PORT B)
    -- ========================================================================
    signal mcu_rd_addr, mcu_wr_addr : std_logic_vector(6 downto 0) := (others => '0');
    signal mcu_rd_data, mcu_wr_data : vector_t := (others => (others => '0'));
    signal mcu_we                   : std_logic := '0';
    signal mcu_mask                 : std_logic_vector(3 downto 0) := "0000";

begin

    -- Clock Generator
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
            inst_write_mask => iss_mask, reg_we => iss_we, issue_valid => iss_valid,
            swiz_sel_a => open, swiz_sel_b => open, swiz_sel_c => open, wb_mux_sel => open
        );

    u_vrf: entity work.vector_reg_file
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_addr, rs2_addr => iss_rs2_addr, rs3_addr => iss_rs3_addr,
            rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            -- Port A (Writeback from FPU exactly 29 cycles later)
            rd_addr_A => s2_rd_addr_pipe(FPU_MAX_LATENCY),
            rd_data_A => wb_data,
            write_mask_A => s2_mask_pipe(FPU_MAX_LATENCY),
            we_A => s2_we_pipe(FPU_MAX_LATENCY),
            -- Port B (MCU / Verification)
            rd_addr_B => mcu_rd_addr, rd_data_B => mcu_rd_data,
            wr_addr_B => mcu_wr_addr, wr_data_B => mcu_wr_data,
            write_mask_B => mcu_mask, we_B => mcu_we
        );

    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>vrf_rs1_data(0), op_b=>vrf_rs2_data(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>fpu_valid_x, comp_flag=>open);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>vrf_rs1_data(1), op_b=>vrf_rs2_data(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open, comp_flag=>open);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>vrf_rs1_data(2), op_b=>vrf_rs2_data(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open, comp_flag=>open);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_opcode, valid_in=>s1_valid, op_a=>vrf_rs1_data(3), op_b=>vrf_rs2_data(3), op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open, comp_flag=>open);

    -- Combine FPU lane scalars into a vector for writeback
    wb_data <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w);

    -- ========================================================================
    -- PIPELINE SYNCHRONIZATION (The "Glue" Logic)
    -- ========================================================================
    pipeline_sync: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
                s2_we_pipe <= (others => '0');
            else
                -- Stage 1: Delay math control signals 1 cycle to align with VRF Data Output
                s1_opcode <= iss_opcode;
                s1_valid  <= iss_valid;

                -- Writeback Delay Line: Directly feed Stage 0 outputs into index 0
                s2_rd_addr_pipe(0) <= iss_rd_addr;
                s2_mask_pipe(0)    <= iss_mask;
                s2_we_pipe(0)      <= iss_we and iss_valid;
                
                for i in 1 to FPU_MAX_LATENCY loop
                    s2_rd_addr_pipe(i) <= s2_rd_addr_pipe(i-1);
                    s2_mask_pipe(i)    <= s2_mask_pipe(i-1);
                    s2_we_pipe(i)      <= s2_we_pipe(i-1);
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

        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 1: Load Initial Data via MCU Port
        -- ====================================================================
        report ">> PHASE 1: Initializing Vector Registers (v0 = Thread*4 + Comp_ID, v1 = 10.0)";
        for i in 0 to 31 loop
            -- Write unique values to v0 (Address: Thread(i) & "00")
            mcu_wr_addr    <= std_logic_vector(to_unsigned(i, 5)) & "00";
            mcu_wr_data(0) <= to_slv(to_float(real(i * 4 + 0))); -- X Component
            mcu_wr_data(1) <= to_slv(to_float(real(i * 4 + 1))); -- Y Component
            mcu_wr_data(2) <= to_slv(to_float(real(i * 4 + 2))); -- Z Component
            mcu_wr_data(3) <= to_slv(to_float(real(i * 4 + 3))); -- W Component
            mcu_mask       <= "1111";
            mcu_we         <= '1';
            wait until rising_edge(clk);
            
            -- Write 10.0 to v1 (Address: Thread(i) & "01")
            mcu_wr_addr <= std_logic_vector(to_unsigned(i, 5)) & "01";
            mcu_wr_data <= (others => x"41200000"); -- Float representation of 10.0
            wait until rising_edge(clk);
        end loop;
        mcu_we <= '0';

        -- ====================================================================
        -- PHASE 2: Issue SIMT Instruction
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

        report ">> Waiting for massively pipelined execution to complete...";
        for i in 1 to 75 loop
            wait until rising_edge(clk);
        end loop;

        -- ====================================================================
        -- PHASE 3: Verification
        -- ====================================================================
        report ">> PHASE 3: Verifying Writeback Results";
        for i in 0 to 31 loop
            -- Request Read for v2 (Address: Thread(i) & "10")
            mcu_rd_addr <= std_logic_vector(to_unsigned(i, 5)) & "10";
            wait until rising_edge(clk); -- Clock address into M10K
            wait until falling_edge(clk); -- Wait for data to stabilize
            
            -- Expected value = (Thread_ID * 4 + Component_ID) + 10.0
            assert to_real(to_float(mcu_rd_data(0))) = real(i * 4 + 0) + 10.0 report "Thread " & integer'image(i) & " X mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(1))) = real(i * 4 + 1) + 10.0 report "Thread " & integer'image(i) & " Y mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(2))) = real(i * 4 + 2) + 10.0 report "Thread " & integer'image(i) & " Z mismatch!" severity error;
            assert to_real(to_float(mcu_rd_data(3))) = real(i * 4 + 3) + 10.0 report "Thread " & integer'image(i) & " W mismatch!" severity error;
            
            wait until rising_edge(clk);
        end loop;

        report ">> INTEGRATION TEST COMPLETE: Instruction Issue -> VRF -> FPU Lanes -> Writeback SUCCESSFUL!";
        std.env.stop;
    end process;

end architecture sim;
