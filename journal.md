# TODO
* fully integrate all the components into a module that can be used in platform designer, works with memory and controlled by CSR
* check sin/cos resource usage, and switch to flopoco or something else if needed
  * test if flopoco arithmetic modules use less resources (I'm ok with losing out on a bit of precision)
  * everything can be done with flopoco floating point format, should only need to convert to IEEE when outputting to framebuffer for compatibility
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling
* test memory controller with real DDR3 memory

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

