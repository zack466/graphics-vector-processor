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
--     - alu_lane             : Scalar integer ALU (also handles LDI immediates).
--     - vector_reduction_unit: Reduces a vector to a scalar (e.g. dot product).
--
--   It also owns the FLUSH token tracking logic (flush_shift_reg), which tells
--   the processor FSM when it is safe to advance past EXEC_WAIT.
--
-- USAGE:
--   Instantiated once by processor.vhd. The VRF has a 1-cycle registered-read
--   latency: addresses are driven on the same cycle as valid_in, and read data
--   appears one cycle later. The execution unit's S1 control registers are timed
--   to match this: valid_in and inst_type_in are registered into s1_valid and
--   s1_inst_type so that the functional-unit enables fire on the same cycle the
--   VRF data arrives. The data path (VRF output → swizzle_network → functional
--   units) contains no additional register inside this unit.
--
-- TIMING / LATENCY:
--   - Cycle N  : valid_in asserted; VRF addresses driven; S1 control regs capture.
--   - Cycle N+1: VRF data stable on vrf_rs*_data; s1_valid='1'; fpu_en/alu_en
--                fire; swiz_a/b_out combinationally computed; functional units start.
--   - Cycle N+1+FPU_MAX_LATENCY: FPU result valid; writeback_controller outputs
--                aligned wb_* signals.
--   - writeback_controller is driven by the UNREGISTERED (S0) signals
--     exec_ctrl_in/valid_in, and internally delays by FPU_MAX_LATENCY+1 cycles.
--     The "+1" accounts for the VRF's 1-cycle read latency (which delays the
--     functional-unit start by one cycle relative to valid_in).
--   - flush_active_out stays high from the cycle a FLUSH token enters S1 until
--     FPU_MAX_LATENCY cycles after it leaves S1, guaranteeing all preceding
--     writes have committed before the FSM advances.
--
-- PORTS:
--   clk               - System clock. All state updates on rising edge.
--   reset             - Synchronous active-high reset. Clears s1_valid and
--                       flush_shift_reg; functional units handle their own reset.
--   exec_ctrl_in      - Decoded execution control record (opcodes, masks, mux
--                       selects, WE flags, etc.) from the issue stage. Fed
--                       DIRECTLY to writeback_controller (unregistered) so that
--                       the WB delay of FPU_MAX_LATENCY+1 correctly accounts for
--                       the VRF read latency plus the FPU pipeline depth.
--   valid_in          - Asserted when exec_ctrl_in carries a valid instruction.
--                       Also fed DIRECTLY to writeback_controller (unregistered).
--   inst_type_in      - 4-bit instruction class (FPU/ALU/IMM/RED/SYS/...).
--                       Registered into s1_inst_type to gate functional-unit
--                       enable signals in S1.
--   red_mode_in       - 2-bit reduction mode (e.g. sum, min, max, dot).
--                       Registered into s1_red_mode.
--   red_mask_in       - 4-bit per-component enable for reduction.
--                       Registered into s1_red_mask.
--   rd_addr_global_in - 9-bit global destination register address (warp-relative
--                       VRF index). Fed DIRECTLY to writeback_controller so its
--                       FPU_MAX_LATENCY+1 delay aligns the address with the
--                       functional-unit result at writeback time.
--   vrf_rs1_data      - 128-bit (4×32) vector source 1 read from VRF this cycle.
--   vrf_rs2_data      - 128-bit (4×32) vector source 2.
--   vrf_rs3_data      - 128-bit (4×32) vector source 3 (FMA third operand).
--                       Not swizzled; fed straight to fpu_lane op_c ports.
--   prf_rs1_data      - 4-bit predicate source 1 from PRF (one bit per thread
--                       component). Used by swizzle_network for logic ops.
--   prf_rs2_data      - 4-bit predicate source 2 from PRF.
--   warp_offset_in    - 32-bit warp base address; forwarded to ALU lane so
--                       GETID-style instructions can compute thread addresses.
--   thread_id_in      - 5-bit local thread index within the warp; forwarded to
--                       ALU lane for thread-ID instructions.
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
        rd_addr_global_in : in  std_logic_vector(8 downto 0);

        vrf_rs1_data      : in  vector_t;
        vrf_rs2_data      : in  vector_t;
        vrf_rs3_data      : in  vector_t;
        prf_rs1_data      : in  std_logic_vector(3 downto 0);
        prf_rs2_data      : in  std_logic_vector(3 downto 0);

        warp_offset_in    : in  std_logic_vector(31 downto 0);
        thread_id_in      : in  std_logic_vector(4 downto 0);

        wb_rd_addr_out    : out std_logic_vector(8 downto 0);
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

    -- -------------------------------------------------------------------------
    -- S1 Control Registers
    -- WHY: The VRF has a 1-cycle registered-read latency, so vrf_rs*_data does
    -- not reflect the addresses driven on cycle N until cycle N+1. These registers
    -- delay the control signals (inst_type, opcode, swiz_sel, etc.) by the same
    -- one cycle so they are synchronous with the arriving VRF data.
    -- NOTE: exec_ctrl_in and valid_in are deliberately NOT registered here;
    -- they go directly to writeback_controller so its internal delay of
    -- FPU_MAX_LATENCY+1 accounts for the VRF's 1-cycle read latency automatically.
    -- The data path (vrf_rs*_data → swizzle_network → functional units) is purely
    -- combinational within this unit; no additional register sits on that path.
    -- -------------------------------------------------------------------------
    signal s1_ctrl        : exec_ctrl_t;
    signal s1_valid       : std_logic := '0';
    signal s1_inst_type   : std_logic_vector(3 downto 0);
    signal s1_red_mode    : std_logic_vector(1 downto 0);
    signal s1_red_mask    : std_logic_vector(3 downto 0);

    -- PRF data registered into S1 so swizzle_network sees stable predicate bits
    -- on the same cycle as the registered VRF data.
    signal s1_prf_rs1     : std_logic_vector(3 downto 0) := "0000";
    signal s1_prf_rs2     : std_logic_vector(3 downto 0) := "0000";
    -- thread_id registered into S1 so ALU sees it coincident with swizzled operands.
    signal s1_thread_id   : std_logic_vector(4 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- FLUSH Token Tracking
    -- WHY: A FLUSH instruction is a sentinel that marks the end of a batch of
    -- instructions. The processor FSM must not advance until ALL instructions
    -- preceding the flush have written back. Because the FPU is pipelined to
    -- FPU_MAX_LATENCY depth, we must wait that many additional cycles after the
    -- FLUSH enters S1. flush_shift_reg is a one-hot shift register that tracks
    -- the token as it travels down the FPU pipeline depth.
    -- -------------------------------------------------------------------------
    signal is_flush_stage1 : std_logic;
    signal flush_shift_reg : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

    -- Swizzled operand buses: outputs of swizzle_network, inputs to all FPU lanes
    -- and the ALU lane (which only consumes element 0).
    signal swiz_a_out     : vector_t;
    signal swiz_b_out     : vector_t;

    -- Functional-unit enable strobes, derived from s1_inst_type (the REGISTERED
    -- type). Using the registered type is critical: it ensures the enable only
    -- asserts when valid S1 data is present, not speculatively on S0.
    signal fpu_en         : std_logic;
    signal red_en         : std_logic;
    signal alu_en         : std_logic;

    -- Per-lane FPU results (one 32-bit word per XYZW component)
    signal fpu_res_x, fpu_res_y, fpu_res_z, fpu_res_w : word_t;
    -- Per-lane FPU comparison flags. Independent per component so that e.g.
    -- FCMP_LT can produce different results for X vs Y vs Z vs W threads.
    signal comp_flag_x, comp_flag_y, comp_flag_z, comp_flag_w : std_logic;

    -- Reduction result: a single scalar word broadcast to all VRF components
    signal red_res_scalar : word_t;
    -- ALU result: scalar, replicated to all four VRF components at writeback
    signal alu_res        : word_t;
    -- ALU comparison flag: scalar, replicated to all four PRF bits at writeback
    -- (all threads see the same integer comparison result)
    signal alu_comp_flag  : std_logic;

    -- Writeback mux select, delayed by writeback_controller to align with the
    -- cycle when functional-unit results actually appear on the output wires.
    signal wb_mux_sel_out : std_logic_vector(1 downto 0);

    -- All-zeros constant for flush_shift_reg comparison (avoids synthesizing a
    -- reduction OR tree in a /= expression against a literal).
    constant ZERO_FLUSH_REG : std_logic_vector(FPU_MAX_LATENCY-1 downto 0) := (others => '0');

begin

    -- Detect FLUSH token at S1. Checked combinationally so it can feed the
    -- shift register on the SAME rising edge that the token exists in S1,
    -- rather than incurring an extra cycle of delay.
    is_flush_stage1 <= '1' when (s1_valid = '1' and s1_ctrl.opcode = OP_FLUSH) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- On reset: invalidate the S1 stage so no stale instruction
                -- accidentally enables a functional unit or blocks flush detection.
                s1_valid <= '0';
                -- Clear the shift register so flush_active_out deasserts immediately
                -- after reset, allowing the FSM to start without stalling.
                flush_shift_reg <= (others => '0');
            else
                -- S0 → S1 pipeline register. All inputs captured here.
                -- exec_ctrl_in/valid_in/rd_addr_global_in are intentionally NOT
                -- registered here; see writeback_controller port map comment.
                s1_valid     <= valid_in;
                s1_ctrl      <= exec_ctrl_in;
                s1_inst_type <= inst_type_in;
                s1_red_mode  <= red_mode_in;
                s1_red_mask  <= red_mask_in;
                s1_prf_rs1   <= prf_rs1_data;
                s1_prf_rs2   <= prf_rs2_data;
                s1_thread_id <= thread_id_in;

                -- Shift the flush token down the pipeline.
                -- Bit 0 of flush_shift_reg corresponds to one cycle after S1;
                -- bit FPU_MAX_LATENCY-1 corresponds to the last FPU output stage.
                -- The LSB is loaded with is_flush_stage1 each cycle.
                flush_shift_reg <= flush_shift_reg(FPU_MAX_LATENCY-2 downto 0) & is_flush_stage1;
            end if;
        end if;
    end process;

    -- flush_active_out: HIGH whenever the FLUSH token is anywhere in the pipeline.
    -- The OR of is_flush_stage1 covers the cycle the token is in S1 but before
    -- it has been shifted into flush_shift_reg (shift happens on the NEXT edge).
    -- The processor FSM must hold EXEC_WAIT as long as this is asserted.
    flush_active_out <= '1' when (flush_shift_reg /= ZERO_FLUSH_REG) or (is_flush_stage1 = '1') else '0';

    -- Functional-unit enable strobes: gated on s1_valid AND the registered
    -- instruction type. Using s1_inst_type (registered) rather than inst_type_in
    -- (combinational) ensures enables are synchronous with the S1 operand data.
    fpu_en <= '1' when (s1_valid = '1' and s1_inst_type = INST_TYPE_FPU) else '0';
    red_en <= '1' when (s1_valid = '1' and s1_inst_type = INST_TYPE_RED) else '0';
    -- WHY INST_TYPE_IMM here: LDI_LO and LDI_HI are encoded as IMM instructions
    -- but are executed by the ALU lane (which decodes the is_load flag to switch
    -- to immediate-load behavior). Both types share the same ALU lane path.
    alu_en <= '1' when (s1_valid = '1' and (s1_inst_type = INST_TYPE_ALU or s1_inst_type = INST_TYPE_IMM)) else '0';

    -- writeback_controller: delays all WB control signals by FPU_MAX_LATENCY+1
    -- cycles so they arrive at the register file on the same cycle as the FPU
    -- result data.
    --
    -- WHY unregistered inputs (exec_ctrl_in, valid_in, rd_addr_global_in):
    --   The functional units start one cycle after valid_in, because the VRF
    --   read data takes one cycle to appear. The writeback_controller's delay of
    --   FPU_MAX_LATENCY+1 encodes this: the "+1" is the VRF read latency, not
    --   an internal pipeline register. Feeding registered (S1) signals would
    --   make the WB signals arrive one cycle late relative to the FPU output.
    u_wb_ctrl: entity work.writeback_controller
        port map (
            clk => clk, reset => reset, iss_rd_addr => rd_addr_global_in,
            iss_mask => exec_ctrl_in.write_mask, iss_wb_mux => exec_ctrl_in.wb_mux_sel,
            iss_vrf_we => (exec_ctrl_in.vrf_we and valid_in), iss_prf_we => (exec_ctrl_in.prf_we and valid_in),
            wb_rd_addr => wb_rd_addr_out, wb_mask => wb_mask_out, wb_mux_sel => wb_mux_sel_out,
            wb_vrf_we => wb_vrf_we_out, wb_prf_we => wb_prf_we_out
        );

    -- swizzle_network: permutes/broadcasts vector component data before it reaches
    -- the functional unit inputs. Both the data path (vrf_rs*_data in, swiz_*_out)
    -- and the connection to the functional units are purely combinational — there
    -- is no register between the VRF output and the FPU/ALU/reduction inputs.
    -- s1_ctrl.swiz_sel_a/b are the registered swizzle selectors, aligned with the
    -- VRF read data that appears one cycle after valid_in.
    --
    -- When is_logic_op='1' (PAND/POR/PXOR), the swizzle network routes PRF
    -- predicate bits rather than VRF float data into the lanes.
    u_swizzle: entity work.swizzle_network
        port map (
            is_logic_op => s1_ctrl.is_logic_op, vec_a_in => vrf_rs1_data,
            prf_a_in => s1_prf_rs1, swiz_sel_a => s1_ctrl.swiz_sel_a, vec_a_out => swiz_a_out,
            vec_b_in => vrf_rs2_data, prf_b_in => s1_prf_rs2, swiz_sel_b => s1_ctrl.swiz_sel_b, vec_b_out => swiz_b_out
        );

    -- Four FPU lanes (u_lane_x/y/z/w): one per vector component.
    -- WHY four identical instances rather than a loop: explicit instantiation
    -- makes it straightforward to tie different swiz_a/b/c component indices to
    -- each lane and keeps the hierarchy visible in simulation waveforms.
    --
    -- All four lanes share: opcode, valid_in (fpu_en), cmp_invert, cmp_swap.
    -- Each lane receives its own component slice of the swizzled operand buses.
    -- vrf_rs3_data (op_c) is NOT swizzled — swizzle only applies to rs1/rs2.
    --
    -- valid_out is left open because the writeback_controller drives WB timing;
    -- we do not need a separate valid chain from the FPU lanes themselves.
    u_lane_x: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(0), op_b=>swiz_b_out(0), op_c=>vrf_rs3_data(0), result=>fpu_res_x, valid_out=>open, comp_flag=>comp_flag_x, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_y: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(1), op_b=>swiz_b_out(1), op_c=>vrf_rs3_data(1), result=>fpu_res_y, valid_out=>open, comp_flag=>comp_flag_y, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_z: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(2), op_b=>swiz_b_out(2), op_c=>vrf_rs3_data(2), result=>fpu_res_z, valid_out=>open, comp_flag=>comp_flag_z, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);
    u_lane_w: entity work.fpu_lane port map (clk=>clk, reset=>reset, opcode=>s1_ctrl.opcode, valid_in=>fpu_en, op_a=>swiz_a_out(3), op_b=>swiz_b_out(3), op_c=>vrf_rs3_data(3), result=>fpu_res_w, valid_out=>open, comp_flag=>comp_flag_w, cmp_invert=>s1_ctrl.cmp_invert, cmp_swap=>s1_ctrl.cmp_swap);

    -- vector_reduction_unit: collapses a vector (or pair of vectors) to a single
    -- scalar using the configured red_mode (sum, min, max, dot-product, etc.).
    -- red_mask gates which components participate in the reduction.
    -- The result is a single word broadcast to all four wb_vrf_data_out components
    -- when wb_mux_sel = WB_MUX_RED, writing the same scalar to every active lane.
    u_reduction: entity work.vector_reduction_unit
        port map (
            clk => clk, reset => reset, valid_in => red_en, vec_a => swiz_a_out, vec_b => swiz_b_out,
            reduce_mask => s1_red_mask, red_mode => s1_red_mode, result => red_res_scalar, valid_out => open
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
    -- thread_id and warp_offset support GETID-style instructions that embed the
    -- hardware thread identity into a register (used for parallel address generation).
    u_alu: entity work.alu_lane
        port map (
            clk => clk, reset => reset, opcode => s1_ctrl.opcode, valid_in => alu_en,
            is_load => s1_ctrl.is_load, imm_data => s1_ctrl.imm_data,
            op_a => swiz_a_out(0), op_b => swiz_b_out(0),
            thread_id => s1_thread_id, warp_offset => warp_offset_in,
            result => alu_res, comp_flag => alu_comp_flag, valid_out => open
        );

    -- VRF writeback data mux: selects the appropriate result for each of the four
    -- vector components. wb_mux_sel_out is the DELAYED mux select from
    -- writeback_controller, so it is guaranteed to be valid on the same cycle
    -- that the functional unit results appear here.
    --
    -- FPU path: each component gets its own lane result (independent XYZW data).
    -- RED path: all four components receive the same scalar reduction result,
    --           which is the intended behavior (broadcast scalar to vector register).
    -- ALU/default path: all four components receive the same scalar ALU result.
    --   The write_mask will gate which components are actually stored in the VRF.
    wb_vrf_data_out(0) <= fpu_res_x     when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(1) <= fpu_res_y     when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(2) <= fpu_res_z     when wb_mux_sel_out = WB_MUX_FPU else
                          red_res_scalar when wb_mux_sel_out = WB_MUX_RED else
                          alu_res;
    wb_vrf_data_out(3) <= fpu_res_w     when wb_mux_sel_out = WB_MUX_FPU else
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

end architecture rtl;
