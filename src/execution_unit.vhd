library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

-- The overall structure of the execution unit:
--
--                 Register Data
--                       │
--  ┌────────────────────┼────────────────────┐
--  │                    ↓                    │
--  │    ┌──────────────────────────────┐     │
--  │    │       Swizzle Network        │     │
--  │    └───────────────┬──────────────┘     │
--  │        ┌───────────┼────────────┐       │
--  │        ↓           ↓            ↓       │
--  │┌─────────────┐┌────────┐┌──────────────┐│
--  ││FPU Lane (x4)││ALU Lane││Reduction Unit││
--  ││ (pipelined) ││        ││  (pipelined) ││
--  ││             ││        ││              ││
--  ││             ││        ││              ││
--  ││             ││        ││              ││
--  ││             ││        ││              ││
--  ││             ││        ││              ││
--  │└───────┬─────┘└────┬───┘└───────┬──────┘│
--  │        │           │            │       │
--  │        └───────────┼────────────┘       │
--  │                    │                    │
--  └────────────────────┼────────────────────┘
--                       ↓
--                 Writeback Data
--

entity execution_unit is
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        exec_ctrl_in      : in  exec_ctrl_t;
        valid_in          : in  std_logic;
        inst_type_in      : in  std_logic_vector(3 downto 0);
        red_mode_in       : in  std_logic_vector(1 downto 0);
        red_mask_in       : in  std_logic_vector(3 downto 0);
        rd_addr_global_in : in  std_logic_vector(6 downto 0);

        vrf_rs1_data      : in  vector_t;
        vrf_rs2_data      : in  vector_t;
        vrf_rs3_data      : in  vector_t;
        prf_rs1_data      : in  std_logic_vector(3 downto 0);
        prf_rs2_data      : in  std_logic_vector(3 downto 0);

        wb_rd_addr_out    : out std_logic_vector(6 downto 0);
        wb_vrf_data_out   : out vector_t;
        wb_prf_data_out   : out std_logic_vector(3 downto 0);
        wb_vrf_we_out     : out std_logic;
        wb_prf_we_out     : out std_logic;
        wb_mask_out       : out std_logic_vector(3 downto 0);
        
        -- NEW: Pipeline Status Flags
        flush_active_out  : out std_logic
    );
end entity execution_unit;

architecture rtl of execution_unit is

    signal s1_ctrl        : exec_ctrl_t;
    signal s1_valid       : std_logic := '0';
    signal s1_inst_type   : std_logic_vector(3 downto 0);
    signal s1_red_mode    : std_logic_vector(1 downto 0);
    signal s1_red_mask    : std_logic_vector(3 downto 0);
    
    signal s1_prf_rs1     : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2     : std_logic_vector(3 downto 0) := "0000";

    -- NEW: Shift register to track the flush token down the pipe
    signal is_flush_stage1 : std_logic;
    signal flush_shift_reg : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

    signal swiz_a_out     : vector_t;
    signal swiz_b_out     : vector_t;
    signal fpu_en         : std_logic;
    signal red_en         : std_logic;
    signal alu_en         : std_logic;
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;
    signal red_res_scalar : word_t;
    signal alu_res        : word_t;
    signal alu_comp_flag  : std_logic; 
    signal wb_mux_sel_out : std_logic_vector(1 downto 0);

    constant ZERO_FLUSH_REG : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

begin

    -- Identify if the incoming Stage 1 instruction is our Flush Token
    is_flush_stage1 <= '1' when (s1_valid = '1' and s1_ctrl.opcode = OP_FLUSH) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
                flush_shift_reg <= (others => '0');
            else
                s1_valid     <= valid_in;
                s1_ctrl      <= exec_ctrl_in;
                s1_inst_type <= inst_type_in;
                s1_red_mode  <= red_mode_in;
                s1_red_mask  <= red_mask_in;
                s1_prf_rs1   <= prf_rs1_data;
                s1_prf_rs2   <= prf_rs2_data;
                
                -- Shift the flush token down the pipeline
                flush_shift_reg <= flush_shift_reg(FPU_MAX_LATENCY-2 downto 0) & is_flush_stage1;
            end if;
        end if;
    end process;

    -- NEW: Assert flush_active if the token is anywhere in the pipeline (or currently in stage 1)
    flush_active_out <= '1' when (flush_shift_reg /= ZERO_FLUSH_REG) or (is_flush_stage1 = '1') else '0';

    fpu_en <= '1' when (s1_valid = '1' and s1_inst_type = INST_TYPE_FPU) else '0';
    red_en <= '1' when (s1_valid = '1' and s1_inst_type = INST_TYPE_RED) else '0';
    alu_en <= '1' when (s1_valid = '1' and (s1_inst_type = INST_TYPE_ALU or s1_inst_type = INST_TYPE_IMM)) else '0';

    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk => clk, reset => reset, iss_rd_addr => rd_addr_global_in,
            iss_mask => exec_ctrl_in.write_mask, iss_wb_mux => exec_ctrl_in.wb_mux_sel,
            iss_vrf_we => (exec_ctrl_in.vrf_we and valid_in), iss_prf_we => (exec_ctrl_in.prf_we and valid_in),
            wb_rd_addr => wb_rd_addr_out, wb_mask => wb_mask_out, wb_mux_sel => wb_mux_sel_out,
            wb_vrf_we => wb_vrf_we_out, wb_prf_we => wb_prf_we_out
        );

    u_swizzle: entity work.swizzle_network
        port map (
            is_logic_op => s1_ctrl.is_logic_op, vec_a_in => vrf_rs1_data, 
            prf_a_in => s1_prf_rs1, swiz_sel_a => s1_ctrl.swiz_sel_a, vec_a_out => swiz_a_out,
            vec_b_in => vrf_rs2_data, prf_b_in => s1_prf_rs2, swiz_sel_b => s1_ctrl.swiz_sel_b, vec_b_out => swiz_b_out
        );

    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(0), op_b=>swiz_b_out(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>open, comp_flag=>comp_flag_x, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(1), op_b=>swiz_b_out(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open, comp_flag=>comp_flag_y, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(2), op_b=>swiz_b_out(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open, comp_flag=>comp_flag_z, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(3), op_b=>swiz_b_out(3), op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open, comp_flag=>comp_flag_w, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);

    u_reduction: entity work.vector_reduction_unit
        port map (
            clk => clk, reset => reset, valid_in => red_en, vec_a => swiz_a_out, vec_b => swiz_b_out,
            reduce_mask => s1_red_mask, red_mode => s1_red_mode, result => red_res_scalar, valid_out => open
        );

    u_alu: entity work.alu_lane 
        port map (
            clk => clk, reset => reset, opcode => s1_ctrl.opcode, valid_in => alu_en,
            is_load => s1_ctrl.is_load, imm_data => s1_ctrl.imm_data,
            op_a => swiz_a_out(0), op_b => swiz_b_out(0), result => alu_res, 
            comp_flag => alu_comp_flag, valid_out => open
        );

    wb_vrf_data_out <= (fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w) when wb_mux_sel_out = WB_MUX_FPU else 
                       (red_res_scalar, red_res_scalar, red_res_scalar, red_res_scalar) when wb_mux_sel_out = WB_MUX_RED else
                       (alu_res, alu_res, alu_res, alu_res);
                
    wb_prf_data_out <= (alu_comp_flag, alu_comp_flag, alu_comp_flag, alu_comp_flag) when wb_mux_sel_out = WB_MUX_ALU else
                       (comp_flag_w & comp_flag_z & comp_flag_y & comp_flag_x);

end architecture rtl;
