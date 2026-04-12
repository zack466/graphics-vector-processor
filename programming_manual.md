# SIMT Vector Processor — Programming Manual

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Register Files](#2-register-files)
3. [Instruction Syntax](#3-instruction-syntax)
4. [Instruction Reference](#4-instruction-reference)
   - [ALU Instructions](#41-alu-instructions)
   - [FPU Instructions](#42-fpu-instructions)
   - [Reduction Instructions](#43-reduction-instructions)
   - [Immediate (IMM) Instructions](#44-immediate-imm-instructions)
   - [Memory Instructions](#45-memory-instructions)
   - [Control Flow Instructions](#46-control-flow-instructions)
   - [System Instructions](#47-system-instructions)
5. [Pipeline Timing and FLUSH Rules](#5-pipeline-timing-and-flush-rules)
6. [SIMT Divergence](#6-simt-divergence)
7. [Writing a Shader to Generate an Image](#7-writing-a-shader-to-generate-an-image)
8. [Running Tests with the Automated Testbench](#8-running-tests-with-the-automated-testbench)
9. [Worked Examples](#9-worked-examples)

---

## 1. Architecture Overview

The processor is a **SIMT (Single Instruction, Multiple Threads)** vector processor organized as follows:

| Parameter | Value |
|---|---|
| Threads per warp | 32 |
| Warps (automated testbench) | 32 |
| VRF registers per thread | 16 (`v0`–`v15`) |
| Components per register | 4 (X, Y, Z, W) |
| Predicate registers per thread | 16 (`p0`–`p15`) |
| Component width | 32 bits |

The processor uses a **barrel scheduler**: the 32 threads of a warp cycle through the instruction stream one at a time, each thread issuing one instruction per cycle before the first thread issues again. This means the same thread sees a 32-cycle gap between consecutive instructions, which is wider than the ALU/FPU write-back latency (~29 cycles). As a result, **no FLUSH is needed between dependent arithmetic instructions** — the barrel scheduler provides the required separation automatically.

---

## 2. Register Files

### Vector Register File (VRF)

Each thread has **16 vector registers** `v0`–`v15`. Each register holds four 32-bit components:

```
v0  →  [ W | Z | Y | X ]
         ↑   ↑   ↑   ↑
         A   B   G   R  (when used as pixel color)
```

All registers are initialized to `0x00000000` on reset. Unwritten components remain 0.

**Register addressing:** Registers are referenced as `v0` through `v15`. The predicate register file uses `p0`–`p15` (or `r0`–`r15`; all are equivalent in the assembler).

### Predicate Register File (PRF)

Each thread has **16 predicate registers** `p0`–`p15`, each holding a single comparison flag bit. Predicate registers are written by `ICMP_*` and `FCMP_*` instructions and read by `BRA_DIV` to determine divergence.

---

## 3. Instruction Syntax

### General Format

```
MNEMONIC  dest[.mask], src1[.swizzle], src2
```

- Fields are separated by spaces or commas (both work).
- Comments begin with `#` and extend to end of line.
- Labels end with `:` on their own line or before an instruction.

### Write Mask

Append a dot suffix to the destination register to select which components are written. Components not in the mask retain their previous value.

| Suffix | Components written |
|---|---|
| `.xyzw` | All four (default if no suffix) |
| `.x` | X only |
| `.y` | Y only |
| `.z` | Z only |
| `.w` | W only |
| `.xy` | X and Y |
| `.xz` | X and Z |
| `.xw` | X and W |
| `.yz` | Y and Z |
| `.yw` | Y and W |
| `.zw` | Z and W |
| `.xyz` | X, Y, Z |
| `.xyw` | X, Y, W |
| `.xzw` | X, Z, W |
| `.yzw` | Y, Z, W |

Example: `IADD v4.xy, v0, v1` writes only the X and Y components of `v4`.

**Note for `LDI_LO`/`LDI_HI`:** These instructions only support a 1-bit "full mask" flag — either all components are written (`.xyzw` or no suffix) or none. Per-component masking is not available for immediate loads.

### Swizzle

Append a dot suffix to a **source** register to replicate one component into all four lanes before the operation:

| Suffix | Meaning |
|---|---|
| `.xxxx` | Broadcast X into all 4 lanes |
| `.yyyy` | Broadcast Y into all 4 lanes |
| `.zzzz` | Broadcast Z into all 4 lanes |
| `.wwww` | Broadcast W into all 4 lanes |
| `.xyzw` | Pass through (no swizzle, default) |

Example: `FMUL v3.xyzw, v1.xxxx, v2` multiplies all 4 components of `v2` by the X component of `v1`.

---

## 4. Instruction Reference

### 4.1 ALU Instructions

All ALU instructions operate on 32-bit integers. Each instruction runs in **all 32 threads** simultaneously; the write mask selects which components are updated.

#### `THREAD_ID  dest[.mask]`
Load the global thread ID into all selected components of `dest`.
- `global_tid = warp_offset + lane_index` (0–1023 across 32 warps of 32 threads)
- The `warp_offset` is set automatically by `warp_scheduler` before each warp launches. Shaders do not need to read it directly.

```asm
THREAD_ID v0.xyzw    # v0 = global thread ID in all 4 components
```

#### `IADD  dest[.mask], src1, src2`
Integer addition: `dest = src1 + src2`

#### `ISUB  dest[.mask], src1, src2`
Integer subtraction: `dest = src1 - src2`

#### `IMUL  dest[.mask], src1, src2`
Integer multiplication: `dest = src1 * src2`

#### `IAND  dest[.mask], src1, src2`
Bitwise AND: `dest = src1 & src2`

#### `IOR  dest[.mask], src1, src2`
Bitwise OR: `dest = src1 | src2`

#### `IXOR  dest[.mask], src1, src2`
Bitwise XOR: `dest = src1 ^ src2`

#### `ISHL  dest[.mask], src1, src2`
Logical shift left: `dest = src1 << src2[4:0]`
- Shift amount is the lower 5 bits of `src2`.

#### `ISHR  dest[.mask], src1, src2`
Logical shift right (zero-fill): `dest = src1 >> src2[4:0]`

#### `ISAR  dest[.mask], src1, src2`
Arithmetic shift right (sign-extend): `dest = src1 >>> src2[4:0]`

#### `IINC  dest[.mask], src1`
Increment: `dest = src1 + 1`

#### `IDEC  dest[.mask], src1`
Decrement: `dest = src1 - 1`

#### `ICMP_EQ  pdest, src1, src2`
Integer compare equal. Writes result bit into all 4 bits of predicate register `pdest`.
- `pdest = (src1 == src2) ? 1 : 0`

```asm
ICMP_EQ p0, v3, v4   # p0 = (v3 == v4)
```

#### `ICMP_SLT  pdest, src1, src2`
Signed integer compare less-than: `pdest = (src1 < src2)` (signed)

#### `ICMP_ULT  pdest, src1, src2`
Unsigned integer compare less-than: `pdest = (src1 < src2)` (unsigned)

---

### 4.2 FPU Instructions

All FPU instructions operate on 32-bit IEEE 754 single-precision floats. The write mask applies per-component.

#### `FADD  dest[.mask], src1[.swizzle], src2`
Float addition: `dest = src1 + src2`

#### `FSUB  dest[.mask], src1[.swizzle], src2`
Float subtraction: `dest = src1 - src2`

#### `FMUL  dest[.mask], src1[.swizzle], src2`
Float multiplication: `dest = src1 * src2`

#### `FMADD  dest[.mask], src1[.swizzle], src2`
Fused multiply-add: `dest = src1 * src2 + dest` (accumulates into dest)

#### `FRCP  dest[.mask], src1`
Float reciprocal: `dest = 1.0 / src1`

#### `FSQRT  dest[.mask], src1`
Float square root: `dest = sqrt(src1)`

#### `FLOG2  dest[.mask], src1`
Float base-2 logarithm: `dest = log2(src1)`

#### `FEXP2  dest[.mask], src1`
Float base-2 exponential: `dest = 2^src1`

#### `SIN  dest[.mask], src1`
Float sine: `dest = sin(src1)` (radians)

#### `COS  dest[.mask], src1`
Float cosine: `dest = cos(src1)` (radians)

#### `FMIN  dest[.mask], src1[.swizzle], src2`
Float minimum: `dest = min(src1, src2)`

#### `FMAX  dest[.mask], src1[.swizzle], src2`
Float maximum: `dest = max(src1, src2)`

#### `FCMP_LT  pdest, src1, src2`
Float compare less-than: `pdest = (src1 < src2)`

#### `FCMP_EQ  pdest, src1, src2`
Float compare equal: `pdest = (src1 == src2)`

#### `F2I  dest[.mask], src1`
Convert float to integer (truncate toward zero): `dest = (int)src1`

#### `I2F  dest[.mask], src1`
Convert integer to float: `dest = (float)src1`

```asm
I2F v1.xyzw, v0    # v1 = float(v0)
```

#### `PAND  dest[.mask], src1, src2`
Bitwise AND operating on predicate registers: `dest = src1 & src2`

#### `POR  dest[.mask], src1, src2`
Bitwise OR on predicate registers: `dest = src1 | src2`

#### `PXOR  dest[.mask], src1, src2`
Bitwise XOR on predicate registers: `dest = src1 ^ src2`

---

### 4.3 Reduction Instructions

Reduction instructions collapse a 4-component vector into a scalar (written to a single component of the destination).

#### `DOT  dest[.mask], src1[.swizzle], src2`
Dot product: `dest = src1.x*src2.x + src1.y*src2.y + src1.z*src2.z + src1.w*src2.w`

#### `SQ_MAG  dest[.mask], src1[.swizzle], src2`
Squared magnitude: `dest = sum(src1_i^2)` (src2 ignored)

#### `SUM  dest[.mask], src1[.swizzle], src2`
Horizontal sum: `dest = src1.x + src1.y + src1.z + src1.w`

#### `ABS_SUM  dest[.mask], src1[.swizzle], src2`
Sum of absolute values: `dest = |src1.x| + |src1.y| + |src1.z| + |src1.w|`

Example:
```asm
SUM v3.y, v0.yyyy, v1   # v3.Y = sum of all components of v0 (broadcast .yyyy)
```

---

### 4.4 Immediate (IMM) Instructions

#### `LDI_LO  dest[.mask], imm16`
Load immediate into the lower 16 bits of each selected component. Upper 16 bits are zeroed.

```asm
LDI_LO v1.xyzw, 0x0004   # v1 = 0x00000004 in all components
```

#### `LDI_HI  dest[.mask], imm16`
Load immediate into the upper 16 bits of each selected component. The **lower 16 bits are preserved** from the current value of `dest`.

Used together with `LDI_LO` to load a full 32-bit constant:

```asm
LDI_LO v10.xyzw, 0x0000   # lower 16 bits = 0x0000
LDI_HI v10.xyzw, 0x3F80   # upper 16 bits = 0x3F80 → v10 = 0x3F800000 = 1.0f
```

> **Important:** Always execute `LDI_LO` before `LDI_HI` for the same destination register. `LDI_HI` reads the current lower 16 bits of `dest` to compose the final value; if `LDI_LO` has not been issued, the lower bits will be stale.

**Write mask note:** `LDI_LO`/`LDI_HI` support only a 1-bit full-mask flag. Either all four components are written (`.xyzw` or no suffix) or only an explicit single-component suffix (`.x`, `.y`, etc.) is used.

---

### 4.5 Memory Instructions

Memory is a flat 128-bit-wide space. Each address holds 16 bytes (four 32-bit components). The new block transfer memory controller issues memory accesses at the granularity of an entire warp (32 threads).

#### `STORE  src, imm14`
Write 32 packed pixels (one per thread in the warp) to memory sequentially starting at the byte address `imm14 << 16`.

```asm
STORE v4, 0x0001       # mem[0x00010000...] = packed(v4)
```

- `imm14` is a 14-bit unsigned immediate forming the upper half of the 32-bit base address.
- The `STORE` instruction causes the barrel scheduler to read `src` for all 32 threads.
- The memory controller snoops this data, extracts the lower 8 bits of the W, Z, Y, and X components of each thread's vector, and packs them into a 32-bit integer (RGBA format: Alpha=W, Blue=Z, Green=Y, Red=X).
- It then issues 8 back-to-back 128-bit Avalon burst writes to memory.
- **FLUSH is required before STORE** to ensure all threads' vector register values are committed before the memory controller reads the VRF.

---

### 4.6 Control Flow Instructions

#### `JMP  target`
Unconditional jump to `target` (label or 16-bit address).

```asm
JMP loop_start
```

#### `BRA_L  target`
Branch with link to `target` (label or 16-bit address).
Stores the next PC into the Link status register.

```asm
BRA_L leaf_function
```

#### `BRA_X`
Branch with exchange.
Subsitutes the current PC with the value stored in the Link status register.

```asm
BRA_X
```

#### `PUSH_L`
Pushes the current Link register onto the call stack.

```asm
PUSH_L
```

#### `POP_L`
Pops the topmost element of the call stack and puts it into the link register.

```asm
POP_L
```

#### `BRA_Z  target, pred[.mod]`
Branch if predicate is zero (false). Jumps to `target` if the predicate register is 0.

#### `BRA_NZ  target, pred[.mod]`
Branch if predicate is non-zero (true). Jumps to `target` if the predicate register is 1.

**Predicate modifiers** (`.ANY`, `.ALL`, `.X`, `.A`):

| Modifier | Meaning |
|---|---|
| `.ANY` (default) | Branch if any thread's predicate is set |
| `.ALL` | Branch if all threads' predicates are set |
| `.X` | Use predicate component X only |
| `.A` | Use predicate component A/W only |

```asm
BRA_NZ done, p0.ALL    # jump if all threads have p0 = 1
```

#### `BRA_DIV  target, pred`
**Divergent branch** for SIMT control flow. Splits the warp into two groups:
- Threads where `pred = 1` (taken) jump to `target`.
- Threads where `pred = 0` (not-taken) fall through to the next instruction.

Must be preceded by a matching `SSY` instruction and a `FLUSH`. See [Section 6](#6-simt-divergence) for the full usage pattern.

```asm
SSY reconv             # push reconvergence address
BRA_DIV if_true, p0   # taken (p0=1) → if_true; not-taken → fall-through
```

#### `SSY  reconv_label`
Save the reconvergence PC. Must appear immediately before `BRA_DIV`. Pushes `reconv_label` onto the SIMT stack so that `SYNC` can find the merge point.

#### `SYNC`
Synchronize divergent threads. Pops the current divergence entry from the SIMT stack:
- If the complementary path has not yet executed, switches execution to that path.
- If both paths are done, falls through to the reconvergence point.

Place one `SYNC` at the end of each divergent path. See [Section 6](#6-simt-divergence).

---

### 4.7 System Instructions

#### `FLUSH`
Stall the warp until the entire pipeline has drained — all in-flight ALU, FPU, and memory operations for this warp complete and all write-backs to VRF and PRF are finished.

Required before:
- Any `STORE` instruction (MCU reads VRF for all 32 threads after all STOREs are issued).
- Any `BRA_DIV` instruction (branch reads PRF combinationally; all ICMP results must be settled).
- Optionally before `RETURN` for correctness if stores are pending.

**Not required between dependent arithmetic instructions** — the barrel scheduler provides a natural 32-cycle separation between same-thread instructions, which exceeds the maximum write-back latency.

#### `RETURN`
End of shader execution for this warp.

#### `BREAK`
Software breakpoint (halts simulation for debugging).

#### `INT`
Interrupt (reserved for future use).

---

## 5. Pipeline Timing and FLUSH Rules

### Barrel Scheduler

The 32 threads of a warp are issued in round-robin order: thread 0, thread 1, ..., thread 31, then thread 0 again. This produces a **32-cycle gap** between any two consecutive instructions issued by the same thread.

| Event | Cycles |
|---|---|
| Max ALU/FPU write-back latency | ~29 cycles |
| Barrel inter-thread spacing | 32 cycles |
| Available margin | ~3 cycles |

Because 32 > 29, **chained ALU/FPU computations do not need FLUSH between them**:

```asm
I2F  v1.xyzw, v0        # no FLUSH before FMUL — barrel provides enough gap
FMUL v3.xyzw, v1, v1   # v1 is ready
FMUL v4.xyzw, v3, v3   # v3 is ready
```

### When FLUSH Is Required

| Situation | Reason |
|---|---|
| Before `STORE` | MCU reads VRF for all 32 threads after all STOREs are issued. Thread 31's write-back (~cycle 60) may not be complete when MCU reads at cycle ~38 without FLUSH. |
| Before `BRA_DIV` | BRA_DIV reads the PRF combinationally at decode time. Thread 31's ICMP result (written at ~cycle 60) is not settled by decode (~cycle 38) without FLUSH. |
| After the last `STORE` block before `RETURN` | Ensures all memory writes complete. |

### Pattern

```asm
# ... arithmetic ...
FLUSH                  # drain before store
STORE v_result, 0x0000 # write warp to address 0x00000000
FLUSH                  # drain after store (before RETURN)
RETURN
```

---

## 6. SIMT Divergence

### Concept

All 32 threads of a warp always execute the same instruction stream. When threads need to take different code paths, the **exec_mask** records which threads are "active" on each path. Only `STORE` respects the exec_mask — ALU/FPU/IMM instructions always run for all 32 threads.

### Required Instruction Sequence

```asm
    ICMP_EQ p0, v_cond, v_zero  # compute predicate
    FLUSH                        # wait for all PRF writes
    SSY     reconv               # save reconvergence PC
    BRA_DIV if_label, p0         # taken (p0=1) → if_label; not-taken → fall-through

# ---- not-taken (else) path ----
    # instructions for "false" threads
    # Note: With the block transfer STORE, Avalon byte enables are masked
    # based on the exec_mask, so masked pixels are left untouched in memory.
    STORE   v_else, 0x0000           # exec_mask: false threads only
    SYNC                              # end of else-path

# ---- taken (if) path ----
if_label:
    # instructions for "true" threads
    STORE   v_if, 0x0000             # exec_mask: true threads only
    SYNC                              # end of if-path → reconverge

# ---- reconvergence ----
reconv:
    FLUSH
    RETURN
```

### Notes

- `SSY` must immediately precede `BRA_DIV` (no instructions between them).
- Each divergent path must end with exactly one `SYNC`.
- After both `SYNC` instructions execute, control resumes at `reconv`.
- ALU/FPU/IMM instructions in each path run for **all** threads. Write the correct value in all threads — only the `STORE` selects which threads commit to memory.
- Nested divergence (divergence inside divergence) is supported by the SIMT stack but is not covered here.

---

## 7. Writing a Shader to Generate an Image

### Framebuffer Layout

The testbench runs **32 warps**, each with a **warp_offset** of 0, 32, 64, ..., 992. This gives 1024 total threads, one per pixel of a **32×32 image**.

Each thread writes one 128-bit pixel to the framebuffer:

| Memory bits | Component | Image channel |
|---|---|---|
| [31:0] | X | Red (R) |
| [63:32] | Y | Green (G) |
| [95:64] | Z | Blue (B) |
| [127:96] | W | Alpha (A) |

Colors are **raw 8-bit integers** in the range [0, 255], stored in the lower 8 bits of each 32-bit VRF component. `runner.py` reads these directly without any scaling. Use `F2I` to convert floating-point intermediate results to integers before `STORE`.

Useful integer constants:

| Value | Assembly |
|---|---|
| 0 (black) | `LDI_LO vN.xyzw, 0x0000` |
| 255 (white/opaque) | `LDI_LO vN.xyzw, 0x00FF` |
| 128 (mid-gray) | `LDI_LO vN.xyzw, 0x0080` |

### Pixel Address

Each pixel is 16 bytes (128-bit bus). Byte address for pixel N:

```asm
THREAD_ID v0.xyzw       # v0 = global_tid = N
LDI_LO    v1.xyzw, 0x0004
ISHL      v_addr.xyzw, v0, v1   # v_addr = global_tid * 16
```

### Column and Row

For a 32-wide image:

```asm
THREAD_ID v0.xyzw
LDI_LO    v_mask.xyzw, 0x001F  # 0x1F = 31
LDI_LO    v_sh.xyzw,   0x0005  # 5

IAND      v_x.xyzw, v0, v_mask  # x = tid & 0x1F  (column 0..31)
ISHR      v_y.xyzw, v0, v_sh    # y = tid >> 5     (row 0..31)
```

### Shader Template

```asm
# my_shader.s — minimal shader template

THREAD_ID v0.xyzw            # global_tid

# --- compute color into v_out (RGBA as integers 0–255) ---
#   X component = Red
#   Y component = Green
#   Z component = Blue
#   W component = Alpha

# ... your computation here ...
# Use F2I to convert float results to integers before STORE.

FLUSH
STORE v_out, 0x0000
FLUSH
RETURN
```

### Assembling and Running

```bash
# Assemble one shader and generate an image
uv run python tools/runner.py tools/my_shader.s

# Output:
#   src/program.hex    — assembled machine code
#   src/memory_dump.hex — raw framebuffer output
#   tools/my_shader.png — rendered image (requires Pillow)
```

> **Note:** Use `uv run python` (not bare `python`) to ensure the managed virtual environment is active and Pillow is available for PNG generation. If you use system Python, image generation will silently be skipped.

---

## 8. Running Tests with the Automated Testbench

### Single Test

```bash
uv run python tools/runner.py tools/test01_thread_id.s
```

This will:
1. Assemble the `.s` file to `src/program.hex`
2. Run `make clean && make build` in `src/`
3. Run the simulation (`tb_frame_processor_automated`)
4. Save a PNG image alongside the `.s` file

### All Tests

```bash
# Full run — rebuild VHDL from scratch, then run all tests and generate images
uv run python tools/run_all_tests.py

# Skip VHDL rebuild (faster when only .s files changed)
uv run python tools/run_all_tests.py --no-rebuild

# Skip PNG generation
uv run python tools/run_all_tests.py --no-images
```

The script discovers all files matching `tools/test[0-9][0-9]_*.s` (sorted), runs them in order, and prints a pass/fail summary:

```
  ✓ test01_thread_id                    PASS (2.1s)
  ✓ test02_i2f                          PASS (2.6s)
  ...
  9/9 tests passed
```

Exit code is 0 if all tests pass, 1 if any fail.

### Adding a New Test

1. Create `tools/testNN_name.s` following the naming convention (`NN` = two-digit number).
2. The `run_all_tests.py` script will pick it up automatically on the next run.

### Testbench Configuration

The automated testbench (`src/tb_frame_processor_automated.vhd`) drives a single `frame_start` pulse to `frame_processor`. The internal `warp_scheduler` then automatically dispatches **32 warps** sequentially, advancing `warp_offset` by 32 each time (0, 32, 64, ..., 992). The testbench waits for the `frame_done` pulse before dumping memory. After simulation, the framebuffer contents are written to `src/memory_dump.hex` in the format:

```
W Z Y X     ← each line is one pixel (128-bit bus: W=[127:96], Z=[95:64], Y=[63:32], X=[31:0])
```

---

## 9. Worked Examples

### Example 1: Per-Thread ID Output

```asm
# Each thread stores its own ID as an integer in all components.
THREAD_ID v0.xyzw       # v0.xyzw = absolute thread index
# NOTE: LDI_LO/LDI_HI only support a 1-bit full-mask flag.
# A partial mask like "v0.w" sets full_mask=0, which writes NOTHING.
# To set all components and then fix up one, use a separate register:
LDI_LO v1.xyzw, 0x00FF  # v1 = 255 in all components (alpha = 255)
# STORE reads only the lower 8 bits of each component.
# v0.x = thread_id[7:0] = R, v0.y = G, v0.z = B, v1.w will be 255 but
# we'd need to assemble the output from multiple registers — simplest is:
FLUSH
STORE v0, 0x0000        # store thread_id in R, G, B, A (all = thread_id)
FLUSH
RETURN
```

> **Gotcha:** `LDI_LO v0.w, 0x00FF` silently does nothing because per-component masking is not supported by `LDI_LO`/`LDI_HI`. Use `.xyzw` (or no mask suffix) and a separate register when you need to load a constant into one component only.

### Example 2: Float Gradient (R = x/32, G = y/32)

```asm
THREAD_ID v0.xyzw        # v0 = global_tid
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (mask for lower 5 bits)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (shift for >>5)
LDI_LO v10.xyzw, 0x0000
LDI_HI v10.xyzw, 0x3D00 # v10 = 0x3D000000 = 0.03125f = 1/32
LDI_LO v13.xyzw, 0x0000
LDI_HI v13.xyzw, 0x437F # v13 = 0x437F0000 = 255.0f (alpha constant and scale factor)
IAND v4.xyzw, v0, v1    # v4 = x (column, 0..31)
ISHR v6.xyzw, v0, v3    # v6 = y (row, 0..31)
I2F v8.xyzw, v4         # v8 = float(x) in all 4 components
I2F v9.xyzw, v6         # v9 = float(y) in all 4 components
FMUL v11.xyzw, v8, v10  # v11 = x/32 in all 4 components (R value)
FMUL v12.xyzw, v9, v10  # v12 = y/32 in all 4 components (G value)
# Assemble output vector v14 = {X=R*255, Y=G*255, Z=0, W=255.0f}
# Z is left as 0 (VRF initialized to 0, never written)
LDI_LO v15.xyzw, 0x0000
LDI_HI v15.xyzw, 0x437F # v15 = 255.0f in all components
LDI_LO v16.xyzw, 0x0000 # v16 = 0.0f
FMUL v14.x, v11, v13    # v14.X = (x/32) * 255.0f = R  [write X only]
FMUL v14.y, v12, v13    # v14.Y = (y/32) * 255.0f = G  [write Y only]
IADD v14.z, v16, v16    # v14.Z = 0.0f
IADD v14.w, v15, v16    # v14.W = 255.0f
F2I v15.xyzw, v14       # Convert float RGBA to integer (0-255)
FLUSH                    # drain pipeline before MCU reads VRF
STORE v15, 0x0000       # store {W=255, Z=0, Y=G, X=R}
FLUSH
RETURN
```

### Example 3: Checkerboard (White if x+y even, Black if odd)

```asm
THREAD_ID v0.xyzw        # v0 = global_tid = warp_offset + lane
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (mask for lower 5 bits)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (shift amount for >> 5)
LDI_LO v5.xyzw, 0x0004  # v5 = 4 (shift amount for * 16 byte addr)
IAND v4.xyzw, v0, v1    # v4 = x = local_tid (column, 0..31)
ISHR v6.xyzw, v0, v3    # v6 = y = warp_y (row, 0..31)
ISHL v2.xyzw, v0, v5    # v2 = global_tid * 16 (byte address in framebuffer)
IADD v7.xyzw, v4, v6    # v7 = x + y
LDI_LO v8.xyzw, 0x0001  # v8 = 1 (bit mask)
IAND v9.xyzw, v7, v8    # v9 = (x + y) & 1  (0=even=white, 1=odd=black)
LDI_LO v10.xyzw, 0x0000 # v10 = 0 (comparison value for even check)
ICMP_EQ p0, v9, v10     # p0 = (v9 == 0) = (x+y is even) = white
FLUSH                    # REQUIRED: settle PRF before BRA_DIV
SSY reconv               # save reconvergence PC
BRA_DIV white, p0        # even (white) threads jump to white; odd fall through

# ---- Black path (odd = black = not-taken, falls through) ----
LDI_LO v11.xyzw, 0x0000 # v11 = 0 (black)
STORE v11, 0x0000
SYNC

# ---- White path (even = white = taken) ----
white:
LDI_LO v11.xyzw, 0x00FF # v11 = 255 (white)
STORE v11, 0x0000
SYNC

# ---- Reconvergence ----
reconv:
FLUSH
RETURN
```
