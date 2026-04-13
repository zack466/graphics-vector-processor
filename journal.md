# TODO
* fully integrate all the components into a module that can be used in platform designer, works with memory and controlled by CSR
* check sin/cos resource usage, and switch to flopoco or something else if needed
  * test if flopoco arithmetic modules use less resources (I'm ok with losing out on a bit of precision)
  * everything can be done with flopoco floating point format, should only need to convert to IEEE when outputting to framebuffer for compatibility
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling
* test memory controller with real DDR3 memory
* (in progress) review documentation manually and verify that it is accurate
* (in progress) instead of triggering top-level for every warp invocation, add simple warp scheduler that just schedules the single warp to draw an entire frame.
  * could also implement latency hiding for memory operations? Would also help to simplify MCU. We definitely have enough M10K blocks.
* create top top level that can trigger processor to draw a frame, and keeps it in sync with the VIP framebuffer.
  should probably hardcode addresses of two backbuffers for double buffering.
* might be difficult, but try to duplicate the cores and have them work on parallel tasks using a warp scheduler (fitting may be hard).
  Or just one warp that utilizes latency hiding should be ok.
* replace reciprocal with division operation for better float precision? Figure out why gradient is slightly wrong at midpoint

# Agent changes

  ---
  Thread ID instruction (OP_THREAD_ID)

  processor_constants_pkg.vhd
  - Added CSR_ADDR_WARP_OFFSET = "110" — new R/W CSR for the warp base thread offset
  - Added OP_THREAD_ID = "001110" in the ALU opcode section

  processor.vhd
  - Added csr_warp_offset signal with reset + CSR write handler for CSR_ADDR_WARP_OFFSET
  - Added csr_warp_offset to the CSR read mux
  - Routes csr_warp_offset and iss_thread_id into the execution unit as new ports

  execution_unit.vhd
  - New ports: warp_offset_in (32-bit) and thread_id_in (5-bit)
  - s1_thread_id captures thread_id_in in the stage-1 latch (cycles through 0–31 with the barrel scheduler)
  - Both passed through to the ALU lane

  alu_lane.vhd
  - New ports: thread_id and warp_offset
  - OP_THREAD_ID case: raw_res <= unsigned(warp_offset) + resize(unsigned(thread_id), 32)
  - No decoder changes needed — OP_THREAD_ID in INST_TYPE_ALU already falls through to the vrf_we='1' branch correctly

  Usage: Write the warp's pixel base index to CSR_ADDR_WARP_OFFSET, then OP_THREAD_ID rd, mask in ALU type gives each thread rd = base + lane_index.

  ---
  SIMT Execution Model and IFU Fixes

  instruction_fetch_unit.vhd
  - Fixed "Unanimous BRA_DIV" bug: The SIMT stack now always pushes a reconvergence entry even if the warp does not diverge. This ensures that the mandatory `SYNC` instruction at the end of `if/else` blocks always has a valid stack entry to pop, preventing the Program Counter from getting lost.
  - Eliminated Execution Mask Lag: Refactored the `exec_mask_out` logic to be combinational. The active thread mask now updates instantly when a branch is taken, ensuring the first instruction of the new path executes with the correct mask.
  - Added "Inactive Warp" safety: If a branch is encountered while all threads are disabled, the IFU now defaults to the sequential path to prevent stack corruption.

  processor.vhd
  - Fixed Breakpoint Resume: The state machine now advances the PC before halting on an `OP_BREAK`. This allows the host to resume execution by simply toggling the `RUN` bit, without the processor getting stuck in a loop on the same breakpoint.
  - Added Start PC Override in DECODE: The FSM now checks for a forced Start PC while in the `DECODE` state, allowing the host to interrupt a running program and redirect it to a new entry point.

  Verification:
  - Validated all changes using `tb_instruction_fetch_unit` and `tb_processor`. 
  - Confirmed nested divergence and reconvergence work correctly across the full 32-thread warp.

  ---
  Thread ID Verification and Hazard Management

  tb_processor.vhd
  - Updated the test program to include explicit `asm_flush` calls between every register-writing instruction (`LDI_LO`, `LDI_HI`, `THREAD_ID`). This eliminates Read-After-Write (RAW) hazards caused by the 37-cycle ALU pipeline latency.
  - Set `Warp Offset` to 64 and verified that `THREAD_ID` calculation correctly incorporates the CSR base.
  - Expanded memory verification to check all 32 threads and all 4 vector components (X, Y, Z, W) for `DEADBEEF`.

  vector_reg_file.vhd
  - Re-enabled component-level write masking. Each word in the vector (X, Y, Z, W) is now only updated if its specific bit in the write mask is asserted, preventing accidental overwrites.

  execution_unit.vhd
  - Restored proper writeback multiplexing logic. ALU and Reduction results are now correctly broadcast to all vector components (X, Y, Z, W) of the output bus, matching the behavior expected by the VRF write mask.

  Verification:
  - `make test-tb_processor` confirms that `THREAD_ID` is correctly calculated as `warp_offset + lane_id` and stored to memory at thread-indexed addresses.


  ---
  Swizzle Unit Optimization

  To reduce FPGA routing complexity, the swizzle network has been rewritten to support a simplified set of modes instead of arbitrary component shuffling. The new modes support standard vector operations and common scalar broadcasting tasks.

  vector_types.vhd
  - Redefined `swizzle_sel_t` from an array of four 2-bit vectors to a single 3-bit logic vector (`std_logic_vector(2 downto 0)`).

  processor_constants_pkg.vhd
  - Added new `SWIZ_X` constants:
    - `SWIZ_PASS` = "000" (.xyzw / passthrough)
    - `SWIZ_X`    = "100" (.xxxx / splat X)
    - `SWIZ_Y`    = "101" (.yyyy / splat Y)
    - `SWIZ_Z`    = "110" (.zzzz / splat Z)
    - `SWIZ_W`    = "111" (.wwww / splat W)

  instruction_decoder.vhd
  - Updated swizzle parsing logic to extract 3-bit sections of the instruction word instead of 8 bits.
  - Set `SWIZ_PASS` as the default value across all pipeline records.

  swizzle_network.vhd
  - Replaced the arbitrary 4-component loop-based multiplexer with simple `case` statements using the predefined 3-bit swizzle types. The unit now outputs either the original vector or broadcasts a single component to all four elements.

  Verification:
  - Updated `tb_swizzle_network` and integration testbenches (`tb_full_execution_integration`, `tb_issuer_writeback_integration`, `tb_instruction_issue`) to use the new `SWIZ_*` constants and to avoid invalid shuffle assertions.
  - Confirmed `make test-all` passes with the updated swizzle framework.

  ---
  Integration Test Fixes

  Fixed `tb_full_execution_integration` to correctly verify the new swizzle modes:
  - Phase 6's verification updated since `.xz = v0.yxxa * v0.zzyy` was removed. It now tests `.xz = v0.yyyy * v0.zzzz`. The expected Z component check was adjusted to match `(i * 4 + 1) * (i * 4 + 2)`.
  - Phase 8's reduction assertion updated. Instead of testing `SUM(v0.yyzz)`, it now tests `SUM(v0.yyyy)`. The expected result checks were adjusted to match `4 * v0.y = 16*i + 4` instead of `16*i + 6`.

  ---
  Documentation Updates

  README.md
  - Updated section "4.1. Hardware Modifiers" to note the new swizzle limitations (only passthrough and splatting are supported to reduce routing pressure).

  ---
  Added Documentation to Swizzle Network

  swizzle_network.vhd
  - Added a header block explaining the purpose of the swizzle network, the recent optimization limiting it to passthrough and splatting, its I/O interfaces, and its 0-cycle combinational timing constraint.
  - Added section comments to the main processing block detailing exactly how the inputs are evaluated and routed.

  ---
  Automated Test Framework & Pipeline Alignment Fix

  Created a robust automated test framework to execute real assembly programs on the processor:
  - `tools/assembler.py`: Parses human-readable assembly syntax into hexadecimal machine code.
  - `src/tb_processor_automated.vhd`: A dedicated testbench that loads `program.hex` into instruction memory, executes the code until `OP_RETURN` is hit, and dumps the memory contents (framebuffer) to `memory_dump.hex`.
  - `tools/runner.py`: A Python test runner that manages the entire lifecycle, assembling the code, invoking GHDL via a Makefile, parsing the resulting `memory_dump.hex`, and using Pillow to render the output as a `.png` image for visual validation.

  During development of this framework, an intricate pipeline alignment bug was discovered and fixed:
  - The `execution_unit.vhd` was routing VRF read data (`vrf_rs1_data`) directly into the combinational logic of `alu_lane` and `fpu_lane` during Stage 1 (`s1`). However, because the M10K block in `vector_reg_file.vhd` requires a full clock cycle to output data after the address is registered, the data arriving in `s1` actually belonged to the *previous* thread. 
  - To solve this, the math execution lanes were shifted to evaluate in Stage 2 (`s2_ctrl`, `s2_valid`), perfectly aligning their combinational inputs with the 1-cycle latency VRF read outputs.
  - The `writeback_controller.vhd` pipeline shift was adjusted (`FPU_MAX_LATENCY-1`) to remain perfectly synchronized with the newly aligned `alu_lane` outputs arriving in cycle N+29.
  - Added proper `(others => '0')` initialization to the `vector_reg_file.vhd` `ram_type` variables to prevent uninitialized memory (`U`) from causing simulation artifacts (appearing as `X` conflicts on the data bus).

  ---
  Assembler TYPE Constant Bug Fix & Incremental Test Validation

  Root cause identified and fixed: all ALU instructions (THREAD_ID, ISHL, IADD, etc.) were silently doing nothing in simulation due to a mismatch between `tools/assembler.py` and `src/processor_constants_pkg.vhd`.

  The bug: `assembler.py` had TYPE_ALU = 1, TYPE_CTRL = 2, TYPE_RED = 3, but the VHDL defines INST_TYPE_CTRL = 1, INST_TYPE_RED = 2, INST_TYPE_ALU = 3. The order of types 1-3 was wrong. IMM/MEM/SYS (4/5/6) were coincidentally correct, so LDI, STORE, and FLUSH all worked. TYPE_FPU = 0 was also correct.

  Because ALU instructions were encoded with type 1 (= INST_TYPE_CTRL, branches), the processor advanced the PC without executing them. This caused v0 (THREAD_ID) and v2 (ISHL result) to remain zero for all threads. The MCU then read zero from v2 for every thread's offset, resulting in all 32 STORE commands dispatching separate burst-length-1 writes, all to address 0x00000000. Only the first pixel was ever written.

  The debugging process involved:
  - Adding `report` statements to `vector_reg_file.vhd` (VRF write log) confirming that only v1 and v3 were ever written — v0 and v2 had no write entries.
  - Adding `report` statements to `mcu_scatter_gather.vhd` (GATHER_ADDR and FETCH_WDATA) confirming the MCU read vrf_X=0 for all threads, and that each thread was getting its own burst of length 1 rather than one coalesced burst of 32.
  - Adding a detailed write log to `avm_sim_memory.vhd` confirming all writes went to address 0x00000000.

  tools/assembler.py
  - Fixed TYPE constants to match VHDL: TYPE_FPU=0, TYPE_CTRL=1, TYPE_RED=2, TYPE_ALU=3, TYPE_IMM=4, TYPE_MEM=5, TYPE_SYS=6.

  All debug `report` statements added during investigation were removed after the fix was confirmed.

  Verification (incremental tests, all passing after fix):
  - test01_thread_id.s: pixel N = raw integer N for all 1024 pixels across all 32 warps. ✓
  - test02_i2f.s: pixel N = IEEE-754 float(N) (0.0, 1.0, 2.0, ...). ✓
  - test03_ldi.s: all 1024 pixels = 0x3F800000 (1.0f) constant. ✓

  ---
  Barrel Scheduler, Write Mask, Control Flow, and Image Tests

  Six new tests exercising the remaining major features of the processor:

  tools/assembler.py
  - Fixed SYNC instruction parsing: CTRL instructions with no arguments (SYNC) now
    default to target_addr=0 instead of crashing with IndexError.

  test04_alu_chain.s — Barrel Scheduler ALU Chain
  - Dependent ALU chain WITHOUT FLUSH between instructions:
    THREAD_ID(v0) → IADD(v3=2*tid) → ISHL(v2=16*tid) → IADD(v4=4*tid)
  - Demonstrates that the barrel scheduler provides natural 32-cycle separation
    between same-thread instructions, which exceeds the ~29-cycle ALU writeback
    latency. No intermediate FLUSHes needed.
  - FLUSH is still required before STORE to ensure VRF is fully written before
    the MCU reads it.
  - Result: pixel N = {4*N, 4*N, 4*N, 4*N} as raw integers. ✓

  test05_fpu_chain.s — Barrel Scheduler FPU Chain
  - Dependent FPU chain WITHOUT FLUSH:
    THREAD_ID(v0) → I2F(v1=float(tid)) → FMUL(v3=tid^2)
  - FPU_MAX_LATENCY=28 stages; 32-cycle separation still exceeds 29 cycles.
  - Result: pixel N = IEEE-754 float(N^2). ✓
    (0.0, 1.0, 4.0, 9.0, 16.0, 25.0, ...)

  test06_write_mask.s — Per-Component ALU Write Mask
  - IADD v4.xy, v0, v0: write mask "0011" (bits X and Y only).
  - v4.z and v4.w are never written, staying at VRF init value of 0.
  - Result: pixel N = {W=0, Z=0, Y=2N, X=2N}. ✓

  test07_control_flow.s — SIMT Divergence (Even/Odd)
  - ICMP_EQ + FLUSH + SSY + BRA_DIV + SYNC divergence sequence.
  - Key insight: ALU/FPU/IMM instructions run for ALL 32 threads regardless of
    exec_mask; only STORE respects exec_mask. The final stored value is correct
    because each path's STORE only writes memory for its active threads.
  - Even threads (tid&1==0) store 0x3F800000 (1.0f = white).
  - Odd threads store 0x00000000 (0.0f = black).
  - Result: alternating white/black pixels across all 32 warps. ✓

  test08_checkerboard.s — 32×32 Checkerboard Image
  - Computes x = global_tid & 0x1F, y = global_tid >> 5.
  - Color = white if (x+y) is even, black otherwise.
  - Uses ICMP_EQ + SSY + BRA_DIV + SYNC for divergence.
  - Result: correct 32×32 checkerboard (test08_checkerboard.png). ✓

  test09_gradient.s — 32×32 RGB Gradient Image
  - R (X component) = float(x) / 32 = x/32  (increases left to right)
  - G (Y component) = float(y) / 32 = y/32  (increases top to bottom)
  - B (Z component) = 0.0f (never written, stays at VRF init)
  - A (W component) = 1.0f (fully opaque)
  - Uses per-component FPU write masks to assemble the 4-channel output vector:
    FMUL v14.x, v11, v13 / FMUL v14.y, v12, v13 / FMUL v14.w, v13, v13
  - Result: smooth red-green gradient (test09_gradient.png). ✓

  Memory layout reference (confirmed):
  - Dump format: "W Z Y X" per line (MSB to LSB of 128-bit bus word)
  - runner.py maps: parts[3]=X=R, parts[2]=Y=G, parts[1]=Z=B, parts[0]=W=A

  ---
  Design Simplification Pass (proposals.md → implemented)

  All changes verified: 9/9 automated tests pass before and after each group.
  Proposals P9, P12, P13, P14, P16 were assessed as too invasive and skipped.

  **Group A — processor_constants_pkg.vhd** (P1, P5, P19)
  - P1: `FPU_MAX_LATENCY` now derived as `LAT_FRSQRT` instead of hardcoded 28.
    Future IP latency changes only require updating the relevant LAT_* constant.
  - P5: Added `THREAD_ID_WIDTH = 5`, `LOCAL_REG_WIDTH = 4`, `VRF_ADDR_WIDTH = THREAD_ID_WIDTH + LOCAL_REG_WIDTH`.
    Eliminates scattered magic 5/4/9 literals.
  - P19: Added `WARP_SIZE = 32` as a named constant in the package.

  **Group B — processor.vhd** (P2, P3, P6, P8, P11, P15)
  - P2: Signal declarations and component instantiations (u_vrf, u_prf, u_issue) now
    use `VRF_ADDR_WIDTH`, `THREAD_ID_WIDTH`, `LOCAL_REG_WIDTH` instead of magic 9/5/4.
  - P3: `mem_phys_addr <= dec_mem.base_addr & x"0000"` extracted as a named concurrent
    signal instead of inline concatenation at the port map call site.
  - P6: FSM states renamed `FETCH_1 → FETCH_ADDR`, `FETCH_2 → FETCH_DATA` for clarity.
  - P8: EXEC_WAIT exit condition split: for arithmetic ops only `iss_issue_valid='0'`
    is checked; `exec_flush_active='0'` is additionally required only for FLUSH.
    Before: `iss_issue_valid='0' and exec_flush_active='0'` for all cases.
    After:  `iss_issue_valid='0' and (opcode/=OP_FLUSH or exec_flush_active='0')`.
  - P11: Added explanatory comment for the four `rs*_addr_local <= "0000"` dead-field
    assignments (the execution unit reads VRF data buses, not local addr fields).
  - P15: Added explicit `elsif v_type = INST_TYPE_SYS then null;` branch in the
    exec_mux_ctrl process so SYS fall-through to dec_fpu defaults is visible.

  **Group C — instruction_issue.vhd** (P4)
  - Replaced 6-bit `count` sentinel (idle = 32) with a separate `active : std_logic`
    flag and a 5-bit `count` (range 0–31).
  - `active='1'` during threads 1–31 replay; `active='0'` when idle or after FLUSH.
  - `issue_valid <= '1' when valid_in='1' or active='1'` (was `count < 32`).
  - FLUSH now clears `active='0'` immediately (was `count <= 32`), same single-cycle
    behavior but without the sentinel magic number.

  **Group D — mcu_scatter_gather.vhd + processor.vhd** (P7)
  - `mem_stall` changed from registered to combinational in the MCU:
    `mem_stall <= '1' when (state=IDLE and mem_op_valid='1') or
                           (state/=IDLE and state/=FINISH) else '0';`
  - This asserts stall on the same cycle as the `mem_op_valid` pulse, eliminating
    the 1-cycle propagation delay.
  - `MEM_WAIT_START` state removed from processor FSM (was needed as a bubble for the
    registered stall). DECODE now goes directly to MEM_WAIT.
  - No combinational loop: `mem_op_valid` is only driven in DECODE; `mem_stall` is
    read in MEM_WAIT; the state register breaks any feedback.
  - Performance gain: every memory instruction saves 1 cycle (MEM_WAIT_START removed).

  **Group E — comment-only fixes** (P10, P17, P18)
  - P10 (mcu_scatter_gather.vhd): Added "2-CYCLE VRF READ PIPELINE" header comments
    to both GATHER_ADDR and FETCH_WDATA states explaining the shared M10K latency
    contract and why each state uses a different tracking idiom.
  - P17 (vector_reg_file.vhd): Added comment to `fifo_count : unsigned(6 downto 0)`
    explaining why 7 bits are needed for a 64-entry FIFO (must represent 64 without
    wrapping, requiring one extra bit beyond the 6-bit head/tail pointers).
  - P18 (vector_reduction_unit.vhd): Added `constant PAD_STAGES : integer :=
    FPU_MAX_LATENCY - LAT_REDUCT;` and updated res_pipe comment to reference it,
    making the two-part latency budget (IP core + padding) self-documenting.


# DONE: Add S2 Register Stage and Clean Up WB Controller Timing

## What was done

### `src/execution_unit.vhd`
- Added S2 pipeline stage: `s2_swiz_a`, `s2_swiz_b`, `s2_rs3`, `s2_valid`, `s2_ctrl`,
  `s2_inst_type`, `s2_red_mode`, `s2_red_mask`, `s2_thread_id`, `s2_warp_offset`, `s2_rd_addr`
- Added `s1_warp_offset` and `s1_rd_addr` to the existing S1 register stage
- Swizzle network still runs combinationally in S1; its outputs are registered into S2
- Functional unit enables (`fpu_en`, `alu_en`, `red_en`) now derive from `s2_valid`/`s2_inst_type`
- All functional unit port maps updated to use S2 signals
- Writeback controller now driven from S2 (`s2_rd_addr`, `s2_ctrl.*`, `s2_valid`)
- Flush shift register size unchanged (FPU_MAX_LATENCY bits); coverage is correct
  because the VRF write commit time is N+2+FPU_MAX_LATENCY in both old and new designs

### `src/writeback_controller.vhd`
- Reduced depth from `FPU_MAX_LATENCY+1` to `FPU_MAX_LATENCY` (removed the off-by-one)
- Array bounds changed from `(0 to FPU_MAX_LATENCY)` to `(0 to FPU_MAX_LATENCY-1)`
- Loop and output taps updated accordingly

## Final pipeline (from valid_in at cycle N)
- Cycle N   : valid_in='1'; VRF addresses driven; S1 captures all control inputs
- Cycle N+1 : VRF data stable; s1_valid='1'; swizzle runs combinationally → swiz_a/b_out
              S2 registers capture: s2_swiz_a/b, s2_ctrl, s2_rd_addr, etc.
- Cycle N+2 : s2_valid='1'; fpu_en/alu_en/red_en fire; functional units start;
              WB controller loads pipe(0) from S2 signals
- Cycle N+2+FPU_MAX_LATENCY: FPU result valid; WB controller pipe(FPU_MAX_LATENCY-1)
              drives wb_* outputs; VRF write commits at the following rising edge

## Why this is clean
- S2 is the single start-of-execution reference point for both functional units and WB
- WB depth = FPU_MAX_LATENCY exactly (direct 1:1 with FPU pipeline depth, no +1)
- No cross-module timing dependencies; execution_unit is self-contained
- SRAM→swizzle→FPU critical path broken by S2 register

## Date: 2026-04-11

### Fixed vector_reduction_unit testbench
- Changed the polling loop in `tb_vector_reduction_unit.vhd` from `1 to FPU_MAX_LATENCY` to `1 to FPU_MAX_LATENCY - 1` to accurately reflect the timing when `valid_out` is asserted.
- Verified that the `vector_reduction_unit` testbench now passes successfully without any assertion errors.


## Date: 2026-04-11

### Architectural Refactor: processor.vhd → frame_processor + warp_unit + warp_scheduler

Replaced the monolithic `processor.vhd` (single-warp processor with an embedded CSR slave and MCU) with a three-level hierarchy that cleanly separates frame-level scheduling, warp execution, and memory output.

**Motivation:**
The old `processor.vhd` mixed host interface logic (CSR writes to set warp_offset, assert RUN), the IFU/decode/issue/exec pipeline, and the Avalon memory controller all into one entity. This made it impossible to schedule multiple warps or context-switch between them, and required the host to manually write 32 separate CSR sequences per frame (one per warp). The refactor removes all of that host-visible machinery and replaces it with a hardware FSM that iterates warps autonomously.

**New files:**
- `src/warp_unit.vhd` — Self-contained SIMT warp. Contains the IFU, instruction decoder, issue unit, execution unit (FPU/ALU/RED), VRF, PRF, and pixel snoop buffer. Exposes `warp_start`/`warp_halted`/`warp_break` control signals and a flat `pixel_buf_data[1023:0]` output (32 packed pixels). Has no host CSR interface and no embedded MCU.
- `src/warp_scheduler.vhd` — Frame-level FSM. Accepts a `frame_start` pulse and `frame_width`/`frame_height` inputs. Computes `total_pixels = frame_width * frame_height`, then iterates `warp_offset` from 0 to `total_pixels-1` in steps of 32, pulsing `warp_start` for each block. Asserts `frame_done` when the last warp halts. States: IDLE → DISPATCH → WAIT_RUNNING → WAIT_HALT → DONE.
- `src/frame_processor.vhd` — Top-level structural entity (pure wiring). Instantiates `instruction_memory`, `warp_scheduler`, `warp_unit`, `mcu_block_transfer`, and `avm_burst_bridge`. Exports `frame_start`/`frame_done`/`frame_width`/`frame_height` upward and the `avm_*` Avalon-MM master bus outward.
- `src/tb_frame_processor_automated.vhd` — Automated testbench replacing `tb_processor_automated.vhd`. Instantiates `frame_processor` + `avm_sim_memory`. Uses generics `PROGRAM_FILE`, `MEMORY_DUMP_FILE`, `FRAME_WIDTH`, `FRAME_HEIGHT`, `DUMP_START_ADDR`, `DUMP_END_ADDR`. Drives a single `frame_start` pulse and waits for `frame_done` rather than writing CSR registers in a loop.
- `src/tb_frame_processor.vhd`, `src/tb_warp_unit.vhd`, `src/tb_warp_scheduler.vhd` — Additional unit and interactive testbenches.

**Deleted files:**
- `src/processor.vhd` — replaced by the three-file hierarchy above.
- `src/tb_processor.vhd` — tested the deleted entity.
- `src/tb_processor_automated.vhd` — replaced by `tb_frame_processor_automated.vhd`.

**Updated files:**
- `src/Makefile` — removed `processor.vhd` from SOURCES; added `warp_unit.vhd`, `warp_scheduler.vhd`, `frame_processor.vhd`. Replaced old testbench targets with `tb_frame_processor_automated`.
- `tools/runner.py` — changed elaboration target to `tb_frame_processor_automated`.
- `tools/run_all_tests.py` — updated SIM_EXE and elaboration target; added print confirmation after PNG save.

**Bug fix (VHDL case-insensitivity):**
The initial `tb_frame_processor_automated.vhd` used signal names `frame_width`/`frame_height` which silently collided with generics `FRAME_WIDTH`/`FRAME_HEIGHT` (VHDL is case-insensitive), causing port bindings to resolve to the constant generic values rather than the driven signals. Fixed by renaming the signals to `fp_width`/`fp_height`.

**Verification:** All 9 assembly tests pass (9/9) with `tb_frame_processor_automated`. PNG images are generated for all tests.

**Known issues (not yet fixed):**
- *Thread 31 snoop timing:* Fixed — see entry below.
- *LDI partial write mask:* The IMM instruction format uses a single `full_mask` bit (bit [9]). A partial register mask (e.g., `.w`) sets `full_mask=0`, which decodes to `write_mask="0000"` — nothing is written. `test01_thread_id.s` uses `LDI_LO v0.w, 0x00FF` expecting to set only the W component; the instruction silently does nothing.

---

## Date: 2026-04-11

### Fix: Thread 31 snoop timing bug (extra column in output images)

All generated images had 33 apparent columns instead of 32. The rightmost column was a duplicate of the 32nd column (thread 30's pixel value). Root cause was a VHDL delta-cycle ordering hazard in `warp_unit.vhd`.

**Root cause:**
The pixel snoop buffer is written in a registered `process(clk)` — `pixel_snoop[thread_id] <= data` commits at the rising edge of the cycle when `exec_mem_store_valid='1'`. Thread 31 is the last to be issued; when `iss_issue_valid` drops to '0' (signaling all 32 threads have been issued), `exec_mem_store_valid` is still '1' in that same delta-cycle phase. The combinational EXEC_WAIT state saw `iss_issue_valid='0'` and immediately asserted `pixel_buf_valid`, but VHDL resolved the registered write to `pixel_snoop[31]` in the same delta cycle — the MCU latched `pixel_buf_data` before `pixel_snoop[31]` was updated, always reading the previous warp's thread-31 value.

**Fix (`src/warp_unit.vhd`):**
1. Added `exec_mem_store_valid` to the combinational Process B sensitivity list.
2. Added a guard `if exec_mem_store_valid = '0'` before asserting `pixel_buf_valid` in the EXEC_WAIT MEM branch, so the FSM holds one extra cycle until the last snoop write has committed.

```vhdl
-- Before:
if iss_issue_valid = '0' and (...) then
    if ifu_inst_out(3 downto 0) = INST_TYPE_MEM then
        pixel_buf_valid <= '1';
        next_state      <= MEM_WAIT;

-- After:
if iss_issue_valid = '0' and (...) then
    if ifu_inst_out(3 downto 0) = INST_TYPE_MEM then
        if exec_mem_store_valid = '0' then
            pixel_buf_valid <= '1';
            next_state      <= MEM_WAIT;
        end if;
```

**Verification:** Checkerboard dump row 0 beat 7 (threads 28–31) changed from `00000000 FFFFFFFF 00000000 FFFFFFFF` (thread 31 wrongly white) to `00000000 00000000 FFFFFFFF 00000000` (thread 31 correctly black, x+y=31 odd). All 9/9 tests pass with correct images.

Also removed the TODO entry "fix the issue where the output images have an extra column" from the top of this file.

---

## Date: 2026-04-11

### Fix: PNG images not generated — Pillow missing from uv project

Running `python tools/run_all_tests.py` produced simulation output but no PNG images. The `generate_image` function silently catches `ImportError` from PIL and returns without generating anything. The project uses `uv` for Python dependency management, and Pillow had never been added to `pyproject.toml`.

**Fix:** Added Pillow via `uv add pillow`. This installed Pillow 12.2.0 into the managed venv and added the dependency to `pyproject.toml` and `uv.lock`. PNG generation now works when the scripts are invoked via `uv run python`.

**Important:** Always use `uv run python tools/run_all_tests.py` (not bare `python`) to ensure the managed venv is active and Pillow is available.

---

### Simplified Memory Controller (Block Transfer & Pixel Packing)
- Deprecated `mcu_scatter_gather.vhd` in favor of a new `mcu_block_transfer.vhd` design.
- The new memory controller strictly enforces 128-bit sequential Avalon burst reads/writes instead of arbitrary non-sequential accesses.
- Added a 32x32-bit (1024 bit) `warp_output_buffer` inside the memory controller.
- Modified `OP_STORE` instruction decode logic in `instruction_decoder.vhd` and `processor.vhd` to dispatch memory instructions through the `execution_unit` barrel scheduler.
- As the barrel scheduler issues threads 0 through 31, the `execution_unit` snoops VRF Port A read data and provides `mem_store_valid`, `mem_store_data`, and `mem_store_thread_id` to the memory controller.
- The memory controller automatically packs the pixel components (the lower 8 bits of X, Y, Z, W) into 32-bit integers and populates its internal warp buffer.
- When the 32-cycle scheduling completes, the FSM transitions to `MEM_WAIT` and signals the memory controller to emit 8 sequential 128-bit write beats to Avalon.
- Re-wrote and validated all behavior via the new `tb_mcu_block_transfer.vhd` testbench.

### Automated Tests and Memory Block Store Updates
- Discovered and fixed a massive simulation slowdown caused by incorrectly exposing floating point units to combinational toggles during memory instructions. Reverted the FPU optimization that was causing it.
- Fixed a bug where block stores from different warps were continually overwriting address `0x0000`. Updated `processor.vhd` to automatically add `csr_warp_offset * 4` to the base address provided by the `STORE` instruction, correctly spacing out each warp's 128-byte chunk in the framebuffer.
- Fixed SIMT divergence failures in `STORE` logic by routing `exec_mask` from the `memory_unit` into the `mcu_block_transfer` controller, allowing masked threads to output `"0000"` to the Avalon `tx_byte_en` line so masked pixels are untouched in memory.
- Fixed an issue where the image output was 64x16 instead of 32x32 by correctly setting `DUMP_END_ADDR` to 4096 (1024 pixels * 4 bytes per pixel) instead of 16384.
- Cleaned up the `mcu_block_transfer.vhd` code by removing all states and logic related to `LOAD` instructions, as they are no longer supported by the block transfer architecture.
- Modified automated tests in `tools/*.s` to conform to the new block store architecture (removed `offset_reg` usage in `STORE`, changed memory output format to expect packed RGBA pixels).
- Updated tests to rescale floating-point color values from 0.0-1.0 to integer values from 0-255 using the `F2I` (Float-to-Integer) instruction before storing to the block memory buffer.
- Updated `tools/runner.py` and `tools/check_pixels.py` to parse 32-bit packed integers instead of floats.
- Updated `programming_manual.md` and `README.md` to reflect the new `STORE`/`LOAD` format and block transfer memory controller.


## Date: 2026-04-11

### Added MOV FPU instruction

Added `OP_MOV` (opcode `"010010"`, decimal 18) as a new FPU-type instruction that copies one vector register into another with a write mask (`rd.mask = rs1`).

**Files changed:**
- `src/processor_constants_pkg.vhd` — Added `OP_MOV` constant.
- `src/instruction_decoder.vhd` — Added `OP_MOV` to the standard FPU math ops case branch (sets `vrf_we='1'`, `prf_we='0'`, `wb_mux_sel=WB_MUX_FPU`).
- `src/fpu_lane.vhd` — MOV is handled as a zero-latency passthrough: `op_a` is injected into `shared_res_pipe(1)` at pipeline stage i=1 (same pattern as PAND/POR/PXOR zero-latency predicate ops). Added `op_a` to the output process sensitivity list and the FPU_MAX_LATENCY=0 bypass guard.
- `tools/assembler.py` — Added `'MOV': 18` to `FPU_OPCODES`.

**Assembly syntax:** `MOV rd.mask, rs1[.swiz]` — identical to other two-operand FPU instructions; `rs2` is unused (assembler defaults to 0).


## Date: 2026-04-12

### Added function call instructions: BRA_L, BRA_X, PUSH_L, POP_L

Added a link register and a small dedicated call stack to the IFU, supporting warp-wide (convergent) function calls without a data stack.

**New instructions:**
- `BRA_L target` — Branch with link: saves `PC+1` into the link register, jumps to `target`. Used to call a function.
- `BRA_X` — Branch to link register: restores the PC from the link register. Used to return from a leaf function.
- `PUSH_L` — Pushes the link register onto the call stack. Used by non-leaf callers before making a nested `BRA_L`.
- `POP_L` — Pops the call stack into the link register. Used to restore the caller's return address before `BRA_X`.

**New opcodes (CTRL type):**
- `OP_BRA_L = "110110"` (54), `OP_BRA_X = "110111"` (55)
- `OP_PUSH_L = "111000"` (56), `OP_POP_L = "111001"` (57)

**Architecture notes:**
- The `branch_type` field in `pc_ctrl_t` was expanded from 3 bits to 4 bits to accommodate the 4 new branch type codes (`BR_BRA_L`, `BR_BRA_X`, `BR_PUSH_L`, `BR_POP_L`) alongside the existing 7. All comparisons use named constants so the width change is backward-compatible.
- `CALL_STACK_DEPTH = 8` constant added to `processor_constants_pkg.vhd`. The IFU has a matching `CALL_STACK_DEPTH` generic (default 8).
- The call stack is entirely separate from the SIMT divergence stack: call instructions are warp-wide and never interact with thread masking.

**Files changed:**
- `src/processor_constants_pkg.vhd` — Added `CALL_STACK_DEPTH`, expanded `branch_type` to 4 bits, added 4 new `BR_*` and `OP_*` constants.
- `src/instruction_decoder.vhd` — Added decode cases for the 4 new CTRL opcodes.
- `src/instruction_fetch_unit.vhd` — Added `CALL_STACK_DEPTH` generic, `link_reg`, `call_stack`, and `csp` signals; added reset handling; added 4 new branch cases (7–10) in the PC-update process.
- `tools/assembler.py` — Added `BRA_L`, `BRA_X`, `PUSH_L`, `POP_L` to `CTRL_OPCODES`.

**New test:**
- `tools/test10_call_stack.s` — Assembly program that calls a leaf function (tests BRA_L/BRA_X), copies the result with MOV, calls a non-leaf function that internally uses PUSH_L/POP_L for nesting, then stores to memory.
- `src/tb_call_stack.vhd` — VHDL testbench that programs `warp_unit` with the above program, verifies `pixel_buf_valid` fires, checks all 32 thread pixels = `0x42424242`, and confirms clean halt.
- All 18 testbenches pass after the change.

  ---
  RETURN reg: combined pixel-write and warp-halt instruction

  Consolidated STORE + bare RETURN into a single `RETURN reg` instruction that
  reads the source register, writes the framebuffer via an 8-beat Avalon burst,
  and halts the warp — all in one opcode. This eliminates the need for a separate
  STORE before the end of every shader and simplifies the standard shader epilogue
  from `FLUSH / STORE vN, 0x0000 / FLUSH / RETURN` to just `FLUSH / RETURN vN`.

  Encoding: `(63 << 26) | (reg_idx << 4) | TYPE_SYS`.
  Examples: `RETURN v2` = 0xFC000026, `RETURN v15` = 0xFC0000F6.

  The fb_base_addr (16-bit upper word of the DDR3 byte address) now flows through:
    frame_processor → warp_scheduler (pass-through) → warp_unit.
  This enables future double-buffering by toggling fb_base_addr between frames.

  FSM changes in warp_unit.vhd:
  - DECODE: OP_RETURN issues through barrel scheduler (iss_valid_in='1') → EXEC_WAIT.
  - EXEC_WAIT: added OP_RETURN alongside INST_TYPE_MEM for the pixel_buf_valid path.
  - MEM_WAIT: OP_RETURN → HALTED (not ADVANCE_PC like STORE).

  Instruction address update: test10_call_stack.s reduced from 14 to 12 instructions
  (leaf moves from PC 8→6, outer from PC 10→8) since STORE+FLUSH+RETURN→RETURN reg
  saves 3 instructions. BRA_L targets updated accordingly.

  Root-cause of stale program.hex: program.hex retained the old 14-instruction
  encoding (STORE+RETURN style), causing the automated testbench to fire two
  pixel_buf_valid pulses per warp. The second fire (from old bare RETURN now
  decoded as RETURN v0) overwrote correct pixels with zeros. Fixed by regenerating
  program.hex from the updated test10_call_stack.s.

  Files changed:
  - src/execution_unit.vhd — added OP_RETURN to mem_store_valid condition.
  - src/warp_unit.vhd — new fb_base_addr port; mem_phys_base mux; FSM DECODE/
    EXEC_WAIT/MEM_WAIT updates for OP_RETURN; DECODE mux for register extraction.
  - src/warp_scheduler.vhd — added fb_base_addr/fb_base_out pass-through ports.
  - src/frame_processor.vhd — added fb_base_addr port, wired through scheduler.
  - src/tb_warp_unit.vhd — updated to use fb_base_addr port and RETURN v1.
  - src/tb_call_stack.vhd — updated BRA_L targets (PC 6/8) and RETURN v2.
  - src/tb_frame_processor.vhd — updated program to FLUSH + RETURN v1.
  - src/tb_frame_processor_automated.vhd — added FB_BASE_ADDR generic.
  - src/tb_warp_scheduler.vhd — added fb_base_addr/fb_base_out connections.
  - src/Makefile — added test-gradient target.
  - src/program.hex — regenerated from test10_call_stack.s (12 instructions).
  - tools/assembler.py — RETURN now accepts an optional register argument.
  - tools/test09_gradient.s — updated epilogue to FLUSH + RETURN v15.
  - tools/test10_call_stack.s — updated BRA_L targets and epilogue.
  - programming_manual.md — documented RETURN reg, updated FLUSH rules and examples.

  All 19 testbenches (including make test-gradient) pass.

---

## Date: 2026-04-12

### Enforce RETURN-not-in-divergence rule: assembler, compiler, and test updates

**Motivation:** `RETURN reg` triggers the pixel snoop and warp halt in a single instruction. Because all 32 threads of a warp execute instructions in lockstep and ALU/FPU register writes are not masked by `exec_mask`, a `RETURN reg` inside a divergent path (between `SSY` and its two `SYNC` instructions) would fire once for the not-taken path's active mask and again for the taken path's mask, producing two pixel writes per warp and corrupting memory. The instruction must only appear after the reconvergence point.

**tools/assembler.py:**
- Removed `'STORE': 33` from `MEM_OPCODES` — STORE has been replaced by `RETURN reg` and is no longer present in the hardware.
- Added a static validation pass (Pass 1b) between label resolution and code emission. The pass tracks `ssy_count` and `sync_count`; when `ssy_count * 2 > sync_count` and a `RETURN reg` instruction is encountered, assembly is aborted with a clear error message. This catches the error before a hex file is produced.

**tools/compiler.py:**
- Added `self.divergence_depth = 0` to `SemanticAnalyzer.__init__`.
- `visit_IfStmt` increments `divergence_depth` before visiting the false/true blocks and decrements it after the second `SYNC`.
- `visit_Assign`: if the assignment target is `out_color` and `divergence_depth > 0`, a `CompileError` is raised with a message explaining the constraint.

**tools/test07_control_flow.s:**
- Rewrote to use branchless ALU computation (no `SSY`/`BRA_DIV`/`SYNC`). The even/odd pixel values are now computed as `(1 − (tid & 1)) × 255` using `IAND`, `ISUB`, and `IMUL`. Expected output unchanged: even pixels = 255, odd pixels = 0.

**tools/test08_checkerboard.s:**
- Rewrote to use branchless ALU computation. The checkerboard parity is computed as `(1 − ((x+y) & 1)) × 255` using `IAND`, `ISUB`, and `IMUL`. Expected output unchanged: white (255) if (x+y) even, black (0) if (x+y) odd.

---

## Date: 2026-04-12

### IMM instruction: full 4-bit component write-mask (replaces 1-bit full_mask)

**Problem:** `LDI_LO`/`LDI_HI` used a single `full_mask` bit (instruction[9]) that produced either `write_mask="1111"` or `write_mask="0000"`. There was no way to write only a subset of components (e.g. `.w` only), making patterns like `LDI_LO v0.w, 0x00FF` silently write nothing. ALU/FPU instructions have always supported a 4-bit mask; this inconsistency was a known bug.

**New IMM instruction encoding:**
```
[31:30] = LDI sub-op   (2 bits: "00"=LDI_LO, "01"=LDI_HI)
[29:26] = write_mask   (4 bits: W Z Y X — same convention as ALU/FPU)
[25:10] = imm16        (16-bit immediate value, unchanged)
[9:8]   = reserved
[7:4]   = rd           (destination register index, unchanged)
[3:0]   = inst_type    (INST_TYPE_IMM, unchanged)
```

The internal_opcode (instruction[31:26]) seen by the ALU lane is now `sub_op[5:4] & mask[3:0]`. The ALU lane decodes only `opcode(5 downto 4)` when `is_load='1'`, ignoring the mask nibble.

**Files changed:**

- `src/processor_constants_pkg.vhd` — Updated the IMM opcode section comments to describe the new layout. `OP_LDI_HI` changed from `"000001"` to `"010000"` so that `opcode(5:4)="01"` correctly identifies LDI_HI in the ALU lane. `OP_LDI_LO` stays `"000000"` (already correct: `opcode(5:4)="00"`).

- `src/instruction_decoder.vhd` — INST_TYPE_IMM branch: replaced `write_mask := instruction(9) & × 4` with `write_mask := instruction(29 downto 26)`. Updated header comment to show the new field layout.

- `src/alu_lane.vhd` — Inside the `if is_load = '1'` block, changed `case opcode is` (matching full 6-bit constants) to `case opcode(5 downto 4) is` (matching only the 2-bit LDI sub-op). Updated comments.

- `tools/assembler.py` — IMM encoding changed from `(op<<26)|(imm<<10)|(full_mask<<9)|(rd<<4)|TYPE_IMM` to `(op<<30)|(mask<<26)|(imm<<10)|(rd<<4)|TYPE_IMM`. The `full_mask` bit is gone; `parse_reg` already returns the correct 4-bit mask for any `.xyzw` combination.

- `src/tb_call_stack.vhd` — Updated the two hardcoded LDI instruction words:
  - `INST_LDI_CLEAR`: `x"00000214"` → `x"3C000014"` (LDI_LO v1.xyzw, 0x0000)
  - `INST_LDI_42`:    `x"00010A14"` → `x"3C010814"` (LDI_LO v1.xyzw, 0x0042)

- `src/program.hex` — Regenerated from `test10_call_stack.s` with the new assembler.

- `programming_manual.md` — Removed the 1-bit full_mask limitation notes and the "TODO: fix this / Gotcha" warning. Updated the write-mask section and the SIMT section.

**Side effect (bug fix):** Tests that used `LDI_LO vN.w, 0x00FF` to set the alpha channel (test01, test02, test04, test05, test06) previously wrote nothing due to the broken `full_mask=0` encoding. They now correctly write W=255, and the generated PNG images will show proper alpha=255.
