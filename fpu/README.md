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

# Agent Instructions: Graphics Vector Processing Unit

Welcome! This document contains context and guidelines for autonomous agents working on this repository.

## Project Overview
This project is vector-based graphics processor in VHDL, intended to run on a Intel Cyclone V SE 5CSEBA6U23I7 device (110K LEs, 112 DSP blocks, 557 M10K blocks).
The processor acts on 128-bit tuples (x, y, z, a) of standard IEEE 32-bit floating-point numbers.

## Technical Stack & Architecture
- **Simulation:** Uses `GHDL` for all testbenching and simulation.
- **Synthesis:** Will `Quartus` for synthesis. Quartus project files are in a separate repository.
- **Waveform Viewer:** Uses `gtkwave` to view waveforms.

## VHDL Style
When writing designs/testbenches in VHDL, always abide by these guideleines:
- Use VHDL-2008 constructs to make testbench code easier to read/write. Using VHDL-1993 constructs in designs is preferred for compatibility.
- Always obey strict synchronous design principles. Testbench code should synchronize itself using `wait until rising_edge(clk)` and should never have arbitrary waits like `wait until 1 ns`.
- Always add brief, informative comments for each declared input/output/signal. Also add comments for all processes or statements that do something non-obvious.
- Otherwise, try to follow the style of the existing code for naming and general style

# Graphics Vector Processor Design Document

## 1. Architecture Overview
The core processor operates on vector registers, with each 32-bit sub-unit referenced as a tuple (x, y, z, a). The architecture is designed to maximize parallel throughput for graphics workloads while strictly managing FPGA logic resources. It utilizes a Single Instruction, Multiple Thread (SIMT) execution model, grouping 32 threads into a single "Warp" that shares a common Program Counter (PC).

**1.1. Register File & Thread Contexts**
* **Multithreaded Vector Register File (VRF):** Partitioned to support 32 concurrent hardware thread contexts. Implemented using natively dual-ported Altera M10K blocks. Port A is dedicated to the math pipeline, while Port B is for the Memory Controller (MCU). The VRF holds untyped 32-bit generic words, allowing it to natively store and seamlessly pass both IEEE-754 floating-point values and 32-bit two's-complement integers.
* **Predicate Register File (PRF):** A dedicated, high-speed register file storing 4 bits per thread (one per component). These store the results of comparisons and drive conditional branching.
* **Instruction Memory (IMEM):** Internal synchronous M10K-based storage for up to 256 instructions. This ensures deterministic 1-cycle fetch latency, decoupling program execution from the variable latency of DDR3 memory.

## 2. Execution Datapath & Compute Clusters
The execution stage utilizes a parallel, multi-path topology for standard floating-point math, exact integer arithmetic, and cross-coordinate reductions.

**2.1. Standard FPU Lanes (4x Independent)**
Each lane contains a Unified Multiply-Add (MADD) datapath and transcendental units.
* **Predicate Logic ALU & Swizzling:** Integrated directly into the FPU lanes to allow bitwise operations (`PAND`, `POR`, `PXOR`) on predicate masks. A pre-swizzle multiplexer injects PRF data into the datapath *before* the swizzle network, natively supporting cross-lane boolean operations (e.g., `POR p2, p0.xxxx, p1.yyyy`).
* **Comparison Modifiers:** Native support for `Swap Operands` and `Invert Result` on comparison instructions. This allows the hardware to evaluate all six algebraic relations (=, ≠, <, ≤, >, ≥) using only `Equal` and `Less Than` hardware cores.

**2.2. Dedicated Integer ALU Lane**
A lightweight, single-lane integer Arithmetic Logic Unit (ALU) operates in parallel with the floating-point cores.
* **Exact Mathematics:** Provides robust 32-bit two's-complement arithmetic (`IADD`, `ISUB`, shifts, and bitwise logic) essential for exact memory address calculation, loop counting, and pointer offset math.
* **Pipeline Synchronization:** While integer math evaluates combinationally in zero cycles, the hardware injects the result into a 37-stage shift register. This synchronizes the ALU output perfectly with the `FPU_MAX_LATENCY`, allowing it to share the unified Writeback Controller seamlessly.

**2.3. Parallel Vector Reduction Unit**
A dedicated 37-cycle Altera floating-point 4D scalar product block handles cross-coordinate math (Dot Products, Squared Magnitudes, Sums). Dynamic input masking allows the unit to switch between 3D and 4D operations without latency penalties.

## 3. Instruction Format & Modifiers
The ISA uses a 32-bit word where the bottom 4 bits (`Type`) determine the decoding scheme (`FPU`, `ALU`, `RED`, `CTRL`). Decoded instructions are flattened into a unified execution control record (`exec_ctrl_t`) to pass cleanly through the issue stage regardless of the target execution lane.

**3.1. Hardware Modifiers (Logic & Math)**
* **Dual-Port Swizzle:** Combinational crossbar routing for operands. Supports component rearrangement (e.g., `.xxxx`, `.zyxw`).
* **Predicate Modifiers (Collapse):** When evaluating a branch, the hardware collapses the 4-bit predicate vector into a 1-bit decision using four modes:
    * **ANY:** True if any component is 1.
    * **ALL:** True if all components are 1.
    * **X_ONLY / A_ONLY:** True based on a single specific component (e.g., Alpha Test).

## 4. SIMT Control Flow & Divergence
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

## 5. Pipeline and Hazard Management
The processor trades logic complexity for high maximum clock frequencies (F_max) through a rigid timing model, heavily decoupled into distinct stages to prevent phase-shift bugs.

**5.1. Barrel Scheduling & RAW Hazards**
* The Instruction Issue stage operates a round-robin scheduler across the 32 threads.
* **Math RAW Hazards:** Inherently avoided for vector math because the 32-cycle loop is shorter than the 37-cycle pipe, meaning a thread's result is almost ready before it executes again.
* **Control RAW Hazards (Software Delay Slot):** Because comparison results take 37 cycles to reach the PRF, a branch cannot immediately follow a comparison for the same thread. The compiler must insert one unrelated instruction (or a `NOP`) between a `FCMP` and a dependent `BRA`.

**5.2. The Writeback Controller & Latency Padding**
* All math operations are stretched via shift-register delay lines to exactly 37 cycles to prevent structural writeback hazards.
* **Dedicated Module:** The massive 37-cycle delay line for all control signals (Destination Address, Write Mask, Write Enables, Mux Selects for FPU/ALU/RED) is abstracted into a dedicated `Writeback Controller` module. This keeps top-level routing clean and synthesizes efficiently into shift-register LUTs (SRLs).
* **Non-Stalling Backend:** If the Instruction Fetcher stalls, the Writeback Controller continues ticking, automatically shifting `NOPs` (Write Enable = 0) into the pipe. This allows the up to 37 instructions already "in-flight" to safely complete and write to the register files without colliding.

**5.3. Synchronous/Asynchronous Pipeline Alignment**
* Strict pipeline isolation registers separate Stage 0 (Issue) from Stage 1 (Read).
* Because the Vector Register File (M10K) has a 1-cycle synchronous read latency and the Predicate Register File has a 0-cycle asynchronous read latency, the hardware explicitly latches the PRF output. This aligns the data and prevents "Phase Shift" bugs where combinational logic accidentally evaluates PRF data for the *next* thread's address.

## 6. Memory Subsystem
Accesses external DDR3 memory using a multi-cycle, coalescing memory controller.

**6.1. Sequential Coalescing**
The MCU evaluates the 32 unique addresses generated by the warp. If addresses are contiguous, they are bundled into high-efficiency burst transactions on the Avalon-MM bus. Non-contiguous "Scatter/Gather" requests are automatically serialized into smaller bursts.

**6.2. Address Generation**
Threads compute their own memory addresses using the dedicated integer ALU, completely bypassing the float-to-int precision traps inherent in graphics workloads exceeding 24 bits of address space. These computed addresses are stored in a standard vector register and consumed by the MCU for Scatter/Gather operations.
