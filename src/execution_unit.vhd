-- =============================================================================
-- FILE: execution_unit.vhd
-- COMPONENT: Execution Unit (Top-Level Execution Datapath)
-- =============================================================================
--
-- PURPOSE:
--   This is the top-level wiring hub for the entire execution datapath. It does
--   not contain any arithmetic logic itself; instead, it instantiates and
--   connects the following sub-units:
--
--     - writeback_controller : Delays WB control signals to align with pipeline
--                              output latency, then drives rd_addr/we/mask.
--     - swizzle_network      : Permutes/broadcasts vector components before they
--                              reach functional units, implementing SIMT swizzle.
--     - fpu_lane (x4)        : Four independent single-precision floating-point
--                              pipelines, one per XYZW vector component.
--     - alu_lane             : Scalar integer ALU (also handles LDI immediates,
--                              THREAD_ID, RESOLUTION, and TIME uniforms).
--     - vector_reduction_unit: Reduces a vector to a scalar (e.g. dot product).
--
--   It also owns the FLUSH token tracking logic (flush_shift_reg), which tells
--   the processor FSM when it is safe to advance past EXEC_WAIT.
--
-- USAGE:
--   Instantiated once by warp_unit.vhd. The pipeline has two explicit register
--   stages before functional units start:
--     S1 (N+1): VRF read data arrives (1-cycle registered read). Control signals
--               are registered into s1_*. Swizzle runs combinationally this cycle.
--     S2 (N+2): Swizzle outputs and all S1 controls are registered into s2_*.
--               Functional units start here with fully stable, registered inputs.
--   The writeback_controller is driven from S2, so its depth equals FPU_MAX_LATENCY
--   exactly — no off-by-one correction required.
--
-- TIMING / LATENCY:
--   - Cycle N  : valid_in asserted; VRF addresses driven; S1 control regs capture.
--   - Cycle N+1: VRF data stable; s1_valid='1'; swizzle runs combinationally.
--                S2 registers capture swiz_a/b_out, s2_ctrl, s2_rd_addr, etc.
--   - Cycle N+2: s2_valid='1'; fpu_en/alu_en/red_en fire; functional units start.
--                writeback_controller loads its pipe(0) this cycle.
--   - Cycle N+2+FPU_MAX_LATENCY: FPU result valid; wb_* outputs aligned.
--   - flush_active_out stays high from the cycle a FLUSH token enters S1 until
--     all preceding writes have committed (FPU_MAX_LATENCY cycles after S1).
--
-- PORTS:
--   clk               - System clock. All state updates on rising edge.
--   reset             - Synchronous active-high reset. Clears s1_valid and
--                       flush_shift_reg; functional units handle their own reset.
--   exec_ctrl_in      - Decoded execution control record (opcodes, masks, mux
--                       selects, WE flags, etc.) from the issue stage. Registered
--                       into S1, then into S2 before reaching the writeback_controller
--                       and functional units.
--   valid_in          - Asserted when exec_ctrl_in carries a valid instruction.
--                       Registered through S1 (s1_valid) and S2 (s2_valid).
--   inst_type_in      - 4-bit instruction class (FPU/ALU/IMM/RED/SYS/...).
--                       Registered into s1_inst_type to gate functional-unit
--                       enable signals in S1.
--   red_mode_in       - 2-bit reduction mode (e.g. sum, min, max, dot).
--                       Registered into s1_red_mode.
--   red_mask_in       - 4-bit per-component enable for reduction.
--                       Registered into s1_red_mask.
--   rd_addr_global_in - 9-bit global destination register address (warp-relative
--                       VRF index). Registered through S1 (s1_rd_addr) and S2
--                       (s2_rd_addr) before reaching the writeback_controller.
--   vrf_rs1_data      - 128-bit (4×32) vector source 1 read from VRF this cycle.
--   vrf_rs2_data      - 128-bit (4×32) vector source 2.
--   vrf_rs3_data      - 128-bit (4×32) vector source 3 (FMA third operand).
--                       Not swizzled; fed straight to fpu_lane op_c ports.
--   prf_rs1_data      - 4-bit predicate source 1 from PRF (one bit per thread
--                       component). Used by swizzle_network for logic ops.
--   prf_rs2_data      - 4-bit predicate source 2 from PRF.
--
--   -- Shader Uniforms --
--   warp_offset_in    - 32-bit warp base address; forwarded to ALU lane so
--                       THREAD_ID instruction can compute absolute thread addresses.
--   thread_id_in      - 5-bit local thread index within the warp; forwarded to
--                       ALU lane for THREAD_ID instruction.
--   frame_width_in    - 16-bit integer; forwarded to ALU lane for RESOLUTION.
--   frame_height_in   - 16-bit integer; forwarded to ALU lane for RESOLUTION.
--   time_ms_in        - 32-bit integer; forwarded to ALU lane for TIME.
--
--   -- Writeback --
--   wb_rd_addr_out    - 9-bit destination address, delayed by writeback_controller
--                       to align with functional-unit output.
--   wb_vrf_data_out   - 128-bit result data to write back to VRF. Each component
--                       is independently muxed from FPU/RED/ALU based on
--                       wb_mux_sel_out (itself delayed by writeback_controller).
--   wb_prf_data_out   - 4-bit predicate result. For ALU: alu_comp_flag replicated
--                       to all 4 bits (scalar comparison → all components equal).
--                       For FPU: independent per-component comp_flag_x/y/z/w,
--                       allowing different XYZW threads to have different results.
--   wb_vrf_we_out     - VRF write enable, delayed to align with result arrival.
--   wb_prf_we_out     - PRF write enable, delayed similarly.
--   wb_mask_out       - 4-bit per-component write mask, delayed to align with
--                       result arrival. Gates which VRF components are updated.
--   flush_active_out  - HIGH while a FLUSH token is anywhere in the execution
--                       pipeline (S1 through the end of the FPU pipe). The
--                       processor FSM must hold EXEC_WAIT until this is LOW,
--                       guaranteeing all prior writes have retired before any
--                       post-flush instruction issues.
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity execution_unit is
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        exec_ctrl_in      : in  exec_ctrl_t;
        valid_in          : in  std_logic;
        inst_type_in      : in  std_logic_vector(3 downto 0);
        red_mode_in       : in  std_logic_vector(1 downto 0);
        red_mask_in       : in  std_logic_vector(3 downto 0);
        rd_addr_global_in : in  std_logic_vector(8 downto 0);

        vrf_rs1_data      : in  vector_t;
        vrf_rs2_data      : in  vector_t;
        vrf_rs3_data      : in  vector_t;
        prf_rs1_data      : in  std_logic_vector(3 downto 0);
        prf_rs2_data      : in  std_logic_vector(3 downto 0);

        warp_offset_in    : in  std_logic_vector(31 downto 0);
        thread_id_in      : in  std_logic_vector(4 downto 0);
        frame_width_in    : in  std_logic_vector(15 downto 0);
        frame_height_in   : in  std_logic_vector(15 downto 0);
        time_ms_in        : in  std_logic_vector(31 downto 0);

        wb_rd_addr_out    : out std_logic_vector(8 downto 0);
        wb_vrf_data_out   : out vector_t;
        wb_prf_data_out   : out std_logic_vector(3 downto 0);
        wb_vrf_we_out     : out std_logic;
        wb_prf_we_out     : out std_logic;
        wb_mask_out       : out std_logic_vector(3 downto 0);
        
        -- Memory block transfer snooping
        mem_store_valid   : out std_logic;
        mem_store_data    : out vector_t;
        mem_store_thread_id : out std_logic_vector(4 downto 0);
        
        -- Pipeline Status Flags
        flush_active_out  : out std_logic
    );
end entity execution_unit;

architecture rtl of execution_unit is

    -- -------------------------------------------------------------------------
    -- S1 and S2 Pipeline Registers
    -- -------------------------------------------------------------------------
    signal s1_ctrl        : exec_ctrl_t;
    signal s1_valid       : std_logic := '0';
    signal s1_inst_type   : std_logic_vector(3 downto 0);
    signal s1_red_mode    : std_logic_vector(1 downto 0);
    signal s1_red_mask    : std_logic_vector(3 downto 0);
    signal s1_prf_rs1     : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2     : std_logic_vector(3 downto 0) := "0000";
    signal s1_thread_id   : std_logic_vector(4 downto 0) := (others => '0');
    signal s1_warp_offset : std_logic_vector(31 downto 0) := (others => '0');
    signal s1_frame_width : std_logic_vector(15 downto 0) := (others => '0');
    signal s1_frame_height: std_logic_vector(15 downto 0) := (others => '0');
    signal s1_time_ms     : std_logic_vector(31 downto 0) := (others => '0');
    signal s1_rd_addr     : std_logic_vector(8 downto 0)  := (others => '0');

    signal s2_valid       : std_logic := '0';
    signal s2_ctrl        : exec_ctrl_t;
    signal s2_inst_type   : std_logic_vector(3 downto 0);
    signal s2_red_mode    : std_logic_vector(1 downto 0);
    signal s2_red_mask    : std_logic_vector(3 downto 0);
    signal s2_thread_id   : std_logic_vector(4 downto 0) := (others => '0');
    signal s2_warp_offset : std_logic_vector(31 downto 0) := (others => '0');
    signal s2_frame_width : std_logic_vector(15 downto 0) := (others => '0');
    signal s2_frame_height: std_logic_vector(15 downto 0) := (others => '0');
    signal s2_time_ms     : std_logic_vector(31 downto 0) := (others => '0');
    signal s2_swiz_a      : vector_t;
    signal s2_swiz_b      : vector_t;
    signal s2_rs3         : vector_t;
    signal s2_rd_addr     : std_logic_vector(8 downto 0)  := (others => '0');

    -- -------------------------------------------------------------------------
    -- FLUSH Token Tracking
    -- -------------------------------------------------------------------------
    signal is_flush_stage1 : std_logic;
    signal flush_shift_reg : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

    signal swiz_a_out      : vector_t;
    signal swiz_b_out      : vector_t;

    signal fpu_en          : std_logic;
    signal red_en          : std_logic;
    signal alu_en          : std_logic;

    -- Per-lane FPU results
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;

    -- Reduction result
    signal red_res_scalar : word_t;
    
    -- ALU result
    signal alu_res        : word_t;
    signal alu_comp_flag  : std_logic;

    -- Writeback mux select
    signal wb_mux_sel_out : std_logic_vector(1 downto 0);

    constant ZERO_FLUSH_REG : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

begin

    -- Detect FLUSH token at S1.
    is_flush_stage1 <= '1' when (s1_valid = '1' and s1_ctrl.opcode = OP_FLUSH) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1_valid <= '0';
                s2_valid <= '0';
                flush_shift_reg <= (others => '0');
            else
                -- S0 → S1: register all control inputs so they arrive coincident
                -- with vrf_rs*_data (which has a 1-cycle registered-read latency).
                s1_valid        <= valid_in;
                s1_ctrl         <= exec_ctrl_in;
                s1_inst_type    <= inst_type_in;
                s1_red_mode     <= red_mode_in;
                s1_red_mask     <= red_mask_in;
                s1_prf_rs1      <= prf_rs1_data;
                s1_prf_rs2      <= prf_rs2_data;
                
                -- Uniform routing
                s1_thread_id    <= thread_id_in;
                s1_warp_offset  <= warp_offset_in;
                s1_frame_width  <= frame_width_in;
                s1_frame_height <= frame_height_in;
                s1_time_ms      <= time_ms_in;
                
                s1_rd_addr      <= rd_addr_global_in;

                -- S1 → S2: register swizzle outputs (combinational in S1) and
                -- all remaining S1 controls. Functional units start from S2.
                s2_valid        <= s1_valid;
                s2_ctrl         <= s1_ctrl;
                s2_inst_type    <= s1_inst_type;
                s2_red_mode     <= s1_red_mode;
                s2_red_mask     <= s1_red_mask;
                
                -- Uniform routing
                s2_thread_id    <= s1_thread_id;
                s2_warp_offset  <= s1_warp_offset;
                s2_frame_width  <= s1_frame_width;
                s2_frame_height <= s1_frame_height;
                s2_time_ms      <= s1_time_ms;
                
                s2_swiz_a       <= swiz_a_out;
                s2_swiz_b       <= swiz_b_out;
                s2_rs3          <= vrf_rs3_data;
                s2_rd_addr      <= s1_rd_addr;

                -- Shift the flush token down the pipeline.
                flush_shift_reg <= flush_shift_reg(FPU_MAX_LATENCY-2 downto 0) & is_flush_stage1;
            end if;
        end if;
    end process;

    flush_active_out <= '1' when (flush_shift_reg /= ZERO_FLUSH_REG) or (is_flush_stage1 = '1') else '0';

    fpu_en <= '1' when (s2_valid = '1' and s2_inst_type = INST_TYPE_FPU) else '0';
    red_en <= '1' when (s2_valid = '1' and s2_inst_type = INST_TYPE_RED) else '0';
    alu_en <= '1' when (s2_valid = '1' and (s2_inst_type = INST_TYPE_ALU or s2_inst_type = INST_TYPE_IMM)) else '0';

    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk => clk, reset => reset, iss_rd_addr => s2_rd_addr,
            iss_mask => s2_ctrl.write_mask, iss_wb_mux => s2_ctrl.wb_mux_sel,
            iss_vrf_we => (s2_ctrl.vrf_we and s2_valid), iss_prf_we => (s2_ctrl.prf_we and s2_valid),
            wb_rd_addr => wb_rd_addr_out, wb_mask => wb_mask_out, wb_mux_sel => wb_mux_sel_out,
            wb_vrf_we => wb_vrf_we_out, wb_prf_we => wb_prf_we_out
        );

    u_swizzle: entity work.swizzle_network
        port map (
            is_logic_op => s1_ctrl.is_logic_op, vec_a_in => vrf_rs1_data,
            prf_a_in => s1_prf_rs1, swiz_sel_a => s1_ctrl.swiz_sel_a, vec_a_out => swiz_a_out,
            vec_b_in => vrf_rs2_data, prf_b_in => s1_prf_rs2, swiz_sel_b => s1_ctrl.swiz_sel_b, vec_b_out => swiz_b_out
        );

    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s2_ctrl.opcode, valid_in=>fpu_en, op_a=>s2_swiz_a(0), op_b=>s2_swiz_b(0), op_c=>s2_rs3(0), result=>fpu_res_x, valid_out=>open, comp_flag=>comp_flag_x, cmp_invert=>s2_ctrl.cmp_invert, cmp_swap=>s2_ctrl.cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s2_ctrl.opcode, valid_in=>fpu_en, op_a=>s2_swiz_a(1), op_b=>s2_swiz_b(1), op_c=>s2_rs3(1), result=>fpu_res_y, valid_out=>open, comp_flag=>comp_flag_y, cmp_invert=>s2_ctrl.cmp_invert, cmp_swap=>s2_ctrl.cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s2_ctrl.opcode, valid_in=>fpu_en, op_a=>s2_swiz_a(2), op_b=>s2_swiz_b(2), op_c=>s2_rs3(2), result=>fpu_res_z, valid_out=>open, comp_flag=>comp_flag_z, cmp_invert=>s2_ctrl.cmp_invert, cmp_swap=>s2_ctrl.cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s2_ctrl.opcode, valid_in=>fpu_en, op_a=>s2_swiz_a(3), op_b=>s2_swiz_b(3), op_c=>s2_rs3(3), result=>fpu_res_w, valid_out=>open, comp_flag=>comp_flag_w, cmp_invert=>s2_ctrl.cmp_invert, cmp_swap=>s2_ctrl.cmp_swap);

    u_reduction: entity work.vector_reduction_unit
        port map (
            clk => clk, reset => reset, valid_in => red_en, vec_a => s2_swiz_a, vec_b => s2_swiz_b,
            reduce_mask => s2_red_mask, red_mode => s2_red_mode, result => red_res_scalar, valid_out => open
        );

    -- alu_lane: scalar integer ALU. Operates ONLY on component 0 of the swizzled
    -- buses (swiz_a_out(0), swiz_b_out(0)).
    -- WHY only component 0: integer operations are inherently scalar in this ISA.
    -- The same alu_res is written back to all four VRF components (see writeback
    -- mux below); the write_mask then selects which components are actually updated.
    --
    -- is_load='1' (set by the decoder for INST_TYPE_IMM) tells the ALU to switch
    -- from a two-register operation to an immediate-load (LDI_LO/LDI_HI) decode.
    -- imm_data carries the 16-bit immediate value from the instruction word.
    --
    -- thread_id, warp_offset, frame_width, frame_height, and time_ms support 
    -- shader uniforms. These route external constants directly into the ALU.
    u_alu: entity work.alu_lane
        port map (
            clk          => clk, 
            reset        => reset, 
            opcode       => s2_ctrl.opcode, 
            valid_in     => alu_en,
            is_load      => s2_ctrl.is_load, 
            imm_data     => s2_ctrl.imm_data,
            op_a         => s2_swiz_a(0), 
            op_b         => s2_swiz_b(0),
            thread_id    => s2_thread_id, 
            warp_offset  => s2_warp_offset,
            frame_width  => s2_frame_width,
            frame_height => s2_frame_height,
            time_ms      => s2_time_ms,
            result       => alu_res, 
            comp_flag    => alu_comp_flag, 
            valid_out    => open
        );

    -- VRF writeback data mux: selects the appropriate result for each of the four
    -- vector components. wb_mux_sel_out is the DELAYED mux select from
    -- writeback_controller, so it is guaranteed to be valid on the same cycle
    -- that the functional unit results appear here.
    wb_vrf_data_out(0) <= fpu_res_x      when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(1) <= fpu_res_y      when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(2) <= fpu_res_z      when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(3) <= fpu_res_w      when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;

    -- PRF writeback data mux:
    -- WHY two different packing strategies:
    --   ALU comparison (ICMP): integer compare is scalar → all four predicate bits
    --     get the same alu_comp_flag. Every active thread component sees an
    --     identical comparison result (e.g. all bits = 1 if condition is true).
    --   FPU comparison (FCMP): floating-point compare is per-component → each of
    --     the four comp_flag_x/y/z/w signals can differ. This allows, for example,
    --     an FCMP to produce P0={X=1,Y=0,Z=1,W=0} when components differ in value.
    wb_prf_data_out <= (alu_comp_flag & alu_comp_flag & alu_comp_flag & alu_comp_flag) when wb_mux_sel_out = WB_MUX_ALU else
                       (comp_flag_w & comp_flag_z & comp_flag_y & comp_flag_x);

    -- ========================================================================
    -- MEMORY BLOCK TRANSFER SNOOPING
    -- ========================================================================
    -- Provide valid memory data to memory unit during execution of OP_RETURN.
    -- OP_RETURN doesn't write back to VRF via the writeback_controller, so it
    -- is routed directly from the S1 stage to the memory unit. Reads a source
    -- register and packs it into the pixel buffer.
    mem_store_valid <= '1' when (s1_valid = '1' and s1_ctrl.opcode = OP_RETURN) else '0';
    mem_store_data <= vrf_rs1_data;
    mem_store_thread_id <= s1_thread_id;

end architecture rtl;
