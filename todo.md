# Project Refactoring Plan

### Change 1: Simplify the Memory Controller (Block-Transfer & Pixel Packing)
**Objective**: Replace the complex scatter-gather coalescing state machine with a streamlined memory controller (`mcu_block_transfer.vhd`) that only does sequential memory bursts and packs integer data into 32-bit RGBA pixels.

**Implementation Steps**:
1. **Deprecate the Scatter/Gather MCU**: Remove `mcu_scatter_gather.vhd`.
2. **Instruction Set & Addressing**: Modify `OP_STORE` to act as a block store. Instead of loading an address per thread from the VRF, the instruction will provide a single `base_address` (either via a scalar register or CSR).
3. **Data Packing Logic**: 
   - When the core issues a memory store, the new MCU reads 32 128-bit tuples from the VRF over 32 cycles.
   - We assume the shader program uses the existing FPU `FLOAT2FIX` instruction to clamp and convert the floating-point RGBA values into 32-bit integers (0–255) prior to the store.
   - The MCU simply extracts the bottom 8 bits of the X, Y, Z, and W components from the VRF data and concatenates them: `packed_pixel = W[7:0] & Z[7:0] & Y[7:0] & X[7:0]`.
4. **Avalon Bus Bursting**:
   - Because the Avalon bus is 128 bits wide, the MCU will accumulate 4 packed pixels (32 bits each) into a single 128-bit Avalon word.
   - To store the entire warp (32 pixels), the MCU pushes exactly **8 sequential 128-bit write beats** to the Avalon bridge as fast as the bus allows.
5. **Testability**: Create a testbench `tb_mcu_block_transfer.vhd`. Inject mock 128-bit VRF vectors (populated with known integers) and verify that the Avalon master port outputs exactly 8 sequential write beats with the bytes correctly packed.

---

### Change 2: The Global Frame Dispatcher (Macro-Scheduler)
**Objective**: Build a top-level hardware module that sits *outside* the processor core and automatically feeds warp offset values to it, allowing a single frame to be computed unattended.

**Implementation Steps**:
1. **Create `frame_dispatcher.vhd`**: This will wrap the main `processor.vhd` or sit adjacent to it.
2. **Interface**: Add inputs for `frame_width`, `frame_height`, and a `start` signal.
3. **State Machine**:
   - **IDLE**: Wait for the host to assert `start`.
   - **DISPATCH**: Write the `current_pixel_index` to the core's `csr_warp_offset` register, then assert `csr_run`.
   - **WAIT**: Monitor the core's `halted` or `break_hit` signal. Wait until the warp finishes executing.
   - **INCREMENT**: Add 32 (the `WARP_SIZE`) to `current_pixel_index`. If `current_pixel_index < total_pixels`, loop back to **DISPATCH**. Otherwise, return to **IDLE**.
4. **Testability**: Write a testbench simulating a dummy processor core that asserts `break_hit` a few clock cycles after `csr_run` goes high. Assert that the dispatcher correctly iterates through offset values `0, 32, 64, 96...` until it reaches the end of the frame.

---

### Change 3: Fine-Grained Hardware Multithreading (In-Core Warp Scheduling)
**Objective**: Expand the processor core to support concurrent execution of 2–4 physical warps to hide pipeline and memory latency. This seamlessly integrates with the previous two changes.

**Implementation Steps**:
1. **Expand Register Files**: 
   - Increase `VRF_ADDR_WIDTH` from 9 bits to 11 bits (assuming 4 warps). 
   - The VRF will now hold 4 warps × 32 threads × 16 registers = 2048 entries.
   - Expand the PRF accordingly.
2. **Replicate IFU State**: 
   - Inside `instruction_fetch_unit.vhd`, duplicate the Program Counter, Execution Mask, and SIMT Divergence Stack into arrays of size 4 (one for each physical warp).
3. **Pipeline Tagging**: 
   - Add a 2-bit `warp_id` tag to the pipeline control records (`latched_ctrl` in `instruction_issue.vhd`). The execution unit and writeback controllers will use this tag to generate the 11-bit global writeback address.
4. **Core FSM Modification (Round-Robin Scheduler)**:
   - In `processor.vhd`, change the FSM to track the state of each warp (e.g., `READY`, `WAIT_MEM`, `WAIT_EXEC`).
   - If Warp 0 issues a block memory store (from Change 1), the FSM transitions Warp 0 to `WAIT_MEM`. 
   - On the very next cycle, the FSM context-switches and begins fetching instructions for Warp 1. 
   - Once the memory controller drops `mem_stall(warp_id)`, the FSM marks Warp 0 as `READY` again.
5. **Update CSRs for Multithreading**:
   - Replace the single `csr_warp_offset` with an array of 4 offset registers. The Frame Dispatcher (from Change 2) will act as the "OS", pushing logical work blocks into any hardware warp that is currently idle.
6. **Testability**: Write an integration test where Warp 0 encounters an `OP_STORE` (triggering a multi-cycle memory stall). Verify via waveform that Warp 1 immediately starts fetching, issuing, and executing arithmetic instructions while the memory unit is busy handling Warp 0's data.