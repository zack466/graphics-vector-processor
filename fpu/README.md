TODO:
* verify that all of the entity interfaces match up with the Altera floating-point IP (will just take time generating all of them on Quartus)
  * we can probably substitute in less precise but also less resource-intensive IP if needed later on
* verify that M10K blocks are inferred as desired in Quartus (vector_reg_file.vhd)
* check sin/cos resource usage, and switch to flopoco or something else if needed
* create and verify each component using testbenches
* finish integrating the memory controller, instruction fetcher, instruction issuer, instruction decoder, and the FPU lanes with the rest of the processor architecture
* top-level control and status register, handle 1) loading assembly into internal ROM, 2) loading pixel data into DDR3 RAM, 3) tell GPU start executing at a given PC, and 4) know when GPU is finished / if there was an error during execution
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling
* finish memory controller, test with real DDR3 memory as well
* update full execution integration test to include predicate / logic operations

This design document has been updated to reflect the critical advancements we've made in instruction storage, predicate logic, and enhanced SIMT control flow.

## Graphics Vector Processor Design Document

### 1. Architecture Overview
The core processor operates on vector registers, with each 32-bit sub-unit referenced as a tuple (x, y, z, a). The architecture is designed to maximize parallel throughput for graphics workloads while strictly managing FPGA logic resources. It utilizes a Single Instruction, Multiple Thread (SIMT) execution model, grouping 32 threads into a single "Warp" that shares a common Program Counter (PC).

**1.1. Register File & Thread Contexts**
* **Multithreaded Vector Register File (VRF):** Partitioned to support 32 concurrent hardware thread contexts. Implemented using natively dual-ported Altera M10K blocks. Port A is dedicated to the math pipeline, while Port B is for the Memory Controller (MCU).
* **Predicate Register File (PRF):** A dedicated, high-speed register file storing 4 bits per thread (one per component). These store the results of comparisons and drive conditional branching.
* **Instruction Memory (IMEM):** Internal synchronous M10K-based storage for up to 256 instructions. This ensures deterministic 1-cycle fetch latency, decoupling program execution from the variable latency of DDR3 memory.

### 2. Execution Datapath & Quad-FPU Cluster
The execution stage utilizes a parallel, dual-path topology for standard math and cross-coordinate reductions.

**2.1. Standard FPU Lanes (4x Independent)**
Each lane contains a Unified Multiply-Add (MADD) datapath and transcendental units.
* **Predicate Logic ALU:** Integrated directly into the FPU lanes to allow bitwise operations (`PAND`, `POR`, `PXOR`) on predicate masks. This allows complex boolean trees (e.g., `if (A && B)`) to be calculated in the math pipeline rather than the branch unit.
* **Comparison Modifiers:** Native support for `Swap Operands` and `Invert Result` on comparison instructions. This allows the hardware to evaluate all six algebraic relations ($=, \neq, <, \leq, >, \geq$) using only `Equal` and `Less Than` hardware cores.

**2.2. Parallel Vector Reduction Unit**
A dedicated 37-cycle Altera floating-point 4D scalar product block handles cross-coordinate math (Dot Products, Squared Magnitudes, Sums). Dynamic input masking allows the unit to switch between 3D and 4D operations without latency penalties.

### 3. Instruction Format & Modifiers
The ISA uses a 32-bit word where the bottom 4 bits (`Type`) determine the decoding scheme for the remaining 28 bits.

**3.1. Hardware Modifiers (Logic & Math)**
* **Dual-Port Swizzle:** Combinational crossbar routing for operands. Supports component rearrangement (e.g., `.xxxx`, `.zyxw`).
* **Predicate Modifiers (Collapse):** When evaluating a branch, the hardware collapses the 4-bit predicate vector into a 1-bit decision using four modes:
    * **ANY:** True if any component is 1.
    * **ALL:** True if all components are 1.
    * **X_ONLY / A_ONLY:** True based on a single specific component (e.g., Alpha Test).

### 4. SIMT Control Flow & Divergence
Conditional logic is managed via execution masking and a hardware stack to handle "Warp Divergence."

**4.1. The 2-Phase Reconvergence Model**
The processor utilizes a structured reconvergence model to handle `if/else` blocks:
* **`SSY` (Set Sync):** Marks the future PC where threads will reunite.
* **`BRA_DIV` (Divergent Branch):** If threads disagree on a condition, the hardware pushes the "False" path to the stack and jumps to the "True" path.
* **`SYNC` (Synchronize):** A two-phase instruction.
    * **Phase 1 (Swap):** At the end of the `IF` block, `SYNC` toggles execution to the deferred threads waiting on the stack.
    * **Phase 2 (Pop):** At the end of the `ELSE` block, `SYNC` pops the stack and jumps to the `SSY` meetup point.

**4.2. Warp Optimizations**
`BRA_Z` and `BRA_NZ` allow the PC to jump over entire blocks of code if the warp is "unanimous," bypassing the stack entirely to save cycles.

### 5. Pipeline and Hazard Management
The processor trades logic complexity for high maximum clock frequencies ($F_{max}$) through a rigid timing model.

**5.1. Barrel Scheduling & RAW Hazards**
* The Instruction Issue stage operates a round-robin scheduler across the 32 threads.
* **Math RAW Hazards:** Inherently avoided for vector math because the 32-cycle loop is shorter than the 37-cycle pipe, meaning a thread's result is almost ready before it executes again.
* **Control RAW Hazards (Software Delay Slot):** Because comparison results take 37 cycles to reach the PRF, a branch cannot immediately follow a comparison for the same thread. The compiler must insert one unrelated instruction (or a `NOP`) between a `FCMP` and a dependent `BRA`.

**5.2. Latency Padding**
All math operations are stretched via shift-register delay lines to exactly 37 cycles. Logic operations (0-latency) are injected into the start of the pipeline, while math core outputs are injected as they complete, ensuring a unified, collision-free writeback stage.

### 6. Memory Subsystem
Accesses external DDR3 memory using a multi-cycle, coalescing memory controller.

**6.1. Sequential Coalescing**
The MCU evaluates the 32 unique addresses generated by the warp. If addresses are contiguous, they are bundled into high-efficiency burst transactions on the Avalon-MM bus. Non-contiguous "Scatter/Gather" requests are automatically serialized into smaller bursts.
