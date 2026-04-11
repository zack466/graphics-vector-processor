# Design Simplification Proposals

Each proposal identifies a specific issue in the current design, explains the problem, describes the change, and quantifies the benefit. No changes have been made — these are proposals only.

---

## Category 1: Magic Numbers

### P1 — `FPU_MAX_LATENCY` is not derived from the latency constants

**File:** `processor_constants_pkg.vhd`

**Problem:** `FPU_MAX_LATENCY = 28` is hardcoded. It happens to equal `LAT_FRSQRT`, but there is no compile-time relationship between them. If a future IP core has a longer latency (say 30 cycles), a developer must remember to update both `LAT_NEW_OP` and `FPU_MAX_LATENCY` — and there is nothing to catch the mistake if they don't.

**Proposed change:**
```vhdl
-- Derive FPU_MAX_LATENCY as the maximum of all IP latencies
constant FPU_MAX_LATENCY : integer := maximum(LAT_FRSQRT,
    maximum(LAT_FMADD, maximum(LAT_FRCP, maximum(LAT_FLOG2,
    maximum(LAT_FSIN,  maximum(LAT_FCOS,  maximum(LAT_FEXP2,
    maximum(LAT_REDUCT, maximum(LAT_I2F, LAT_F2I)))))))));
```
VHDL-2008 provides `maximum()` as a built-in on integers. Alternatively, just add an `assert LAT_FRSQRT = FPU_MAX_LATENCY severity failure;` guard as a minimum safeguard.

**Benefit:** Eliminates a silent, non-obvious maintenance coupling. Adding a new slow IP core automatically extends the pipeline.

---

### P2 — VRF `ADDR_WIDTH => 9` is a magic number in `processor.vhd`

**File:** `processor.vhd` (lines instantiating `u_vrf` and `u_prf`)

**Problem:** Both the VRF and PRF are instantiated with `ADDR_WIDTH => 9`, which is `THREAD_WIDTH + REG_WIDTH` (5 + 4). This relationship is not expressed in code. If the number of threads or registers ever changes, these magic `9`s must be found and updated manually.

**Proposed change:**
```vhdl
-- At the top of the architecture:
constant VRF_ADDR_WIDTH : integer := 5 + 4; -- thread_id(5b) & reg_idx(4b)

-- In instantiation:
u_vrf : entity work.vector_reg_file
    generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH ) ...
u_prf : entity work.predicate_reg_file
    generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH ) ...
```

Or alternatively, expose `THREAD_WIDTH` and `REG_WIDTH` as top-level generics of `processor` and compute it there.

**Benefit:** Removes two magic `9`s; makes the address space derivation self-documenting.

---

### P3 — `base_addr & x"0000"` is a magic left-shift in `processor.vhd`

**File:** `processor.vhd`, memory unit instantiation

**Problem:** The 16-bit `dec_mem.base_addr` is shifted into the upper half of the 32-bit Avalon address bus via `dec_mem.base_addr & x"0000"`. This means instruction immediate bits [25:12] map to address bits [29:16], giving a 1 GB aligned window. The shift is correct but unexplained to a reader.

**Proposed change:**
```vhdl
-- Named constant documents the intent:
constant MEM_BASE_SHIFT : integer := 16;
...
base_addr => std_logic_vector(
    unsigned(dec_mem.base_addr) sll MEM_BASE_SHIFT),
```
Or simpler — a local signal:
```vhdl
signal mem_phys_addr : std_logic_vector(31 downto 0);
...
mem_phys_addr <= dec_mem.base_addr & x"0000"; -- imm[25:12] → addr[29:16]
```

**Benefit:** Makes the addressing window obvious and searchable; eliminates the literal `x"0000"` magic string.

---

### P4 — `instruction_issue` uses `count = 32` as a magic idle sentinel

**File:** `instruction_issue.vhd`

**Problem:** The issuer starts with `count <= to_unsigned(32, 6)` on reset and uses the condition `count < 32` to decide whether to continue issuing. The value 32 is both the thread count and the "nothing to issue" sentinel. This is a dual-use of a numeric value: a reader who doesn't know the convention might think this is an off-by-one error. The FLUSH special case (`count <= to_unsigned(32, 6)`) looks identical to the reset case.

**Proposed change:** Add an explicit `active` flag:
```vhdl
signal active : std_logic := '0';
...
-- On new instruction: active <= '1'; count <= to_unsigned(1, 6);
-- On FLUSH:          active <= '0'; count <= (others => '0'); -- only 1 thread needed
-- Count at 31 → 32: active <= '0';
issue_valid <= valid_in or active;
```
The WARP_SIZE generic could replace the literal 32 throughout.

**Benefit:** Eliminates the magic-32 overload. The FLUSH "skip" and the "idle" state are now expressed by different mechanisms.

---

### P5 — `THREAD_WIDTH` and `REG_WIDTH` are magic at the instantiation site

**File:** `processor.vhd`, `u_issue` instantiation

**Problem:** `instruction_issue` is instantiated with `THREAD_WIDTH => 5, REG_WIDTH => 4`. These numbers are correct but unlinked to any named constant. The fact that 5 threads bits → 32 threads and 4 register bits → 16 registers is not obvious from the generics at the call site.

**Proposed change:** Add constants to `processor_constants_pkg`:
```vhdl
constant THREAD_ID_WIDTH : integer := 5; -- log2(32 threads)
constant LOCAL_REG_WIDTH : integer := 4; -- log2(16 registers)
```
Use these in `processor.vhd` and tie them into P2 above.

**Benefit:** Single source of truth for thread/register counts.

---

## Category 2: FSM Simplification

### P6 — `FETCH_1` is an empty pass-through state

**File:** `processor.vhd`

**Problem:** The FSM path `FETCH_1 → FETCH_2 → DECODE` adds two cycles after every `ADVANCE_PC`. `FETCH_1` does nothing — it is literally just `next_state <= FETCH_2`. The two cycles exist to absorb the M10K read latency of `instruction_memory` (registered read address + data output). The state name `FETCH_1` implies something happens there, but nothing does.

**Proposed change:** Merge `FETCH_1` into `ADVANCE_PC`:
```vhdl
-- ADVANCE_PC already unstalls the IFU for 1 cycle. On the following
-- cycle (currently FETCH_1) the BRAM address is registered. On the
-- cycle after that (FETCH_2) data is stable. Rename:
--   ADVANCE_PC → FETCH_ADDR   (IFU unstalled, address registered)
--   FETCH_2    → FETCH_DATA   (data stable, decode next cycle)
--   DECODE     → DECODE       (unchanged)
-- Net: removes 1 state, no cycle-count change.
```

**Benefit:** Removes one FSM state. The rename (`FETCH_ADDR`, `FETCH_DATA`) makes the 2-cycle BRAM pipeline explicit in the state names rather than hiding it in a blank state.

---

### P7 — `MEM_WAIT_START` exists solely to paper over an MCU interface timing gap

**File:** `processor.vhd`, `mcu_scatter_gather.vhd`

**Problem:** `MEM_WAIT_START` is a 1-cycle bubble because the MCU takes 1 clock cycle after `mem_op_valid` is pulsed before it asserts `mem_stall`. Without this state, the FSM sees `mem_stall = '0'` on the next cycle and immediately exits `MEM_WAIT` thinking the operation is complete. The extra state is a band-aid on the MCU's interface, not a structural requirement.

**Proposed change:** Make `mem_stall` go high combinationally in the MCU's IDLE state when `mem_op_valid = '1'`:
```vhdl
-- In mcu_scatter_gather.vhd:
mem_stall <= '1' when (state = IDLE and mem_op_valid = '1') or
                      (state /= IDLE and state /= FINISH) else '0';
```
This makes `mem_stall` a combinational output rather than a registered one, eliminating the need for the extra FSM state in `processor.vhd`.

**Benefit:** Removes one FSM state and one cycle of unnecessary latency per memory instruction.

---

### P8 — `EXEC_WAIT` checks `exec_flush_active` unnecessarily for non-FLUSH instructions

**File:** `processor.vhd`

**Problem:** The EXEC_WAIT exit condition is:
```vhdl
if iss_issue_valid = '0' and exec_flush_active = '0' then ...
```
For non-FLUSH arithmetic instructions, `exec_flush_active` is always `'0'` by the time `iss_issue_valid` drops — there is no FLUSH token in the pipe. The second condition is vacuously true and adds no protection; it just obscures which condition is actually load-bearing for which instruction type.

**Proposed change:** Track whether the current EXEC_WAIT was entered for a FLUSH:
```vhdl
signal waiting_for_flush : std_logic;
...
-- On entry to EXEC_WAIT:
waiting_for_flush <= '1' when v_inst_type = INST_TYPE_SYS and
                     ifu_inst_out(31 downto 26) = OP_FLUSH else '0';
...
when EXEC_WAIT =>
    if iss_issue_valid = '0' then
        if waiting_for_flush = '0' or exec_flush_active = '0' then
            next_state <= ADVANCE_PC;
        end if;
    end if;
```

**Benefit:** The condition is now explicit about what each flag guards. Easier to reason about and extend.

---

## Category 3: Code Duplication / Reuse

### P9 — VRF's inline arbitration FIFO duplicates `sync_fifo`

**File:** `vector_reg_file.vhd`

**Problem:** The VRF implements its own 64-entry FIFO for MCU write arbitration using raw signal arrays (`fifo_addr`, `fifo_data`, `fifo_mask`), a 6-bit head/tail pointer pair, and a 7-bit count. This is functionally identical to the `sync_fifo` entity already in the design. The inline implementation is ~60 lines, is harder to verify in isolation, and cannot benefit from future improvements to `sync_fifo`.

**Challenge:** The FIFO needs to store three independent fields (addr, data, mask) and `sync_fifo` has a single wide bus. One option is to widen it and pack the fields:
```vhdl
-- Pack: [ADDR_WIDTH-1:0] addr | [127:0] data | [3:0] mask
-- Total width: ADDR_WIDTH + 128 + 4 bits
u_arb_fifo : entity work.sync_fifo
    generic map (DATA_WIDTH => ADDR_WIDTH + 132, ADDR_WIDTH => 6)
    port map (...);
```
Alternatively, use three separate `sync_fifo` instances that share a single write enable and read enable, keeping each field in its own FIFO.

**Benefit:** Removes ~60 lines of ad-hoc FIFO logic. Correctness of arbitration is now testable through the existing `sync_fifo` test bench.

---

### P10 — MCU has two independent implementations of the 2-cycle VRF read pipeline

**File:** `mcu_scatter_gather.vhd`

**Problem:** The MCU uses the 2-cycle M10K read latency pipeline in two places:
1. `GATHER_ADDR`: `req_idx` (address issue) + `ack_idx` (data capture, offset by 2 cycles) to read all 32 thread offsets from the VRF.
2. `FETCH_WDATA`: `words_issued` (address issue) + `words_pushed` + `read_active_q1/q2` (2-stage valid pipeline) to read store data.

Both implement the same 2-cycle VRF read pipeline but with different variable names and slightly different mechanisms (`req_idx ≥ 2` offset vs `read_active_q1/q2` shift register). This divergence makes both harder to verify.

**Proposed change:** Extract a shared 2-cycle pipeline pattern as a comment template or local procedure, and unify the `GATHER_ADDR` path to also use `read_active_q1/q2` explicitly. At minimum, rename variables to match across the two uses.

**Benefit:** Easier to audit timing correctness; change to VRF read latency (e.g., switching from M10K to MLAB) only needs to be made in one place.

---

### P11 — `iss_exec_record.rs*_addr_local` are always hardwired to `"0000"` in `processor.vhd`

**File:** `processor.vhd`

**Problem:** After the issuer produces global addresses, `processor.vhd` reconstructs an `exec_ctrl_t` record to pass to `execution_unit`, but then hardwires all four local-address fields to `"0000"`:
```vhdl
iss_exec_record.rs1_addr_local <= "0000";
iss_exec_record.rs2_addr_local <= "0000";
iss_exec_record.rs3_addr_local <= "0000";
iss_exec_record.rd_addr_local  <= "0000";
```
These fields exist in `exec_ctrl_t` because the record type is shared between the issuer input and the execution unit input. By the time the record reaches the execution unit the local fields are dead weight — the execution unit never reads them.

**Proposed change:** Define a second, slimmer record type `exec_pipe_t` for the issuer→execution unit path that drops the local address fields. Or, promote `rd_addr_global` from a separate port to a field in `exec_ctrl_t` and remove the local fields entirely.

**Benefit:** Eliminates four hardwired-zero assignments, removes dead fields from the record, and reduces the risk of accidentally reading stale local addresses downstream.

---

## Category 4: Type Safety

### P12 — `wb_mux_sel` uses raw `std_logic_vector` instead of an enumerated type

**File:** `processor_constants_pkg.vhd`, `writeback_controller.vhd`, `execution_unit.vhd`

**Problem:** `WB_MUX_FPU = "00"`, `WB_MUX_RED = "01"`, `WB_MUX_ALU = "10"` are 2-bit `std_logic_vector` constants. At the `wb_vrf_data_out` mux in `execution_unit.vhd`, the comparison is against these raw bit patterns. An enumerated type would catch accidental assignment of `"11"` (undefined) at elaboration time rather than silently driving a wrong value.

**Proposed change:**
```vhdl
type wb_mux_t is (WB_MUX_FPU, WB_MUX_RED, WB_MUX_ALU);
-- Use in exec_ctrl_t, writeback_controller, and execution_unit
-- Replace raw bit-pattern comparisons with case on wb_mux_t
```

**Benefit:** Compile-time type checking; the `others` arm of the case statement becomes a natural catch for undefined states.

---

### P13 — `INST_TYPE_*`, `BR_*`, and `PRED_MOD_*` could be enumerated types

**File:** `processor_constants_pkg.vhd`, `instruction_decoder.vhd`, `instruction_fetch_unit.vhd`

**Problem:** `INST_TYPE_FPU = "0000"`, `BR_SYNC = "110"`, `PRED_MOD_ANY = "00"` etc. are raw `std_logic_vector` constants compared with `=` throughout the design. A mistyped bit pattern or an accidental extra bit in a concatenation silently evaluates to `'0'` (false) with no warning.

**Proposed change:** Define `inst_type_t`, `branch_type_t`, and `pred_mod_t` as enumerated types. The decoder and IFU can use `case` on these types rather than `if inst_type = INST_TYPE_FPU`. VHDL synthesis tools handle enumerations well.

**Benefit:** Catches range errors at elaboration. Eliminates raw bit patterns in control flow. Makes `case` coverage checking reliable.

---

## Category 5: Interface / Protocol Fragility

### P14 — `SSY` and `BRA_DIV` are coupled through a bare register, not the SIMT stack

**File:** `instruction_fetch_unit.vhd`

**Problem:** `SSY` writes `saved_reconv_pc` and `BRA_DIV` reads it. This works only if nothing appears between `SSY` and `BRA_DIV` — a `FLUSH` or any other IFU-visible instruction in between would leave `saved_reconv_pc` stale. The convention is enforced by the assembler and programmer, but not by the hardware. If a future optimization or compiler inserts an instruction between `SSY` and `BRA_DIV`, the result is silent control-flow corruption.

**Proposed change — Option A:** Encode the reconvergence target directly in the `BRA_DIV` instruction word (use a second 16-bit field or a dedicated instruction format). `SSY` then becomes optional or is removed.

**Proposed change — Option B:** On SSY, push `saved_reconv_pc` directly onto the SIMT stack (with a dummy deferred mask of all-ones), and have BRA_DIV simply update the deferred mask of the top stack entry. No bare register needed.

**Benefit:** Eliminates a temporal coupling between two instructions enforced only by convention. Makes divergence robust to instruction reordering.

---

### P15 — SYS instructions tunnel through `dec_fpu.opcode` via a silent convention

**File:** `instruction_decoder.vhd`, `processor.vhd`

**Problem:** The decoder places SYS opcodes into `v_fpu.opcode` (with all WEs cleared) because `exec_mux_ctrl` uses `dec_fpu` as its default, which means the opcode reaches the execution unit for the FLUSH path. This is a hidden contract: anyone reading the decoder in isolation cannot tell why SYS goes into the FPU record, and anyone reading `processor.vhd` cannot tell how a SYS opcode reaches the execution unit for `iss_valid_in <= '1'`.

**Proposed change:** Add an explicit SYS opcode field to the `exec_mux_ctrl` assembly, or handle SYS in the FSM directly without routing through the decoder record (the FSM already reads `ifu_inst_out(31 downto 26)` to detect FLUSH/RETURN/BREAK anyway).

**Benefit:** Breaks the implicit dec_fpu dependency; SYS instruction handling is self-contained and auditable.

---

### P16 — `fpu_lane`'s output process duplicates the injection logic from the sequential process

**File:** `fpu_lane.vhd`

**Problem:** The sequential `process(clk)` injects each IP result at pipeline stage `i = LAT_X`. The combinational output process then re-checks `if LAT_X = FPU_MAX_LATENCY` to bypass `shared_res_pipe(FPU_MAX_LATENCY)` with the raw IP output. This duplication exists to handle the edge case where an IP latency equals `FPU_MAX_LATENCY` exactly (currently `LAT_FRSQRT = 28`). If `FPU_MAX_LATENCY` ever changes such that no IP equals it, the output process becomes dead code. If two IPs share the same latency equal to `FPU_MAX_LATENCY`, only the last `if` check wins.

**Proposed change:** Extend the shared pipeline by one extra stage so it always captures the injected result one cycle later, and always read from stage `FPU_MAX_LATENCY`. The sequential injection into `shared_res_pipe(i)` at `i = LAT_X` is then reliable at every latency value and no bypass is needed.

**Benefit:** Removes the output process duplication entirely (~25 lines). The pipeline behaviour is uniform regardless of which IPs are instantiated or what their latencies are.

---

## Category 6: Minor Cleanup

### P17 — VRF inline FIFO `fifo_count` is 7 bits for a 64-entry FIFO

**File:** `vector_reg_file.vhd`

**Problem:** `fifo_count` is declared as `unsigned(6 downto 0)` (7 bits, range 0–127) but the FIFO is only 64 entries deep (6-bit head/tail pointers). The 7-bit width is needed to represent "64" (full) without wrapping, but it is not obvious why the counter is one bit wider than the pointer. By contrast, `sync_fifo` uses `integer range 0 to (2**ADDR_WIDTH)` which makes the intent clear.

**Proposed change:** Either use `integer range 0 to 64` (matching `sync_fifo`) or add a comment explaining the bit-width rationale. This issue also goes away if P9 is adopted (replacing the inline FIFO with `sync_fifo`).

**Benefit:** Removes a subtle type-width inconsistency.

---

### P18 — `vector_reduction_unit` hardcodes `latency => LAT_REDUCT` in the `fp_scalar_product` instantiation but also pads to `FPU_MAX_LATENCY` separately

**File:** `vector_reduction_unit.vhd`

**Problem:** The hardware IP `fp_scalar_product` is instantiated with `latency => LAT_REDUCT = 16`, and then the unit pads the result up to `FPU_MAX_LATENCY = 28` in software shift registers. The LAT_REDUCT constant appears only in this one instantiation. A reader must cross-reference the constants package to understand the split. If `LAT_REDUCT` is ever updated, the padding pipeline (`FPU_MAX_LATENCY - LAT_REDUCT = 12` cycles of shifting) automatically adjusts — but this is not stated anywhere.

**Proposed change:** Add a comment or local constant:
```vhdl
-- IP produces result at LAT_REDUCT cycles; the remaining
-- (FPU_MAX_LATENCY - LAT_REDUCT) cycles are absorbed by res_pipe
-- so all execution unit outputs arrive at the same cycle.
constant PAD_STAGES : integer := FPU_MAX_LATENCY - LAT_REDUCT;
```

**Benefit:** Makes the two-part latency budget explicit and self-documenting.

---

### P19 — `WARP_SIZE` generic in `mcu_scatter_gather` is never defaulted from a shared constant

**File:** `mcu_scatter_gather.vhd`, `memory_unit.vhd`, `processor.vhd`

**Problem:** `WARP_SIZE => 32` is passed through three levels of instantiation (`processor` → `memory_unit` → `mcu_scatter_gather`) as a raw integer literal. The value 32 is also baked into `instruction_issue` (its thread count) and `instruction_fetch_unit` (its active_mask width). There is no shared named constant tying them together: if you change one, the others must be found manually.

**Proposed change:** Add `constant WARP_SIZE : integer := 32;` to `processor_constants_pkg` (alongside the proposed `THREAD_ID_WIDTH` from P5) and use it as the default generic value at all instantiation sites.

**Benefit:** Single definition of warp size. Changing the warp size is a one-line edit rather than a grep-and-replace.

---

## Summary Table

| # | File(s) | Category | Effort | Benefit |
|---|---|---|---|---|
| P1 | `processor_constants_pkg` | Magic number | Low | Safety |
| P2 | `processor.vhd` | Magic number | Low | Readability |
| P3 | `processor.vhd` | Magic number | Low | Readability |
| P4 | `instruction_issue` | Magic number | Medium | Readability |
| P5 | `processor.vhd`, pkg | Magic number | Low | Readability |
| P6 | `processor.vhd` | FSM simplification | Low | Clarity |
| P7 | `processor.vhd`, `mcu_scatter_gather` | FSM simplification | Medium | Performance (-1 cycle/mem op) |
| P8 | `processor.vhd` | FSM simplification | Low | Clarity |
| P9 | `vector_reg_file` | Code reuse | Medium | Maintainability |
| P10 | `mcu_scatter_gather` | Code reuse | Medium | Correctness / Maintainability |
| P11 | `processor.vhd` | Code reuse | Medium | Correctness / Cleanliness |
| P12 | `processor_constants_pkg`, exec path | Type safety | Medium | Safety |
| P13 | `processor_constants_pkg`, decoder, IFU | Type safety | High | Safety |
| P14 | `instruction_fetch_unit` | Protocol fragility | High | Correctness |
| P15 | `instruction_decoder`, `processor.vhd` | Protocol fragility | Low | Readability |
| P16 | `fpu_lane` | Duplication | Medium | Correctness / Simplicity |
| P17 | `vector_reg_file` | Minor cleanup | Low | Readability |
| P18 | `vector_reduction_unit` | Minor cleanup | Low | Readability |
| P19 | All instantiation sites | Magic number | Low | Maintainability |
