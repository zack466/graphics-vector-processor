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
The processor accesses external DDR3 memory through a fully decoupled, multi-cycle, scatter/gather memory controller. This subsystem isolates the strict 1-cycle timing constraints of the processor's internal pipeline from the unpredictable stall behavior (`waitrequest`) of the Avalon-MM master bus.

**7.1. Decoupled Architecture & FIFOs**
The Memory Control Unit (MCU) is split into three independent domains linked by hardware FIFOs. This allows the processor to dispatch memory commands at maximum speed and then immediately resume execution.
* **M10K FIFO Elasticity:** The internal Command, Write Data, and Load Tracking FIFOs are mapped directly to FPGA M10K block RAM. This completely avoids the use of Logic Elements (ALMs) for buffering, while gracefully absorbing Avalon bus stalls without requiring complex pipeline skid buffers.
* **Frontend (Coalescing State Machine):** Rapidly scans the 32 threads, calculates absolute memory addresses, and coalesces contiguous requests (stride-1) into burst commands. It blasts these commands and associated VRF write data into the FIFOs and drops the `mem_stall` signal immediately once the FIFOs are loaded.
* **Backend (Avalon Bridge):** A thin translation layer that pops commands from the FIFOs and issues them to the Avalon-MM bus. It handles DDR3 `waitrequests` natively by simply pausing the FIFO read enables, preventing data loss without stalling the processor frontend.

**7.2. VRF Port B Arbitration & Latency Tracking**
The MCU accesses the Vector Register File (VRF) via the dedicated Port B.
* **2-Cycle Read Latency:** To read data for `STORE` instructions, the MCU's state machine implements a strict 2-stage shift register (`read_active_q1`, `read_active_q2`). This accounts for the synchronous nature of the M10K blocks, ensuring data is stable on the bus before pushing it into the Write Data FIFO.
* **Asynchronous Write Collisions:** When memory returns from a `LOAD` instruction, the MCU writes it back to Port B. Because the math pipeline has strict priority on Port A, Port B writes are routed through an internal VRF collision buffer (FIFO) and drain into the RAM autonomously on the next free clock cycle.

**7.3. Asynchronous Load Tracking (Non-Blocking Reads)**
Because the MCU drops `mem_stall` immediately after dispatching a read command, the processor will move on to the next instruction while the DDR3 memory is still fetching the data.
* **Load Tracking FIFO:** The frontend pushes an 18-bit token (`dest_src_reg_idx` + `burst_len` + `start_thread_idx`) into a tracking FIFO.
* **Asynchronous Receiver:** When `avm_readdatavalid` pulses high cycles later, an independent background process pops the context from the tracking FIFO. This ensures the incoming data is written to the correct thread index and the correct destination register, even if the processor's pipeline has already advanced to an entirely different instruction.
* *Note on Hazards:* Because memory reads are non-blocking, software must manage memory Read-After-Write (RAW) hazards. If an instruction attempts to use loaded data before the Avalon bus returns it, the software compiler must inject `NOPs` or synchronization barriers.
