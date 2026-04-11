-- ============================================================================
-- COMPONENT: processor
-- ============================================================================
-- PURPOSE:
--   Top-level structural entity for the SIMT vector processor.  It wires
--   together every subsystem — instruction memory, IFU, decoder, issuer,
--   execution unit, memory unit, VRF, and PRF — and contains the scalar FSM
--   that sequences instruction execution.  No datapath logic lives here;
--   this entity is pure glue and control.
--
-- SUBSYSTEM MAP:
--   u_imem   : instruction_memory  — M10K-backed program store (1-cycle latency)
--   u_ifu    : instruction_fetch_unit — PC logic, SIMT divergence stack, exec-mask
--   u_decode : instruction_decoder — combinational: instruction word → control records
--   u_issue  : instruction_issue   — cycles through all 32 thread IDs, driving VRF reads
--   u_exec   : execution_unit      — FPU / ALU / RED pipelines + writeback
--   u_mem    : memory_unit         — scatter/gather MCU + Avalon bridge
--   u_vrf    : vector_reg_file     — 512-entry dual-port register file (Port A = exec, Port B = mem)
--   u_prf    : predicate_reg_file  — 512-entry predicate file; also collapses predicate → branch mask
--
-- PROCESSOR FSM STATES AND RATIONALE:
--   HALTED        : Idle.  Waits for csr_run='1' from the host before fetching.
--                   If do_force_pc is also set when csr_run rises, skip directly
--                   to ADVANCE_PC to apply the forced PC before the first fetch.
--
--   FETCH_ADDR    : First fetch wait cycle.  instruction_memory is M10K BRAM,
--                   which has a 1-cycle registered-read latency: the address
--                   must be stable for one cycle before data appears.  The IFU
--                   is STALLED here (ifu_stall='1') so the PC does not advance
--                   while we are waiting.
--
--   FETCH_DATA    : Second fetch wait cycle.  The IFU pipeline has its own
--                   internal register stage before presenting instruction_out.
--                   One cycle is insufficient; two guarantees stable data at
--                   DECODE regardless of IFU implementation details.
--
--   DECODE        : Instruction is stable on ifu_inst_out.  The FSM inspects
--                   the bottom 4 bits (INST_TYPE) and dispatches:
--                   MEM              → pulse mem_op_valid='1' for 1 cycle → MEM_WAIT
--                   SYS / OP_RETURN  → deassert csr_run, go to HALTED (no PC advance)
--                   SYS / OP_BREAK   → deassert csr_run + set break_hit, go to ADVANCE_PC
--                                      (PC advances so BREAK is not re-hit on resume)
--                   SYS / OP_FLUSH   → assert iss_valid_in='1', go to EXEC_WAIT
--                                      (FLUSH token must drain FPU_MAX_LATENCY cycles)
--                   SYS / OP_INT     → raise irq_pending, go to ADVANCE_PC (non-blocking)
--                   CTRL             → IFU handles PC update combinationally from
--                                      dec_pc / active_pc_ctrl; go straight to ADVANCE_PC
--                   FPU/ALU/IMM/RED  → assert iss_valid_in='1' → EXEC_WAIT
--
--   EXEC_WAIT     : Waits for two independent conditions:
--                   (a) iss_issue_valid='0': the issuer has stepped through all
--                       32 thread IDs (one per cycle) and finished dispatching.
--                   (b) exec_flush_active='0': the execution pipeline has drained.
--                   For arithmetic instructions (b) is always satisfied by the
--                   time (a) becomes true, so the state exits quickly.
--                   For FLUSH instructions, the FLUSH token must propagate
--                   FPU_MAX_LATENCY=28 cycles through the pipeline; this is what
--                   makes exec_flush_active stay high until all in-flight results
--                   have committed.
--
--   MEM_WAIT      : Spins until mem_stall deasserts.  The MCU drives mem_stall
--                   combinationally, so it is already asserted on the same cycle
--                   as the mem_op_valid pulse.  All scatter/gather memory
--                   traffic (including DDR3 waitrequest back-pressure) is
--                   absorbed here.  The FSM goes directly from DECODE→MEM_WAIT.
--
--   ADVANCE_PC    : Deasserts ifu_stall for exactly ONE clock cycle.  The IFU
--                   samples active_pc_ctrl during this cycle to compute the
--                   next PC (branch taken / not-taken / sequential), then
--                   re-presents the updated PC as ifu_imem_addr.  The FSM
--                   immediately returns to FETCH_ADDR on the following cycle.
--
-- PORT DESCRIPTIONS:
--   clk               : System clock.  All state registers are rising-edge.
--   reset             : Synchronous active-high reset.  Drives FSM to HALTED.
--   avm_*             : Avalon-MM master port to external DDR3 SDRAM, wired
--                       directly through to memory_unit.
--   prog_we           : Write-enable for instruction memory programming.
--   prog_wr_addr      : IMEM_ADDR_WIDTH-bit word address for programming.
--   prog_wr_data      : 32-bit instruction word to write into IMEM.
--   csr_address       : 3-bit CSR select (see CSR_ADDR_* constants).
--   csr_write         : Avalon-MM write strobe from host.
--   csr_writedata     : 32-bit data written by host.
--   csr_read          : Avalon-MM read strobe (read data available same cycle).
--   csr_readdata      : Combinational read-data mux output.
--   host_irq_out      : Level-sensitive interrupt line to host; asserted while
--                       irq_pending='1' (cleared by W1C write to CSR_ADDR_IRQ_ACK).
--
-- TIMING / LATENCY CONSTRAINTS:
--   - csr_run must be asserted at least 1 cycle before the FSM exits HALTED.
--   - prog_we writes are single-cycle; do not overlap with execution (IMEM is
--     a simple dual-port BRAM without write-first semantics).
--   - Host CSR writes take effect on the cycle after csr_write is asserted
--     (registered in the CSR process).
--   - A write to CSR_ADDR_START_PC sets do_force_pc='1'; the forced jump is
--     consumed in the next ADVANCE_PC cycle, after which do_force_pc clears.
--   - Minimum instruction throughput is 2 cycles (ADVANCE_PC + FETCH_ADDR/DATA +
--     DECODE) for CTRL instructions.  Arithmetic instructions cost that plus
--     32 issue cycles (one per thread).  Memory instructions cost that plus
--     DDR3 round-trip latency.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity processor is
    generic (
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Avalon-MM Master (To DDR3 via Memory Unit)
        -- ==========================================
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_byteenable    : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avm_read          : out std_logic;
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic;

        -- ==========================================
        -- Instruction Memory Programming Interface
        -- ==========================================
        prog_we           : in  std_logic;
        prog_wr_addr      : in  std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0);
        prog_wr_data      : in  word_t;

        -- ==========================================
        -- CSR Avalon-MM Slave (External Control)
        -- ==========================================
        csr_address       : in  std_logic_vector(2 downto 0);
        csr_write         : in  std_logic;
        csr_writedata     : in  std_logic_vector(31 downto 0);
        csr_read          : in  std_logic;
        csr_readdata      : out std_logic_vector(31 downto 0);
        host_irq_out      : out std_logic
    );
end entity processor;

architecture structural of processor is

    -- ========================================================================
    -- PROCESSOR STATE MACHINE
    -- ========================================================================
    -- WHY seven states rather than eight:
    --   FETCH_ADDR/FETCH_DATA exist because M10K BRAM has a 1-cycle registered
    --   read latency AND the IFU has its own pipeline register — two cycles total.
    --   MEM_WAIT_START was previously needed because the MCU asserted mem_stall
    --   one cycle after mem_op_valid.  Now that mem_stall is combinational in the
    --   MCU (asserts on the same cycle as mem_op_valid), DECODE can go directly
    --   to MEM_WAIT without a bubble state.
    type proc_state_t is (HALTED, FETCH_ADDR, FETCH_DATA, DECODE, EXEC_WAIT, MEM_WAIT, ADVANCE_PC);
    signal state, next_state : proc_state_t;

    -- ========================================================================
    -- CSR & CONTROL SIGNALS
    -- ========================================================================
    signal csr_run         : std_logic := '0';
    signal csr_start_pc    : std_logic_vector(15 downto 0) := (others => '0');
    signal csr_warp_offset : std_logic_vector(31 downto 0) := (others => '0');
    -- do_force_pc: set by CSR_ADDR_START_PC write, cleared after ADVANCE_PC
    -- consumes it.  Acts as a one-shot flag so a host PC-set does not repeat.
    signal do_force_pc     : std_logic := '0';
    signal irq_pending     : std_logic := '0'; -- Set by OP_INT, cleared by host W1C on CSR_ADDR_IRQ_ACK
    signal break_hit       : std_logic := '0'; -- Set by OP_BREAK, cleared by host W1C on CSR_ADDR_BREAK

    -- ========================================================================
    -- INTERCONNECT SIGNALS
    -- ========================================================================

    -- Instruction memory / IFU
    signal ifu_imem_addr   : std_logic_vector(PC_WIDTH-1 downto 0);  -- PC output from IFU → IMEM address
    signal imem_rd_data    : word_t;                                   -- IMEM read data back to IFU

    signal ifu_stall       : std_logic; -- '1' holds the IFU PC; released for exactly 1 cycle in ADVANCE_PC
    signal ifu_inst_out    : word_t;    -- Stable instruction word from FETCH_DATA onward
    signal ifu_exec_mask   : std_logic_vector(WARP_SIZE-1 downto 0); -- Active-thread mask (from divergence stack)
    signal ifu_fetch_valid : std_logic; -- Unused structural wire; reserved for future pipeline validity

    -- Decoder outputs: one record per instruction class.
    -- WHY separate records instead of one big flat bus: the decoder produces
    -- overlapping field encodings for different instruction types (e.g. ALU
    -- and FPU share the rs1/rs2 bit positions but interpret them differently).
    -- Separate records enforce type safety and avoid accidental field reuse.
    signal dec_fpu  : fpu_ctrl_t;
    signal dec_red  : red_ctrl_t;
    signal dec_alu  : alu_ctrl_t;
    signal dec_pc   : pc_ctrl_t;
    signal dec_mem  : mem_ctrl_t;

    -- active_pc_ctrl: combinational mux output fed to the IFU.
    -- When do_force_pc='1' a synthetic JMP to csr_start_pc overrides dec_pc,
    -- allowing the host to reposition the PC between warps without needing a
    -- full CTRL instruction in the instruction stream.
    signal active_pc_ctrl : pc_ctrl_t;

    -- exec_mux_ctrl: the decoder-output mux result fed to the issuer.
    -- Defaults to dec_fpu; overridden with dec_alu for ALU/IMM, dec_red for RED.
    -- SYS instructions fall through to dec_fpu (only the opcode matters for FLUSH;
    -- all WE fields are '0' so no accidental writeback occurs).
    signal exec_mux_ctrl  : exec_ctrl_t;

    -- Issuer outputs: exec record re-assembled from individual signals because
    -- the instruction_issue entity exposes flat ports, not a record port, to
    -- keep its interface synthesiser-friendly across tool versions.
    signal iss_exec_record : exec_ctrl_t;
    signal iss_valid_in    : std_logic; -- '1' for 1 cycle in DECODE to start the 32-thread issue sequence
    signal iss_issue_valid : std_logic; -- '1' while issuer is stepping through threads 0–31
    signal iss_opcode      : std_logic_vector(5 downto 0);
    signal iss_thread_id   : std_logic_vector(4 downto 0); -- Current thread index (0–31), advances each cycle
    -- Global VRF addresses: {thread_id[4:0], reg_idx[3:0]} = VRF_ADDR_WIDTH-bit flat address into VRF
    signal iss_rs1_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs2_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs3_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rd_global   : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);

    signal iss_swiz_a      : swizzle_sel_t;
    signal iss_swiz_b      : swizzle_sel_t;
    signal iss_swiz_c      : swizzle_sel_t;
    signal iss_mask        : std_logic_vector(3 downto 0);
    signal iss_cmp_inv     : std_logic;
    signal iss_cmp_swap    : std_logic;
    signal iss_is_log      : std_logic;
    signal iss_is_ld       : std_logic;
    signal iss_imm         : std_logic_vector(15 downto 0);
    signal iss_wb_mux      : std_logic_vector(1 downto 0);
    signal iss_vrf_we      : std_logic;
    signal iss_prf_we      : std_logic;

    -- VRF/PRF read data: presented to the execution unit one cycle after the
    -- issuer drives the global address, matching the VRF's 1-cycle read latency.
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    -- prf_mask_out: per-warp predicate collapse result, fed to IFU for branch
    -- evaluation.  Re-evaluated combinationally every cycle as dec_pc changes.
    signal prf_mask_out                             : std_logic_vector(WARP_SIZE-1 downto 0);

    -- Execution unit writeback: delayed FPU_MAX_LATENCY cycles from issue so
    -- all units (ALU, RED, FPU) commit at a uniform time without extra buffering.
    signal exec_wb_rd_addr : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0); -- Global VRF/PRF write address
    signal exec_wb_vrf_data: vector_t;
    signal exec_wb_prf_data: std_logic_vector(3 downto 0);
    signal exec_wb_vrf_we  : std_logic;
    signal exec_wb_prf_we  : std_logic;
    signal exec_wb_mask    : std_logic_vector(3 downto 0); -- Component write-enable for VRF

    -- Memory unit control / VRF Port B wiring.
    -- mem_vrf_rd/wr_addr use the same 9-bit {thread_id, reg_idx} format as
    -- the execution port so Port B is structurally identical to Port A.
    signal mem_op_valid    : std_logic; -- 1-cycle pulse from FSM DECODE state
    signal mem_stall       : std_logic; -- Asserted by MCU while scatter/gather is in progress
    signal mem_vrf_rd_addr : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal mem_vrf_rd_data : vector_t;
    signal mem_vrf_wr_addr : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal mem_vrf_wr_data : vector_t;
    signal mem_vrf_we      : std_logic;

    -- exec_flush_active: asserted by execution_unit while the FLUSH token is
    -- propagating through the pipeline (FPU_MAX_LATENCY cycles).  FSM uses
    -- this in EXEC_WAIT to ensure all in-flight results commit before advancing.
    signal exec_flush_active : std_logic;

    -- mem_phys_addr: full 32-bit Avalon byte address for memory operations.
    -- WHY shift dec_mem.base_addr left by 16: the instruction encodes a 16-bit
    -- base in bits[31:16] of the address space, producing 64 KB-aligned windows.
    -- Per-thread fine-grained offsets are added by the MCU using the offset register.
    signal mem_phys_addr : std_logic_vector(31 downto 0);

begin

    -- mem_phys_addr: place the 16-bit instruction immediate in the upper half
    -- of the 32-bit Avalon address, giving 64 KB-aligned base addresses.
    mem_phys_addr <= dec_mem.base_addr & x"0000";

    -- ========================================================================
    -- SIMULATION DEBUG MONITOR
    -- ========================================================================
    -- WHY synthesis translate_off guard: this process calls 'report', which is
    -- only meaningful in simulation.  Wrapping it prevents synthesis tools from
    -- trying to map string-formatting logic to gates.
    -- WHY fire on DECODE rather than EXEC_WAIT or writeback: DECODE is the
    -- exact cycle the FSM commits to dispatching an instruction.  Logging here
    -- gives the clearest 1:1 correspondence between the trace and the ISA-level
    -- program flow, without any latency ambiguity from pipeline stages.
    -- synthesis translate_off
    process(clk)
    begin
        if rising_edge(clk) then
            -- We log ONLY when the FSM explicitly commits an instruction
            -- from the Decode stage into the Execution Unit.
            if state = DECODE and csr_run = '1' then
                report "[EXEC COMMIT] PC: " & integer'image(to_integer(unsigned(ifu_imem_addr))) &
                       " | Instr: 0x" & to_hstring(ifu_inst_out);
            end if;
        end if;
    end process;
    -- synthesis translate_on

    -- ========================================================================
    -- 1. CSR INTERFACE & HARDWARE HANDSHAKES
    -- ========================================================================
    -- WHY two separate event sources (host writes [A] and GPU hardware [B])
    -- in one process: both modify the same set of control registers (csr_run,
    -- irq_pending, break_hit).  A single clocked process with priority between
    -- the two sources is simpler and avoids multiple-driver errors.
    -- Host writes take priority in the case statement; hardware events are
    -- checked unconditionally in the else branch — so a simultaneous host
    -- write and a GPU SYS instruction will merge correctly (the SYS event runs
    -- on the next cycle relative to the Avalon write strobe).
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                csr_run         <= '0';
                do_force_pc     <= '0';
                irq_pending     <= '0';
                break_hit       <= '0';
                csr_warp_offset <= (others => '0');
            else
                -- [A] HOST AVALON WRITES
                if csr_write = '1' then
                    case csr_address is
                        when CSR_ADDR_RUN =>
                            csr_run <= csr_writedata(0);

                        when CSR_ADDR_START_PC =>
                            csr_start_pc <= csr_writedata(15 downto 0);
                            -- WHY set do_force_pc here rather than acting immediately:
                            -- The FSM may currently be mid-instruction (EXEC_WAIT, etc.).
                            -- do_force_pc is a flag checked at HALTED and DECODE so the
                            -- forced jump is applied only when the FSM is at a safe
                            -- instruction boundary.
                            do_force_pc <= '1';

                        when CSR_ADDR_IRQ_ACK =>
                            -- WHY W1C (write-1-to-clear) semantics: allows the host to
                            -- atomically acknowledge the interrupt without needing a
                            -- read-modify-write sequence.
                            if csr_writedata(0) = '1' then irq_pending <= '0'; end if;

                        when CSR_ADDR_BREAK =>
                            -- Same W1C pattern as IRQ_ACK: host clears the breakpoint
                            -- flag by writing 1, enabling a clean resume.
                            if csr_writedata(0) = '1' then break_hit <= '0'; end if;

                        when CSR_ADDR_WARP_OFFSET =>
                            csr_warp_offset <= csr_writedata;

                        -- Read-only addresses are ignored on write
                        when others => null;
                    end case;
                end if;

                -- Clear force PC flag once consumed by FSM.
                -- WHY clear in ADVANCE_PC rather than immediately: ADVANCE_PC
                -- is the cycle when the IFU samples active_pc_ctrl.  Clearing
                -- here guarantees do_force_pc stays high across the entire
                -- HALTED→ADVANCE_PC→FETCH_ADDR path so active_pc_ctrl remains
                -- the synthetic JMP for that one ADVANCE_PC cycle.
                if state = ADVANCE_PC and do_force_pc = '1' then
                    do_force_pc <= '0';
                end if;

                -- [B] GPU HARDWARE EVENTS
                -- WHY fire on DECODE (not FETCH or EXEC_WAIT): the instruction is
                -- not architecturally committed until DECODE.  Firing here ensures
                -- exactly once-per-instruction semantics.
                if state = DECODE and ifu_inst_out(3 downto 0) = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- OP_RETURN halts cleanly: deassert csr_run so the FSM
                        -- goes to HALTED.  No PC advance — RETURN is not re-fetched.
                        csr_run <= '0';

                    elsif ifu_inst_out(31 downto 26) = OP_BREAK then
                        -- OP_BREAK: halt + set breakpoint flag for host inspection.
                        -- The FSM goes to ADVANCE_PC (not HALTED) so the PC steps
                        -- past the BREAK instruction before csr_run=0 takes effect.
                        -- This prevents the same BREAK from triggering again on resume.
                        csr_run <= '0';
                        break_hit <= '1';

                    elsif ifu_inst_out(31 downto 26) = OP_INT then
                        -- OP_INT: raise interrupt without halting.  The FSM goes to
                        -- ADVANCE_PC so execution continues; the host polls
                        -- CSR_ADDR_IRQ_ACK to detect and service the interrupt.
                        irq_pending <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    -- ========================================================================
    -- CSR AVALON READ MULTIPLEXER
    -- ========================================================================
    -- WHY combinational (not registered): Avalon-MM slaves are allowed to
    -- return readdata in the same cycle as csr_read (zero-wait-read).
    -- Registering would add one cycle of read latency and require the host
    -- to insert a wait state, complicating the Platform Designer component.
    -- Note: CSR_ADDR_EXEC_MASK returns all zeros — ifu_exec_mask is WARP_SIZE
    -- bits wide and would require a conditional width pad; the zero constant
    -- is a known placeholder until the read is properly wired.
    csr_readdata <=
        x"0000000" & "000" & csr_run      when csr_address = CSR_ADDR_RUN else
        x"0000"    & csr_start_pc         when csr_address = CSR_ADDR_START_PC else
        x"0000000" & "000" & irq_pending  when csr_address = CSR_ADDR_IRQ_ACK else
        x"0000000" & "000" & break_hit    when csr_address = CSR_ADDR_BREAK else
        x"0000"    & ifu_imem_addr        when csr_address = CSR_ADDR_CURR_PC else
        x"00000000"                       when csr_address = CSR_ADDR_EXEC_MASK else -- Placeholder: pad upper bits if WARP_SIZE < 32
        csr_warp_offset                   when csr_address = CSR_ADDR_WARP_OFFSET else
        (others => '0');

    -- Drive the interrupt line directly from the pending flag so the host's
    -- interrupt controller sees a level-sensitive signal.  The host clears it
    -- by W1C write to CSR_ADDR_IRQ_ACK, which deasserts irq_pending.
    host_irq_out <= irq_pending;

    -- ========================================================================
    -- 2. TOP-LEVEL STATE MACHINE (Two-Process Methodology)
    -- ========================================================================
    -- WHY two-process methodology (one synchronous, one combinational):
    --   Splitting state registration from output logic makes the sensitivity
    --   list of the combinational process exact, eliminates unintended latches,
    --   and makes it easy to verify that every signal driven combinationally
    --   has a safe default at the top of Process B.

    -- Process A: Synchronous State Register
    -- Only job: advance state on clock edge.  Reset drives HALTED.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= HALTED;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    -- Process B: Combinational Next-State & Output Routing
    -- WHY defaults at the top: avoids latches on ifu_stall, iss_valid_in, and
    -- mem_op_valid for states that do not explicitly drive them.  ifu_stall
    -- defaults to '1' (IFU held) so the PC never advances unless the FSM
    -- explicitly releases it in ADVANCE_PC.
    process(state, csr_run, do_force_pc, ifu_inst_out, iss_issue_valid, mem_stall, exec_flush_active)
        variable v_inst_type : std_logic_vector(3 downto 0);
    begin
        -- Default Combinational Outputs (Prevents Latches)
        next_state   <= state;
        ifu_stall    <= '1';  -- Hold PC by default; only released in ADVANCE_PC
        iss_valid_in <= '0';
        mem_op_valid <= '0';

        v_inst_type := ifu_inst_out(3 downto 0);

        case state is
            when HALTED =>
                -- WHY check do_force_pc here: if the host writes CSR_ADDR_START_PC
                -- while the processor is halted and then asserts csr_run, we need
                -- to apply the forced PC before fetching.  Going to ADVANCE_PC
                -- first ensures active_pc_ctrl (the synthetic JMP) is seen by
                -- the IFU exactly once before FETCH_ADDR begins.
                if csr_run = '1' then
                    if do_force_pc = '1' then next_state <= ADVANCE_PC; else next_state <= FETCH_ADDR; end if;
                end if;

            -- WHY two fetch states: M10K BRAM requires the read address to be
            -- stable for one cycle before data appears (registered-read mode).
            -- FETCH_ADDR presents the address; FETCH_DATA waits for stable data.
            when FETCH_ADDR => next_state <= FETCH_DATA;
            when FETCH_DATA => next_state <= DECODE;

            when DECODE =>
                if csr_run = '0' then
                    -- csr_run can deassert mid-stream (e.g. if host halts while
                    -- the FSM is in FETCH_*).  Return to HALTED cleanly.
                    next_state <= HALTED;

                elsif do_force_pc = '1' then
                    -- A CSR_ADDR_START_PC write arrived while the processor was
                    -- running.  Interrupt normal dispatch to apply the forced jump.
                    next_state <= ADVANCE_PC;

                elsif v_inst_type = INST_TYPE_MEM then
                    -- Pulse mem_op_valid for exactly 1 cycle.  The MCU asserts
                    -- mem_stall combinationally on this same cycle, so MEM_WAIT
                    -- immediately sees stall='1' on entry with no bubble needed.
                    mem_op_valid <= '1';
                    next_state <= MEM_WAIT;

                elsif v_inst_type = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- Halt immediately.  No PC advance: if the host re-asserts
                        -- csr_run it re-executes from this same RETURN instruction,
                        -- which is the correct loop-back-to-start behavior.
                        next_state <= HALTED;
                    elsif ifu_inst_out(31 downto 26) = OP_BREAK then
                        -- WHY ADVANCE_PC rather than HALTED: csr_run is already
                        -- cleared in the CSR process on this same cycle (GPU
                        -- hardware event [B]).  By going to ADVANCE_PC, the FSM
                        -- steps the PC past the BREAK instruction so that a
                        -- resume (host re-asserts csr_run) does not re-hit the
                        -- same breakpoint immediately.
                        next_state <= ADVANCE_PC;
                    elsif ifu_inst_out(31 downto 26) = OP_FLUSH then
                        -- FLUSH sends a sentinel token through the execution
                        -- pipeline.  We use iss_valid_in='1' to start the
                        -- issuer, which will push the FLUSH token through all
                        -- 32 thread slots.  EXEC_WAIT holds until the token
                        -- exits the pipeline (exec_flush_active='0') after
                        -- FPU_MAX_LATENCY cycles.
                        iss_valid_in <= '1';
                        next_state <= EXEC_WAIT;
                    else
                        -- OP_INT: interrupt flag set in CSR process; execution
                        -- is non-blocking (PC advances normally).
                        next_state <= ADVANCE_PC;
                    end if;

                elsif v_inst_type = INST_TYPE_CTRL then
                    -- Branch/SSY/SYNC: the IFU handles PC update combinationally
                    -- via active_pc_ctrl during ADVANCE_PC.  No issuer involvement.
                    next_state <= ADVANCE_PC;

                elsif v_inst_type = INST_TYPE_FPU or v_inst_type = INST_TYPE_ALU or
                      v_inst_type = INST_TYPE_IMM or v_inst_type = INST_TYPE_RED then
                    -- Start the 32-thread issue sequence.  iss_valid_in='1' for
                    -- exactly this one DECODE cycle; the issuer self-advances
                    -- through threads 0–31 once started.
                    iss_valid_in <= '1';
                    next_state <= EXEC_WAIT;

                else
                    -- Unknown/unimplemented instruction type: skip silently.
                    next_state <= ADVANCE_PC;
                end if;

            when EXEC_WAIT =>
                -- WHY two exit conditions:
                --   iss_issue_valid = '0': the barrel issuer has stepped through
                --     all 32 threads; the instruction has been fully dispatched.
                --   exec_flush_active = '0': only checked for FLUSH instructions.
                --     For arithmetic ops, the 32-cycle barrel gap guarantees the
                --     pipeline has drained by the time iss_issue_valid drops, so
                --     testing exec_flush_active would be redundant.  Skipping it
                --     for non-FLUSH makes the intent clear: we only wait for the
                --     pipeline drain signal when we actually sent a FLUSH token.
                if iss_issue_valid = '0' and
                   (ifu_inst_out(31 downto 26) /= OP_FLUSH or exec_flush_active = '0') then
                    next_state <= ADVANCE_PC;
                end if;

            when MEM_WAIT =>
                -- Spin until the MCU deasserts mem_stall.  All DDR3 back-pressure
                -- (waitrequest, burst beat counting) is absorbed inside memory_unit.
                if mem_stall = '0' then next_state <= ADVANCE_PC; end if;

            when ADVANCE_PC =>
                -- Deassert ifu_stall for exactly ONE cycle.  The IFU samples
                -- active_pc_ctrl on this cycle to compute and latch the next PC.
                -- On the following cycle ifu_stall returns to '1' (default) and
                -- the FSM enters FETCH_ADDR to wait for the new instruction.
                ifu_stall <= '0';
                next_state <= FETCH_ADDR;

        end case;
    end process;

    -- active_pc_ctrl mux: inject a synthetic unconditional JMP to csr_start_pc
    -- when do_force_pc='1'.  This allows the host to reposition the program
    -- counter to any 16-bit instruction address between warps without needing
    -- a JMP instruction in the program image.  PRED_MOD_ANY ensures the branch
    -- is always taken regardless of the current predicate state.
    -- When do_force_pc='0', pass dec_pc through unchanged so the IFU sees the
    -- normal decoded branch control for the current instruction.
    active_pc_ctrl <= (
        branch_type   => BR_JMP, target_addr => csr_start_pc,
        predicate_sel => "00", predicate_mod => PRED_MOD_ANY
    ) when do_force_pc = '1' else dec_pc;

    -- ========================================================================
    -- 3. DECODER RECORD MULTIPLEXER
    -- ========================================================================
    -- WHY this mux exists here rather than inside the issuer or decoder:
    --   The instruction_decoder produces three parallel, incompatible record
    --   types (fpu_ctrl_t, alu_ctrl_t, red_ctrl_t) because each instruction
    --   class packs its bits differently.  The issuer and execution unit consume
    --   a single unified exec_ctrl_t.  Merging here (at the top level) keeps
    --   the decoder and the issuer both simple and orthogonal.
    --
    -- WHY dec_fpu is the default (not an "unknown" value):
    --   SYS instructions (FLUSH) go through the issuer.  Their opcode field is
    --   in bits[31:26] which dec_fpu correctly exposes.  All WE fields in
    --   dec_fpu are '0' for SYS instructions (the decoder sets them), so using
    --   dec_fpu as the default causes no accidental writeback for FLUSH.
    --
    -- WHY ALU and IMM share the same branch: both use dec_alu fields.  The
    --   IMM class differs only in that dec_alu.is_load='1' and imm_data carries
    --   the payload; the execution unit distinguishes them by opcode.
    --
    -- WHY RED does not override rs3_addr_local: the reduction unit only reads
    --   rs1 and rs2; rs3 is unused (left as the dec_fpu default, which is '0').
    process(ifu_inst_out, dec_fpu, dec_alu, dec_red)
        variable v_type : std_logic_vector(3 downto 0);
    begin
        v_type := ifu_inst_out(3 downto 0);

        -- Default: populate from dec_fpu.  Covers INST_TYPE_FPU and all SYS
        -- instructions that fall through to the issuer (e.g. FLUSH).
        exec_mux_ctrl.opcode         <= dec_fpu.opcode;
        exec_mux_ctrl.rs1_addr_local <= dec_fpu.rs1_addr_local;
        exec_mux_ctrl.rs2_addr_local <= dec_fpu.rs2_addr_local;
        exec_mux_ctrl.rs3_addr_local <= dec_fpu.rs3_addr_local;
        exec_mux_ctrl.rd_addr_local  <= dec_fpu.rd_addr_local;
        exec_mux_ctrl.swiz_sel_a     <= dec_fpu.swiz_sel_a;
        exec_mux_ctrl.swiz_sel_b     <= dec_fpu.swiz_sel_b;
        exec_mux_ctrl.swiz_sel_c     <= dec_fpu.swiz_sel_c;
        exec_mux_ctrl.write_mask     <= dec_fpu.write_mask;
        exec_mux_ctrl.wb_mux_sel     <= dec_fpu.wb_mux_sel;
        exec_mux_ctrl.cmp_invert     <= dec_fpu.cmp_invert;
        exec_mux_ctrl.cmp_swap       <= dec_fpu.cmp_swap;
        exec_mux_ctrl.is_logic_op    <= dec_fpu.is_logic_op;
        exec_mux_ctrl.vrf_we         <= dec_fpu.vrf_we;
        exec_mux_ctrl.prf_we         <= dec_fpu.prf_we;
        -- is_load and imm_data are FPU-irrelevant; zero them to prevent
        -- stale values from propagating into the execution unit.
        exec_mux_ctrl.is_load        <= '0';
        exec_mux_ctrl.imm_data       <= (others => '0');

        if v_type = INST_TYPE_ALU or v_type = INST_TYPE_IMM then
            -- Override with ALU/IMM fields.  IMM instructions set is_load='1'
            -- and carry a 16-bit immediate in imm_data; the execution unit
            -- uses is_load to mux imm_data onto the rs2 operand path.
            exec_mux_ctrl.opcode         <= dec_alu.opcode;
            exec_mux_ctrl.rs1_addr_local <= dec_alu.rs1_addr_local;
            exec_mux_ctrl.rs2_addr_local <= dec_alu.rs2_addr_local;
            exec_mux_ctrl.rd_addr_local  <= dec_alu.rd_addr_local;
            exec_mux_ctrl.swiz_sel_a     <= dec_alu.swiz_sel_a;
            exec_mux_ctrl.swiz_sel_b     <= dec_alu.swiz_sel_b;
            exec_mux_ctrl.write_mask     <= dec_alu.write_mask;
            exec_mux_ctrl.wb_mux_sel     <= dec_alu.wb_mux_sel;
            exec_mux_ctrl.vrf_we         <= dec_alu.vrf_we;
            exec_mux_ctrl.prf_we         <= dec_alu.prf_we;
            exec_mux_ctrl.is_load        <= dec_alu.is_load;
            exec_mux_ctrl.imm_data       <= dec_alu.imm_data;

        elsif v_type = INST_TYPE_RED then
            -- Reduction only uses rs1, rs2, rd, swiz_a/b, wb_mux_sel, vrf_we.
            -- Fields not present in red_ctrl_t (rs3, write_mask, cmp_*, prf_we,
            -- is_logic_op, is_load, imm_data) remain at the dec_fpu defaults
            -- set above, which are all-zero / '0' for these fields.
            exec_mux_ctrl.rs1_addr_local <= dec_red.rs1_addr_local;
            exec_mux_ctrl.rs2_addr_local <= dec_red.rs2_addr_local;
            exec_mux_ctrl.rd_addr_local  <= dec_red.rd_addr_local;
            exec_mux_ctrl.swiz_sel_a     <= dec_red.swiz_sel_a;
            exec_mux_ctrl.swiz_sel_b     <= dec_red.swiz_sel_b;
            exec_mux_ctrl.wb_mux_sel     <= dec_red.wb_mux_sel;
            exec_mux_ctrl.vrf_we         <= dec_red.vrf_we;

        elsif v_type = INST_TYPE_SYS then
            -- SYS instructions (FLUSH, RETURN, BREAK, INT) use the dec_fpu
            -- defaults set above.  The opcode field is correctly exposed by
            -- dec_fpu (bits[31:26] are the same for all instruction types), and
            -- all WE fields remain '0' so no accidental writeback occurs.
            -- This explicit branch makes the fall-through intent visible.
            null;
        end if;
    end process;


    -- ========================================================================
    -- 4. COMPONENT INSTANTIATIONS
    -- ========================================================================

    -- u_imem: M10K-backed instruction store.
    -- WHY IMEM_ADDR_WIDTH < PC_WIDTH: the physical memory is smaller than the
    -- full 16-bit PC range.  The IFU drives a 16-bit address; only the lower
    -- IMEM_ADDR_WIDTH bits are wired to the BRAM.  Programs must fit within the
    -- M10K array; branches into the upper address space are a firmware error.
    -- WHY prog_we / prog_wr_addr: the processor does not have a self-modifying
    -- instruction; programs are loaded by the host via the prog_* ports before
    -- csr_run is asserted.
    u_imem : entity work.instruction_memory
        generic map ( ADDR_WIDTH => IMEM_ADDR_WIDTH )
        port map (
            clk      => clk,
            we       => prog_we,
            wr_addr  => prog_wr_addr,
            wr_data  => prog_wr_data,
            rd_addr  => ifu_imem_addr(IMEM_ADDR_WIDTH-1 downto 0),
            rd_data  => imem_rd_data
        );

    -- u_ifu: instruction fetch unit.
    -- WHY imem_valid is tied '1': the IFU is always stalled by ifu_stall when
    -- the instruction memory is not ready.  A separate imem_valid signal would
    -- be redundant because the FSM already gates the IFU via ifu_stall.
    -- WHY predicate_mask comes from u_prf: the PRF collapses the per-thread
    -- predicate bits for the branch instruction currently in DECODE into a
    -- single bit that the IFU uses to decide whether to take the branch.  This
    -- is evaluated combinationally so the IFU sees the correct value during
    -- the ADVANCE_PC cycle when it samples pc_ctrl.
    u_ifu : entity work.instruction_fetch_unit
        generic map ( PC_WIDTH => PC_WIDTH, WARP_SIZE => WARP_SIZE )
        port map (
            clk             => clk, reset => reset,
            imem_addr       => ifu_imem_addr,
            imem_data       => imem_rd_data,
            imem_valid      => '1',
            stall           => ifu_stall,
            pc_ctrl         => active_pc_ctrl,
            predicate_mask  => prf_mask_out,
            instruction_out => ifu_inst_out,
            exec_mask_out   => ifu_exec_mask,
            fetch_valid     => ifu_fetch_valid
        );

    -- u_decode: purely combinational.  No clock input.  All five output records
    -- are valid within the same cycle the instruction word is presented.
    -- WHY all records are always driven (even when the instruction type only
    -- uses one): unused records are ignored by the mux above; having the
    -- decoder produce all fields always avoids incomplete assignments and
    -- ensures synthesis sees constant driving equations for every field.
    u_decode : entity work.instruction_decoder
        port map (
            instruction => ifu_inst_out, fpu_ctrl => dec_fpu, red_ctrl => dec_red,
            alu_ctrl => dec_alu, pc_ctrl => dec_pc, mem_ctrl => dec_mem
        );

    -- u_issue: sequences through threads 0–31, one per cycle, once iss_valid_in
    -- is pulsed.  It computes global VRF/PRF addresses ({thread_id, reg_idx})
    -- and drives them to the VRF read ports.  The execution unit samples the
    -- read data one cycle later, matching the VRF's 1-cycle read latency.
    -- WHY THREAD_WIDTH=5 / REG_WIDTH=4: WARP_SIZE=32 requires 5 bits for
    -- thread IDs (0–31); 16 registers per thread requires 4 bits.  Together
    -- they produce the 9-bit global VRF address.
    u_issue : entity work.instruction_issue
        generic map ( THREAD_WIDTH => THREAD_ID_WIDTH, REG_WIDTH => LOCAL_REG_WIDTH )
        port map (
            clk             => clk, reset => reset, exec_ctrl_in => exec_mux_ctrl,
            valid_in        => iss_valid_in, current_thread => iss_thread_id,
            opcode_out      => iss_opcode, rs1_addr_global => iss_rs1_global,
            rs2_addr_global => iss_rs2_global, rs3_addr_global => iss_rs3_global,
            rd_addr_global  => iss_rd_global, swiz_sel_a => iss_swiz_a,
            swiz_sel_b      => iss_swiz_b, swiz_sel_c => iss_swiz_c,
            inst_write_mask => iss_mask, cmp_invert => iss_cmp_inv,
            cmp_swap        => iss_cmp_swap, is_logic_op => iss_is_log,
            is_load         => iss_is_ld, imm_data => iss_imm,
            wb_mux_sel      => iss_wb_mux, vrf_we => iss_vrf_we,
            prf_we          => iss_prf_we, issue_valid => iss_issue_valid
        );

    -- Re-pack issuer flat outputs into iss_exec_record for the execution unit.
    -- WHY flat ports on u_issue rather than a record port: the issuer was
    -- written to be tool-agnostic (some older Quartus versions have issues
    -- with record aggregates on entity ports).  We re-assemble the record here.
    -- WHY rs*_addr_local are zeroed: the execution unit reads operands from
    -- VRF read data (vrf_rs1_data etc.), not from address fields in the record.
    -- The issuer has already driven the global address to the VRF; the local
    -- fields are only used in the pre-issue mux (exec_mux_ctrl) and are not
    -- needed in the pipelined exec stage.
    iss_exec_record.opcode      <= iss_opcode;
    iss_exec_record.swiz_sel_a  <= iss_swiz_a;
    iss_exec_record.swiz_sel_b  <= iss_swiz_b;
    iss_exec_record.swiz_sel_c  <= iss_swiz_c;
    iss_exec_record.write_mask  <= iss_mask;
    iss_exec_record.cmp_invert  <= iss_cmp_inv;
    iss_exec_record.cmp_swap    <= iss_cmp_swap;
    iss_exec_record.is_logic_op <= iss_is_log;
    iss_exec_record.is_load     <= iss_is_ld;
    iss_exec_record.imm_data    <= iss_imm;
    iss_exec_record.wb_mux_sel  <= iss_wb_mux;
    iss_exec_record.vrf_we      <= iss_vrf_we;
    iss_exec_record.prf_we      <= iss_prf_we;
    -- Local address fields are unused past the issuer: the issuer has already
    -- concatenated them with the thread ID and driven the global addresses to the VRF.
    -- The execution unit reads operands from vrf_rs*_data, not from these fields.
    iss_exec_record.rs1_addr_local <= "0000"; iss_exec_record.rs2_addr_local <= "0000";
    iss_exec_record.rs3_addr_local <= "0000"; iss_exec_record.rd_addr_local  <= "0000";

    -- u_exec: FPU / ALU / RED pipeline, FPU_MAX_LATENCY=28 deep.
    -- WHY inst_type_in comes directly from ifu_inst_out rather than from
    -- iss_exec_record: the execution unit needs to know which functional unit
    -- to route the result to (FPU vs. ALU vs. RED) but exec_ctrl_t does not
    -- carry a type tag — it only carries wb_mux_sel.  The raw INST_TYPE bits
    -- from the instruction word serve as a fast dispatch key without adding a
    -- redundant field to exec_ctrl_t.
    -- WHY red_mode_in / red_mask_in come from dec_red directly rather than
    -- through the issuer: these fields control the reduction unit's internal
    -- accumulation mode, which is uniform across all 32 threads (not per-thread).
    -- Bypassing the issuer keeps these warp-level fields stable for all 32 issue
    -- cycles rather than requiring the issuer to re-present them each cycle.
    -- WHY warp_offset_in: the THREAD_ID instruction computes
    -- rd = csr_warp_offset + thread_id.  The offset is a CSR so the execution
    -- unit needs access to it to implement the instruction without a dedicated
    -- pre-adder in the issuer.
    u_exec : entity work.execution_unit
        port map (
            clk               => clk, reset => reset, exec_ctrl_in => iss_exec_record,
            valid_in          => iss_issue_valid, inst_type_in => ifu_inst_out(3 downto 0),
            red_mode_in       => dec_red.red_mode, red_mask_in => dec_red.red_mask,
            rd_addr_global_in => iss_rd_global, vrf_rs1_data => vrf_rs1_data,
            vrf_rs2_data      => vrf_rs2_data, vrf_rs3_data => vrf_rs3_data,
            prf_rs1_data      => prf_rs1_data, prf_rs2_data => prf_rs2_data,
            warp_offset_in    => csr_warp_offset, thread_id_in => iss_thread_id,
            wb_rd_addr_out    => exec_wb_rd_addr, wb_vrf_data_out => exec_wb_vrf_data,
            wb_prf_data_out   => exec_wb_prf_data, wb_vrf_we_out => exec_wb_vrf_we,
            wb_prf_we_out     => exec_wb_prf_we, wb_mask_out => exec_wb_mask,
            flush_active_out  => exec_flush_active
        );

    -- u_mem: scatter/gather memory subsystem (see memory_unit.vhd for details).
    -- WHY REG_WIDTH=>4: 16 registers per thread, requiring a 4-bit local index
    --   (same as the VRF address scheme used everywhere else in the design).
    -- base_addr is driven by mem_phys_addr (see signal declaration above).
    u_mem : entity work.memory_unit
        generic map ( WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH, REG_WIDTH => 4 )
        port map (
            clk               => clk, reset => reset, mem_op_valid => mem_op_valid,
            is_store          => dec_mem.is_store, base_addr => mem_phys_addr,
            offset_reg_idx    => dec_mem.offset_reg_idx, dest_src_reg_idx => dec_mem.dest_src_reg_idx,
            exec_mask         => ifu_exec_mask, mem_stall => mem_stall,
            reg_read_addr     => mem_vrf_rd_addr, reg_read_data => mem_vrf_rd_data,
            reg_write_addr    => mem_vrf_wr_addr, reg_write_data => mem_vrf_wr_data,
            reg_write_en      => mem_vrf_we, avm_address => avm_address,
            avm_burstcount    => avm_burstcount, avm_write => avm_write,
            avm_writedata     => avm_writedata, avm_byteenable => avm_byteenable,
            avm_read          => avm_read, avm_readdata => avm_readdata,
            avm_readdatavalid => avm_readdatavalid, avm_waitrequest => avm_waitrequest
        );

    -- u_vrf: 512-entry vector register file (32 threads × 16 registers).
    -- WHY ADDR_WIDTH=VRF_ADDR_WIDTH (=9): THREAD_ID_WIDTH+LOCAL_REG_WIDTH = 5+4 = 9.
    --   The 9-bit address is formed as {thread_id[4:0], reg_idx[3:0]} by the issuer and MCU.
    -- WHY Port A has 3 read ports (rs1/rs2/rs3): FMA and other ternary FPU
    --   ops need three independent source operands per thread.  Port B (memory)
    --   only needs one read port (the source/destination register) per thread.
    -- WHY write_mask_B is hardwired to "1111": memory loads always write all
    --   four vector components; there is no per-component masking for loads.
    --   Component masking is only used for arithmetic writebacks (Port A).
    u_vrf : entity work.vector_reg_file
        generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH )
        port map (
            clk => clk, reset => reset, rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs3_addr => iss_rs3_global, rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data,
            rs3_data => vrf_rs3_data, rd_addr_A => exec_wb_rd_addr, rd_data_A => exec_wb_vrf_data,
            write_mask_A => exec_wb_mask, we_A => exec_wb_vrf_we, rd_addr_B => mem_vrf_rd_addr,
            rd_data_B => mem_vrf_rd_data, wr_addr_B => mem_vrf_wr_addr, wr_data_B => mem_vrf_wr_data,
            write_mask_B => "1111", we_B => mem_vrf_we
        );

    -- u_prf: 512-entry predicate register file.
    -- WHY same VRF_ADDR_WIDTH as VRF: predicates use the same {thread_id,
    --   reg_idx} addressing convention so the issuer can share address
    --   generation logic between VRF and PRF accesses.
    -- WHY ifu_pred_sel / ifu_pred_mod come from dec_pc rather than from a
    --   registered/issued value: the PRF collapse (predicate → branch mask) is
    --   needed by the IFU during ADVANCE_PC to evaluate the branch.  Using
    --   dec_pc directly means the collapse re-evaluates combinationally every
    --   cycle as the instruction changes, always reflecting the current DECODE
    --   instruction's predicate selector.  No extra pipeline register is needed.
    -- WHY ifu_mask_out goes to u_ifu predicate_mask: the collapsed predicate
    --   tells the IFU which threads evaluate the branch as "taken", forming the
    --   basis for the SIMT divergence decision (push / pop / converge).
    u_prf : entity work.predicate_reg_file
        generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH )
        port map (
            clk => clk, reset => reset, rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs1_data => prf_rs1_data, rs2_data => prf_rs2_data, wr_addr => exec_wb_rd_addr,
            wr_data => exec_wb_prf_data, we => exec_wb_prf_we, wr_mask => exec_wb_mask,
            ifu_pred_sel => dec_pc.predicate_sel, ifu_pred_mod => dec_pc.predicate_mod,
            ifu_mask_out => prf_mask_out
        );

end architecture structural;
