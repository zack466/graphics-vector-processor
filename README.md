TODO:
* fully integrate all the components into a module that can be used in platform designer, works with memory and controlled by CSR
* check sin/cos resource usage, and switch to flopoco or something else if needed
  * test if flopoco arithmetic modules use less resources (I'm ok with losing out on a bit of precision)
  * everything can be done with flopoco floating point format, should only need to convert to IEEE when outputting to framebuffer for compatibility
* add immediate FPU instructions, don't support things like swizzling or mask, but allow encoding low-precision immediate constants, for things like scalar multiplication, negation, etc
  * or could just hardcode some constants in the FPU like -1, 1/2, 1/3, 1/4, pi, pi/2, pi/3, pi/4, etc and use for scaling
* test memory controller with real DDR3 memory
* improve routing congestion, either pipeline the swizzle network, decrease its capabilities, or remove it altogether
  * (fixed) modified vector registers to use M10K blocks, improved ALM util and reduced congestion by a ton
  * also, scatter gather mcu using about 3000 ALMs, seems like a lot more than should be necessary
    * fixed as well?
* test all of the instructions in simulation, run programs and dump pixel outputs
* add warp offset to CSR, route into execution unit, and add ALU instruction to write it to a register

# Graphics Vector Processor Design Document

## 1. Architecture Overview
The core processor operates on vector registers, with each 32-bit sub-unit referenced as a tuple (x, y, z, w). The architecture is designed to maximize parallel throughput for graphics workloads while strictly managing FPGA logic resources. It utilizes a Single Instruction, Multiple Thread (SIMT) execution model, grouping 32 threads into a single "Warp" that shares a common Program Counter (PC).

**1.1. Register File & Thread Contexts**
* **Multithreaded Vector Register File (VRF):** Partitioned to support 32 concurrent hardware thread contexts. Implemented using natively dual-ported Altera M10K blocks. Port A is dedicated to the math pipeline, while Port B is for the Memory Controller (MCU). The VRF holds untyped 32-bit generic words, allowing it to natively store and seamlessly pass both IEEE-754 floating-point values and 32-bit two's-complement integers.
* **Predicate Register File (PRF):** A dedicated, high-speed register file storing 4 bits per thread (one per component). These store the results of comparisons and drive conditional branching.
* **Instruction Memory (IMEM):** Internal synchronous M10K-based storage for up to 256 instructions. This ensures deterministic 1-cycle fetch latency, decoupling program execution from the variable latency of DDR3 memory.

## 2. Host Interface & Control
The processor operates as an accelerator co-processor, managed by an external host (e.g., an ARM HPS) via the Avalon Memory-Mapped (Avalon-MM) bus.

**2.1. IMEM Programming Interface**
The Instruction Memory features a dedicated write port (`prog_we`, `prog_wr_addr`, `prog_wr_data`) allowing the host processor to backdoor-load assembled machine code directly into the GPU's ROM before execution.

**2.2. Control Status Registers (CSR)**
An Avalon-MM Slave interface exposes critical execution controls to the host:
* **CSR[0] - Run Register:** Writing `1` unstalls the IFU and begins program execution. Writing `0` halts the processor. The processor can also clear this bit internally via a `RETURN` instruction to automatically signal completion to the host.
* **CSR[1] - Start PC Override:** Allows the host to force the processor to boot from a specific instruction address by injecting a combinational `BR_JMP` into the fetch unit.

## 3. Execution Datapath & Compute Clusters
The execution stage utilizes a parallel, multi-path topology for standard floating-point math, exact integer arithmetic, and cross-coordinate reductions.

**3.1. Standard FPU Lanes (4x Independent)**
Each lane contains a Unified Multiply-Add (MADD) datapath and transcendental units.
* **Predicate Logic ALU & Swizzling:** Integrated directly into the FPU lanes to allow bitwise operations (`PAND`, `POR`, `PXOR`) on predicate masks. A pre-swizzle multiplexer injects PRF data into the datapath *before* the swizzle network, natively supporting cross-lane boolean operations (e.g., `POR p2, p0.xxxx, p1.yyyy`).
* **Comparison Modifiers:** Native support for `Swap Operands` and `Invert Result` on comparison instructions. This allows the hardware to evaluate all six algebraic relations (=, ≠, <, ≤, >, ≥) using only `Equal` and `Less Than` hardware cores.

**3.2. Dedicated Integer ALU Lane**
A lightweight, single-lane integer Arithmetic Logic Unit (ALU) operates concurrently with the floating-point cores.
* **Exact Mathematics:** Provides robust 32-bit two's-complement arithmetic (`IADD`, `ISUB`, shifts, and bitwise logic) essential for exact memory address calculation, loop counting, and pointer offset math.
* **Pipeline Synchronization:** While integer math evaluates combinationally in zero cycles, the hardware injects the result into a 37-stage shift register. This synchronizes the ALU output perfectly with the `FPU_MAX_LATENCY`, allowing it to share the unified Writeback Controller seamlessly.

**3.3. Parallel Vector Reduction Unit**
A dedicated 37-cycle Altera floating-point 4D scalar product block handles cross-coordinate math (Dot Products, Squared Magnitudes, Sums). Dynamic input masking allows the unit to switch between 3D and 4D operations without latency penalties.

## 4. Instruction Format & Modifiers
The ISA uses a 32-bit word where the bottom 4 bits (`Type`) determine the decoding scheme (`FPU`, `CTRL`, `RED`, `ALU`, `IMM`, `MEM`, `SYS`). Decoded instructions are flattened into a unified execution control record (`exec_ctrl_t`) to pass cleanly through the issue stage regardless of the target execution lane.

**4.1. Hardware Modifiers (Logic & Math)**
* **Dual-Port Swizzle:** Combinational crossbar routing for operands. Supports component rearrangement (e.g., `.xxxx`, `.zyxw`).
* **Predicate Modifiers (Collapse):** When evaluating a branch, the hardware collapses the 4-bit predicate vector into a 1-bit decision using four modes:
    * **ANY:** True if any component is 1.
    * **ALL:** True if all components are 1.
    * **X_ONLY / A_ONLY:** True based on a single specific component (e.g., Alpha Test).

**4.2. System Instructions (INST_TYPE_SYS)**
System instructions (`FLUSH`, `RETURN`) are completely decoupled from the branch evaluator (`INST_TYPE_CTRL`). This cleanly separates pipeline state management from Program Counter mathematics, keeping the Control Branch Type mux optimized at 3 bits (000-110).

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
Rather than forcing the IFU to manually track 37-cycle delays or inserting thousands of NOPs into IMEM, the architecture uses a hardware `FLUSH` token:
1. The IFU decodes an `OP_FLUSH` (`INST_TYPE_SYS`) and commands the issuer to inject exactly one flush token into the pipeline.
2. The Execution Unit tracks this token down a 37-bit shift register.
3. The IFU stalls in the `EXEC_WAIT` state until `exec_flush_active` drops to `0`.
*Note: To prevent VHDL 32-bit integer overflow limits from evaluating to 'X' states, the 37-bit tracker is safely compared against a `ZERO_FLUSH_REG` constant.*

**6.3. Read-After-Write (RAW) Hazards**
* **Math RAW Hazards:** Inherently avoided for vector math because the 32-cycle loop is shorter than the 37-cycle pipe.
* **Control / Immediate RAW Hazards:** Loading immediate halves (`LDI_LO`, `LDI_HI`) or comparing values before branching requires the compiler to either insert independent instructions or issue an explicit `FLUSH` to clear the 37-cycle pipe before reading the register.

**6.4. The Writeback Controller & Latency Padding**
* All math operations are stretched via shift-register delay lines to exactly 37 cycles to prevent structural writeback hazards.
* **Non-Stalling Backend:** If the Instruction Fetcher stalls, the Writeback Controller continues ticking, automatically shifting `NOPs` (Write Enable = 0) into the pipe. This allows the up to 37 instructions already "in-flight" to safely complete and write to the register files without colliding.

## 7. Memory Subsystem
Accesses external DDR3 memory using a multi-cycle, coalescing memory controller.

**7.1. Handshake Synchronization**
The top-level FSM utilizes a 1-cycle `MEM_WAIT_START` buffer state when issuing memory commands. This guarantees the standalone Memory Control Unit (MCU) has a full clock edge to register the incoming command and assert its `mem_stall` output before the FSM begins polling it, preventing premature PC advancement.

**7.2. Sequential Coalescing**
The MCU evaluates the 32 unique addresses generated by the warp. If addresses are contiguous, they are bundled into high-efficiency burst transactions on the Avalon-MM bus. Non-contiguous "Scatter/Gather" requests are automatically serialized into smaller bursts.

**7.3. Address Generation**
Threads compute their own memory addresses using the dedicated integer ALU, bypassing float-to-int precision traps. The immediate `STORE` instruction routes the base address to the MCU, while the local offsets are pulled natively from Port B of the Vector Register File.
