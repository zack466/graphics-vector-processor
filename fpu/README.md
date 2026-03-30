TODO:
* verify that all of the entity interfaces match up with the Altera floating-point IP (will just take time generating all of them on Quartus)
  * we can probably substitute in less precise but also less resource-intensive IP if needed later on
* verify that M10K blocks are inferred as desired in Quartus (vector_reg_file.vhd)
* check sin/cos resource usage, and switch to flopoco or something else if needed
* create and verify each component using testbenches
* finish integrating the memory controller, instruction fetcher, instruction issuer, instruction decoder, and the FPU lanes with the rest of the processor architecture
* stall pipeline (nop?) in between compare operations and branch instructions to ensure condition flags are all written back before testing condition
* for now, have memory stored in M10K memory
* top-level control and status register, handle 1) loading assembly into internal ROM, 2) loading pixel data into DDR3 RAM, 3) tell GPU start executing at a given PC, and 4) know when GPU is finished / if there was an error during execution
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling

## Graphics Vector Processor Design Document

### 1. Architecture Overview
The core processor operates on vector registers, with each 32-bit sub-unit referenced as a tuple (x, y, z, a). The architecture is designed to maximize parallel throughput for graphics workloads while strictly managing FPGA DSP block utilization through strategic resource sharing and algebraic optimization. It utilizes a Single Instruction, Multiple Thread (SIMT) execution model, grouping 32 threads into a single "Warp" that shares a common Program Counter (PC).

**1.1. Register File & Thread Contexts**
* **Multithreaded Allocation:** The central Register File is partitioned to support 32 concurrent hardware thread contexts (one full Warp).
* **Vector Registers:** Each thread context contains dedicated vector registers. Each vector consists of four 32-bit floating-point numbers or signed integers.
* **Predicate Registers:** Dedicated small registers (e.g., 4-bit masks) per thread to store the boolean results of vector comparisons, used to drive conditional execution.
* **True Dual-Ported Architecture:** The register file is implemented using natively dual-ported Altera M10K blocks, banked four times. Port A is dedicated to the rigidly timed FPU math pipeline, while Port B is dedicated to the Memory Controller Unit (MCU) for asynchronous memory loads/stores, preventing structural collisions.

### 2. Quad-FPU Cluster Topology
The execution stage utilizes a "Quad-FPU Cluster" approach. It features four independent FPU lanes for parallel coordinate-wise operations, supported by centralized, shared execution units for resource-heavy calculations.

**2.1. Standard FPU Lanes (4x Independent)**
Each of the four lanes operates in parallel to process the (x, y, z, a) coordinates. Each lane contains:
* **Unified Multiply-Add (MADD) Datapath:** To optimize DSP resource sharing, standard linear arithmetic is mapped to a single pipelined MADD IP core. Hardware constants are multiplexed into the operands to execute basic instructions:
    * **Addition (a + b):** Evaluated as `a * 1.0 + b`
    * **Subtraction (a - b):** Evaluated as `a * 1.0 + (-b)` (Sign bit of `b` is inverted)
    * **Multiplication (a * b):** Evaluated as `a * b + 0.0`
    * **Multiply-Add:** Natively supported as `a * b + c`
* **Dedicated Hardware Units:** Each lane also contains dedicated, pipelined logic for:
    * **Reciprocal:** Hardware division is omitted to save logic footprint. Division operations ($x / y$) are executed via a reciprocal calculation followed by a multiplication utilizing the MADD datapath.
    * Square Root, Log 2, Exp 2, Sin, Cos
    * Comparisons and Logical bounds (Min, Max, Less Than, Equal).
    * Type conversion (Fix2Float, Float2Fix).

**2.3. Cascaded Vector Reduction (Adder Tree)**
To handle cross-coordinate math (like 4-way Dot Products) without wasting dedicated DSP blocks, the reduction unit acts as a post-processing stage cascaded *after* the FPU lanes.
* When a Dot Product (`DP4`) is called, the Instruction Decoder translates it into a parallel Multiply (`FMUL`) for the standard FPU lanes.
* The multiplied results are then routed into a dedicated 2-stage floating-point adder tree to sum the coordinates.
* The final scalar result is broadcast across the writeback bus, where the register write-mask determines which vector slots are updated.

### 3. Instruction Format & Modifiers
The instruction set distinguishes between FPU math operations and Control/Memory operations via a dedicated "Type" field (e.g., bits [3:0]), radically altering how the remaining bits are decoded.

**3.1. Instruction Categories**
* **Vector Math Operations:** Parallel FPU calculations (Add, Sub, Mul) dispatches.
* **Control Flow Operations:** Modifications to the global Program Counter or SIMT Execution Stack (Jumps, Branches, Syncs).
* **Memory Operations:** Scatter/Gather operations to external RAM (Loads, Stores).

**3.2. Hardware Modifiers (Math)**
* **Input Swizzle:** A combinational crossbar routing network before the FPU inputs allows flexible rearrangement of the (x, y, z, a) coordinates.
* **Output Mask:** A write-enable bitmask that dictates which specific coordinates of the destination register are updated.

### 4. SIMT Control Flow & Divergence
Because all 32 threads in a warp share a single Program Counter, conditional logic (`if/else`) is managed via execution masking and a hardware stack rather than individual thread branching.

**4.1. The Execution Mask (EXEC)**
* A global 32-bit register where each bit represents the active status of one thread.
* If a thread evaluates a condition as `False`, its EXEC bit is cleared. The thread continues to fetch and flow through the pipeline to maintain rigid timing, but the writeback stage drops its result.

**4.2. The SIMT Hardware Stack**
* To support nested `if/else` divergence, the Instruction Fetch unit contains a physical hardware stack.
* **Divergence:** When threads diverge on a condition, the Fetch Unit pushes the "Reconvergence PC" (the address where the branches meet) and a "Deferred Mask" (the threads taking the alternate path) to the stack.
* **Reconvergence:** When the PC matches the top of the stack, the hardware automatically pops the state, updates the EXEC mask to the deferred threads, and jumps to the deferred execution block.
* Standard optimizations include `BRA_Z` (Branch if Zero) to skip entire code blocks if no threads in the warp require it.

### 5. Pipeline and Hazard Management
The processor employs a rigidly timed execution pipeline, trading logic complexity for high maximum clock frequencies ($F_{max}$).

**5.1. Barrel Scheduling (RAW Hazard Prevention)**
* The Instruction Issue stage operates a strict round-robin scheduler across the 32 threads. 
* It issues exactly one instruction from the shared PC to a different thread every clock cycle.
* Because the 32-thread loop is inherently longer than the maximum FPU latency (e.g., 24 cycles), Read-After-Write (RAW) data hazards are physically impossible. 

**5.2. Latency Padding (Writeback Hazard Prevention)**
* To prevent Structural Writeback Hazards (fast instructions finishing at the same time as older, slower instructions), the pipeline is rigidly padded.
* Shift-register delay lines ensure all instructions take the exact same number of clock cycles to reach the Register File write port, guaranteeing in-order completion without a complex scoreboard.

### 6. Memory Subsystem
The processor accesses external DDR3 memory (via an Avalon-MM master interface) using a multi-cycle, coalescing memory controller.

**6.1. Gather / Scatter Addressing**
* Each thread generates a unique 32-bit memory address using a standard `Base Address + Thread-Specific Offset` calculation. This natively supports individual pixel or vertex manipulation.

**6.2. Pipeline Stalling & Context**
* Because external memory has variable latency, memory operations break the rigid pipeline timing.
* When a `LOAD` or `STORE` is decoded, the Memory Controller Unit (MCU) asserts a global `mem_stall` signal, freezing the PC and Barrel Scheduler while it processes the 32 memory requests. Math instructions already in the FPU pipeline continue safely to completion.

**6.3. Sequential Coalescing**
* To prevent severe performance degradation from 32 individual random memory accesses, the MCU evaluates the generated addresses.
* If consecutive threads request contiguous memory blocks, the MCU bundles them into highly efficient, multi-word burst transactions on the Avalon bus. Divergent addresses are automatically broken into separate, smaller bursts.
* Loaded data is routed asynchronously into the FPU's Register File via the dedicated Port B.
