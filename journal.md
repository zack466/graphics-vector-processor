# TODO
* fully integrate all the components into a module that can be used in platform designer, works with memory and controlled by CSR
* check sin/cos resource usage, and switch to flopoco or something else if needed
  * test if flopoco arithmetic modules use less resources (I'm ok with losing out on a bit of precision)
  * everything can be done with flopoco floating point format, should only need to convert to IEEE when outputting to framebuffer for compatibility
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling
* test memory controller with real DDR3 memory
* test all of the instructions in simulation, run programs and dump pixel outputs

# TODO (priority)
* make a robust test framework for processor instructions

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
