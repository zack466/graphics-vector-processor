# Graphics Vector Processor Design Document

## 1. Architecture Overview
The core processor operates on vector registers, with each 32-bit sub-unit referenced as a tuple (x, y, z, w). The architecture is designed to maximize parallel throughput for graphics workloads while strictly managing FPGA logic resources. It utilizes a Single Instruction, Multiple Thread (SIMT) execution model, grouping 32 threads into a single "Warp" that shares a common Program Counter (PC).

**1.0. Top-Level Hierarchy**
The top-level entity is `frame_processor`, a structural entity (no datapath logic) that wires together:
* **`warp_scheduler`** — frame-level FSM that iterates `warp_offset` from 0 to `frame_width × frame_height − 1` in steps of 32, dispatching one warp block at a time.
* **`warp_unit`** — self-contained SIMT warp: IFU, decode, issue, FPU/ALU/RED execution, VRF, PRF, and pixel snoop buffer. Accepts `warp_start`/`warp_offset`; exposes `pixel_buf_valid`, `pixel_buf_data` (1024-bit flat buffer of 32 packed RGBA pixels), and `warp_halted`.
* **`mcu_block_transfer`** — accepts the warp's 1024-bit pixel buffer and emits 8 sequential 128-bit Avalon burst beats to DDR3.
* **`avm_burst_bridge`** — thin Avalon-MM master protocol layer between the MCU and the DDR3 controller.
* **`instruction_memory`** — shared M10K BRAM; all warps execute the same shader program.

The host drives `frame_start` (1-cycle pulse), `frame_width`, and `frame_height` and waits for `frame_done`. There is no per-warp CSR interface.

**1.1. Register File & Thread Contexts**
* **Multithreaded Vector Register File (VRF):** Partitioned to support 32 concurrent hardware thread contexts. Implemented using natively dual-ported Altera M10K blocks. Port A is dedicated to the math pipeline, while Port B is for the Memory Controller (MCU). The VRF holds untyped 32-bit generic words, allowing it to natively store and seamlessly pass both IEEE-754 floating-point values and 32-bit two's-complement integers.
* **Predicate Register File (PRF):** A dedicated, high-speed register file storing 4 bits per thread (one per component). These store the results of comparisons and drive conditional branching.
* **Instruction Memory (IMEM):** Internal synchronous M10K-based storage for up to 256 instructions. This ensures deterministic 1-cycle fetch latency, decoupling program execution from the variable latency of DDR3 memory.

## 2. Host Interface & Control
The processor operates as an accelerator co-processor, managed by an external host (e.g., an ARM HPS) via the Avalon Memory-Mapped (Avalon-MM) bus.

**2.1. IMEM Programming Interface**
The Instruction Memory features a dedicated write port (`prog_we`, `prog_wr_addr`, `prog_wr_data`) allowing the host processor to backdoor-load assembled machine code directly into the GPU's IMEM before execution begins.

**2.2. Frame Control Interface**
`frame_processor` replaces the old per-warp CSR slave interface with a simple frame-level handshake:
* **`frame_start`** — 1-cycle pulse from host to begin rendering. The warp_scheduler latches `frame_width × frame_height` and starts dispatching warp blocks.
* **`frame_width` / `frame_height`** — pixel dimensions of the output frame (16-bit unsigned each). Must be stable before and during `frame_start`.
* **`frame_done`** — 1-cycle pulse emitted by warp_scheduler after the last warp halts. The host can use this to signal a framebuffer flip.

There is no longer a per-warp CSR register for `warp_offset` or a `RUN` bit; warp dispatch is fully autonomous once `frame_start` is received.

## 3. Execution Datapath & Compute Clusters
The execution stage utilizes a parallel, multi-path topology for standard floating-point math, exact integer arithmetic, and cross-coordinate reductions.

**3.1. Standard FPU Lanes (4x Independent)**
Each lane contains a Unified Multiply-Add (MADD) datapath and transcendental units.
* **Predicate Logic ALU & Swizzling:** Integrated directly into the FPU lanes to allow bitwise operations (`PAND`, `POR`, `PXOR`) on predicate masks. A pre-swizzle multiplexer injects PRF data into the datapath *before* the swizzle network, natively supporting cross-lane boolean operations (e.g., `POR p2, p0.xxxx, p1.yyyy`).
* **Comparison Modifiers:** Native support for `Swap Operands` and `Invert Result` on comparison instructions. This allows the hardware to evaluate all six algebraic relations (=, ≠, <, ≤, >, ≥) using only `Equal` and `Less Than` hardware cores.

**3.2. Dedicated Integer ALU Lane**
A lightweight, single-lane integer Arithmetic Logic Unit (ALU) operates concurrently with the floating-point cores.
* **Exact Mathematics:** Provides robust 32-bit two's-complement arithmetic (`IADD`, `ISUB`, shifts, and bitwise logic) essential for exact memory address calculation, loop counting, and pointer offset math.
* **Pipeline Synchronization:** While integer math evaluates combinationally in zero cycles, the hardware injects the result into a 28-stage shift register. This synchronizes the ALU output perfectly with the unified Writeback Controller.

**3.3. Parallel Vector Reduction Unit**
A dedicated 16-cycle Altera floating-point 4D scalar product block handles cross-coordinate math (Dot Products, Squared Magnitudes, Sums). By aggressively optimizing this datapath down to 16 cycles, it is no longer the pipeline's latency bottleneck. The maximum execution latency of the entire processor is now safely bounded at 28 cycles (dictated by the FPU lanes). Dynamic input masking allows the unit to switch between 3D and 4D operations without latency penalties.

## 4. Instruction Format & Modifiers
The ISA uses a 32-bit word where the bottom 4 bits (`Type`) determine the decoding scheme (`FPU`, `CTRL`, `RED`, `ALU`, `IMM`, `MEM`, `SYS`). Decoded instructions are flattened into a unified execution control record (`exec_ctrl_t`) to pass cleanly through the issue stage regardless of the target execution lane.

**4.1. Hardware Modifiers (Logic & Math)**
* **Dual-Port Swizzle:** Combinational crossbar routing for operands. To reduce FPGA routing pressure, this currently supports passthrough (`.xyzw`) and scalar broadcasting/splatting (`.xxxx`, `.yyyy`, `.zzzz`, `.wwww`). Arbitrary cross-component swizzling has been removed but could be added later via a dedicated instruction.
* **Predicate Modifiers (Collapse):** When evaluating a branch, the hardware collapses the 4-bit predicate vector into a 1-bit decision using four modes:
    * **ANY:** True if any component is 1.
    * **ALL:** True if all components are 1.
    * **X_ONLY / A_ONLY:** True based on a single specific component (e.g., Alpha Test).

**4.2. System Instructions (INST_TYPE_SYS)**
System instructions (`FLUSH`, `RETURN`) are completely decoupled from the branch evaluator (`INST_TYPE_CTRL`). This cleanly separates pipeline state management from Program Counter mathematics, keeping the Control Branch Type mux optimized at 4 bits.

## 5. SIMT Control Flow & Divergence
Conditional logic is managed via execution masking and a hardware stack to handle "Warp Divergence."

**5.1. The 2-Phase Reconvergence Model**
The processor utilizes a structured reconvergence model to handle `if/else` blocks:
* **`SSY` (Set Sync):** Marks the future PC where threads will reunite.
* **`BRA_DIV` (Divergent Branch):** If threads disagree on a condition, the hardware pushes the "False" path to the stack and jumps to the "True" path.
* **`SYNC` (Synchronize):** A two-phase instruction.
    * **Phase 1 (Swap):** At the end of the `IF` block, `SYNC` toggles execution to the deferred threads waiting on the stack.
    * **Phase 2 (Pop):** At the end of the `ELSE` block, `SYNC` pops the stack and jumps to the `SSY` meetup point.

**5.2. Warp Optimizations**
`BRA_Z` and `BRA_NZ` allow the PC to jump over entire blocks of code if the warp is "unanimous," bypassing the stack entirely to save cycles.

## 6. Pipeline and Hazard Management
The processor heavily utilizes structural decoupling and explicit multi-cycle FSM states to prevent phase-shift bugs and Read-After-Write (RAW) hazards.

**6.1. Top-Level State Machine (Two-Process Methodology)**
To ensure the Instruction Fetch Unit (IFU) stall pins perfectly track the state machine without 1-cycle latency shifts, the FSM uses a Two-Process model:
* A synchronous process registers the current state.
* A combinational process instantaneously calculates the next state and drives control flags (`ifu_stall`, `mem_op_valid`, `iss_valid_in`).

**6.2. Token-Based Pipeline Flushing**
Rather than forcing the IFU to manually track delays or inserting thousands of NOPs into IMEM, the architecture uses a hardware `FLUSH` token:
1. The IFU decodes an `OP_FLUSH` (`INST_TYPE_SYS`) and commands the issuer to inject exactly one flush token into the pipeline.
2. The Execution Unit tracks this token down a 28-bit shift register.
3. The IFU stalls in the `EXEC_WAIT` state until `exec_flush_active` drops to `0`.
*Note: To prevent VHDL 32-bit integer overflow limits from evaluating to 'X' states, the 28-bit tracker is safely compared against a `ZERO_FLUSH_REG` constant.*

**6.3. Read-After-Write (RAW) Hazard Resolution**
By bounding the maximum pipeline latency to 28 cycles, the architecture intrinsically resolves intra-thread RAW hazards:
* **Math RAW Hazards (The 28 vs 32 Advantage):** Because the maximum pipeline latency (28 cycles) is strictly less than the warp size (32 threads), a thread's math result is guaranteed to be fully written back to the VRF *before* that same thread is issued its next instruction. This completely eliminates the need for complex data forwarding or stall logic for sequential math operations.
* **Control / Immediate RAW Hazards:** Loading immediate halves (`LDI_LO`, `LDI_HI`) or comparing values before branching still requires the compiler to either insert independent instructions or issue an explicit `FLUSH` to clear the 28-cycle pipe before evaluating the branch condition.

**6.4. The Writeback Controller & Latency Padding**
* All math operations are stretched via shift-register delay lines to exactly 28 cycles to prevent structural writeback hazards.
* **Non-Stalling Backend:** If the Instruction Fetcher stalls, the Writeback Controller continues ticking, automatically shifting `NOPs` (Write Enable = 0) into the pipe. This allows the up to 28 instructions already "in-flight" to safely complete and write to the register files without colliding.

## 7. Memory Subsystem
The processor writes pixels to external DDR3 memory using a sequential block-transfer architecture. The old scatter/gather MCU (which scanned 32 thread addresses independently) has been replaced by a snoop-based design that is simpler and better suited to framebuffer output.

**7.1. Pixel Snoop Buffer (inside warp_unit)**
As the barrel scheduler issues a `STORE` instruction over 32 cycles (one thread per cycle), `execution_unit` snoops the VRF read data at Stage 1 and provides three outputs: `mem_store_valid`, `mem_store_data` (4 × 32-bit XYZW components), and `mem_store_thread_id`. The warp_unit uses these to fill a 32-entry × 32-bit `pixel_snoop` buffer. Each entry packs the lower 8 bits of all four components into a single 32-bit RGBA word:
```
pixel_snoop[t] = W[7:0] & Z[7:0] & Y[7:0] & X[7:0]
```
The full 1024-bit buffer is exposed as `pixel_buf_data` on the warp_unit port boundary.

**7.2. mcu_block_transfer**
Accepts the warp's `pixel_buf_valid` pulse, `pixel_buf_addr`, `pixel_buf_data`, and `pixel_exec_mask`. Latches the buffer and emits exactly 8 sequential 128-bit Avalon write beats (beat k carries threads 4k+3..4k+0, MSB to LSB). `mem_stall` is held high until all 8 beats have been acknowledged, keeping the warp FSM in `MEM_WAIT`.

**7.3. avm_burst_bridge**
Thin Avalon-MM master driver. Holds the base address constant for all 8 beats of the burst (the DDR3 controller auto-increments the address internally). Handles `waitrequest` by pausing without losing beat data.

**7.4. Address Calculation**
The physical DDR3 byte address for a warp block is:
```
phys_addr = (STORE.base_addr << 16) + warp_offset * 4
```
`warp_offset` is the pixel index of thread 0 within the warp, supplied by `warp_scheduler`. Multiplying by 4 converts from pixel index to byte address (4 bytes per 32-bit RGBA pixel). Each warp's 32-pixel block therefore occupies 128 consecutive bytes in DDR3.

**7.5. Sequential Memory Ordering**
`LOAD` and `STORE` both block the warp FSM in `MEM_WAIT` until the full burst completes, enforcing strict sequential memory ordering. There is no out-of-order or overlapping memory access.
