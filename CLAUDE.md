# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Compile all sources and build testbench executables
make

# Run a single testbench
make test-<testbench_name>
# e.g.: make test-tb_fpu_lane

# Run all testbenches
make test-all

# List available testbenches
make test

# View waveforms (after running a test that generates waveform.ghw)
make view   # launches gtkwave

# Clean build artifacts
make clean
```

All builds use GHDL with VHDL-2008 (`--std=08`). Build artifacts go in `work/`. Waveforms are written to `waveform.ghw`.

## Architecture Overview

This is a **Graphics Vector Processing Unit (VPU)** targeting the Intel Cyclone V SE FPGA. It executes 128-bit vector operations (x, y, z, a) on IEEE 32-bit floats using a **SIMT model with 32 concurrent hardware threads** (one "Warp").

### Key Design Invariant: Rigid 37-Cycle Pipeline

The entire design is built around a **fixed 37-cycle FPU latency**. With 32 threads in a barrel scheduler, a new thread issues every cycle, so thread N's result is ready before thread N needs it again — eliminating RAW hazards without forwarding or stalling logic. All result paths (FPU, ALU, reduction) are synchronized to exactly 37 cycles via shift-register delay chains in `writeback_controller.vhd`.

**Consequence:** The ALU (`alu_lane.vhd`) is combinational but its output is delayed 37 cycles to match FPU writeback. Branching has a **software delay slot** — the compiler must insert an instruction between FCMP and its dependent BRA.

### Pipeline Stages

```
Instruction Fetch (instruction_fetch_unit.vhd)
  → Instruction Decode (instruction_decoder.vhd)
  → Issue / Register Read (instruction_issue.vhd)
  → Execute (execution_unit.vhd)
      ├── 4× FPU Lanes (fpu_lane.vhd) — 37 cycles, Altera IP
      ├── ALU Lane (alu_lane.vhd) — combinational + 37-cycle delay
      └── Vector Reduction Unit (vector_reduction_unit.vhd) — dot products
  → Writeback (writeback_controller.vhd)
```

### Register Files

- **Vector Register File** (`vector_reg_file.vhd`): 128 registers = 32 threads × 4 regs each. Dual-ported: Port A for FPU execution, Port B for memory controller (concurrent, independent access). Inferred as M10K blocks.
- **Predicate Register File** (`predicate_reg_file.vhd`): 4 bits per thread (one per component). Asynchronous reads for branch decisions.

### Memory Subsystem

- `mcu_scatter_gather.vhd`: Coalesces 32 per-thread addresses into Avalon-MM bursts. Uses VRF Port B.
- `avm_burst_bridge.vhd`: Avalon-MM protocol adapter.
- `avm_sim_memory.vhd`: Behavioral DDR3 simulation model for testbenches.

### FP IP Cores

`fp_sim_entities.vhd` / `fp_sim_arch.vhd` wrap Altera floating-point IP cores (MADD, comparators, transcendentals) with behavioral simulation models for GHDL. On real hardware these are replaced by Quartus IP instances.

### ISA

Defined in `processor_constants_pkg.vhd`. Four instruction types:
- `FPU` — floating-point math (MADD, recip, sqrt, log2, exp2, trig, min/max, compare, convert)
- `ALU` — integer arithmetic (add, sub, shifts, bitwise), also immediate variants
- `RED` — vector reduction (dot product, magnitude)
- `CTRL` — control flow (BRA, SSY, BRA_DIV, SYNC for warp divergence)

### Warp Divergence

Handled via an SSY/BRA_DIV/SYNC stack in `instruction_fetch_unit.vhd`. Divergent threads are tracked with a per-thread active mask; the SYNC instruction reconverges them.
