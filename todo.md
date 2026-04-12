# Project Refactoring Plan

---

## Change 1: Block-Transfer Memory Controller ✅ COMPLETE

Replaced `mcu_scatter_gather.vhd` with `mcu_block_transfer.vhd`. The new MCU snoops
32 execution-unit writeback cycles, packs 32 × 32-bit RGBA pixels into a 1024-bit buffer,
then emits 8 sequential 128-bit Avalon burst write beats. Testbenches pass cleanly.

---

## Change 2: Warp Scheduler + Warp Unit Refactor

### Objective

Replace the current `processor.vhd` (which requires the host to manually write CSR
registers for every warp) with a self-contained hardware system that draws an entire
frame from a single `start` pulse. The architecture is explicitly structured so that
latency hiding (Change 3) requires only instantiating additional `warp_unit` instances
and extending the scheduler — no changes to `warp_unit` or `mcu_block_transfer` internal
logic.

---

### Target Architecture

```
frame_processor.vhd            ← new synthesized top level
├── instruction_memory          ← shared IMEM (same program for all warps)
├── warp_scheduler.vhd          ← frame-level FSM; iterates warp_offset 0, 32, 64, ...
│                                  drives warp_start/warp_offset per warp_unit
│                                  outputs frame_done when last warp completes
├── warp_unit.vhd               ← x1 now; xN for latency hiding (Change 3)
│   ├── instruction_fetch_unit  ← unchanged internal logic
│   ├── instruction_decoder     ← unchanged internal logic
│   ├── instruction_issue       ← unchanged internal logic
│   ├── execution_unit          ← unchanged internal logic
│   ├── vector_reg_file         ← unchanged internal logic
│   ├── predicate_reg_file      ← unchanged internal logic
│   ├── pixel_snoop_buffer      ← inline registers (moved from mcu_block_transfer)
│   └── proc_fsm                ← unchanged states; csr_run replaced by warp_start/running
└── mcu_block_transfer.vhd      ← top-level peer; simplified input interface
     └── avm_burst_bridge.vhd   ← unchanged
```

**What changes and what does not:**

| File | Status |
|---|---|
| `instruction_fetch_unit.vhd` | No changes to internal logic |
| `instruction_decoder.vhd` | No changes to internal logic |
| `instruction_issue.vhd` | No changes to internal logic |
| `execution_unit.vhd` | No changes to internal logic |
| `vector_reg_file.vhd` | No changes to internal logic |
| `predicate_reg_file.vhd` | No changes to internal logic |
| `avm_burst_bridge.vhd` | No changes |
| `mcu_block_transfer.vhd` | Port interface simplified (snoop signals removed; flat pixel buffer added) |
| `processor.vhd` | Superseded by `warp_unit.vhd` + `frame_processor.vhd`; can be removed |
| `memory_unit.vhd` | Superseded; mcu and bridge are now direct children of frame_processor |
| `warp_unit.vhd` | **New** — refactored processor body (no CSR, no IMEM, no embedded MCU) |
| `warp_scheduler.vhd` | **New** — frame-level dispatch FSM |
| `frame_processor.vhd` | **New** — structural top level wiring everything together |

---

### Step 1 — Simplify `mcu_block_transfer.vhd` interface

**Motivation:** The pixel snoop buffer (the 32-entry array that accumulates RGBA data
from the execution unit during EXEC_WAIT) is moving into `warp_unit`. The MCU's new job
is: receive a pre-filled 1024-bit buffer + address + mask, then burst-write 8 × 128-bit
beats. It no longer needs to see raw execution-unit snoop signals.

**Remove from mcu_block_transfer ports:**
```vhdl
mem_store_valid   : in  std_logic;
mem_store_thread  : in  std_logic_vector(4 downto 0);
mem_store_data    : in  vector_t;
```

**Remove internal logic:** The `Store Buffer Write Port` process that indexes
`warp_buffer` by `mem_store_thread` moves into `warp_unit`.

**Add to mcu_block_transfer ports:**
```vhdl
-- Pre-packed pixel buffer from warp_unit (replaces snoop signals)
pixel_buf_data  : in  std_logic_vector(1023 downto 0);  -- 32 packed 32-bit pixels (flat)
```

**Rename `mem_op_valid` → `pixel_buf_valid`** to reflect the new trigger semantics.
The signal is still a 1-cycle pulse, but it arrives after the buffer is already filled.

**Result:** mcu_block_transfer now only has states IDLE → STORE_CMD → STORE_BURST.
The SNOOP phase is gone. On `pixel_buf_valid` it latches `pixel_buf_data`, `base_addr`,
and `exec_mask`, asserts `mem_stall`, then runs the 8-beat burst exactly as before.

**Update `tb_mcu_block_transfer.vhd`** to remove snoop signal stimulation and instead
drive `pixel_buf_data` directly before pulsing `pixel_buf_valid`.

---

### Step 2 — Create `warp_unit.vhd`

This is `processor.vhd` with three changes:
1. CSR Avalon slave interface removed; replaced by lean direct-wired control ports.
2. `instruction_memory` and `prog_*` ports removed (IMEM lives at frame_processor level).
3. `memory_unit` subinstance removed; pixel buffer is inline here; MCU is a top-level peer.

**Entity ports:**

```vhdl
entity warp_unit is
    generic (
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128;
        REG_WIDTH       : integer := 4
    );
    port (
        clk, reset : in std_logic;

        -- Instruction memory read port (IMEM is external, shared)
        imem_addr   : out std_logic_vector(PC_WIDTH-1 downto 0);
        imem_data   : in  std_logic_vector(31 downto 0);

        -- Warp control (from warp_scheduler)
        warp_start  : in  std_logic;   -- 1-cycle pulse: begin execution
        warp_offset : in  std_logic_vector(31 downto 0);  -- pixel index for address calc
        warp_halted : out std_logic;   -- asserted (level) while FSM is in HALTED state
        warp_break  : out std_logic;   -- asserted for 1 cycle when OP_BREAK executes

        -- Pixel buffer output (to mcu_block_transfer)
        pixel_buf_valid : out std_logic;                       -- buffer full; request write
        pixel_buf_addr  : out std_logic_vector(31 downto 0);  -- computed DDR3 byte address
        pixel_buf_data  : out std_logic_vector(1023 downto 0);-- 32 packed pixels, flat
        mem_stall       : in  std_logic                        -- MCU busy; hold MEM_WAIT
    );
end entity;
```

**Internal changes vs processor.vhd:**

- Replace `csr_run`/CSR process with internal `running` register:
  - Set on rising edge when `warp_start = '1'`
  - Cleared when FSM is in DECODE and OP_RETURN executes
  - FSM uses `running` the same way it used `csr_run`

- Replace `csr_warp_offset` with a registered latch of `warp_offset`:
  - Latch `warp_offset` into `reg_warp_offset` on the same cycle `warp_start` is asserted
  - Used to compute `pixel_buf_addr` the same way `mem_phys_addr` is computed now

- `warp_halted` is driven combinationally: `warp_halted <= '1' when state = HALTED`

- Add `pixel_snoop_buffer` registers (32-entry array of 32-bit packed pixels):
  - Written by a clocked process identical to the `Store Buffer Write Port` being removed
    from mcu_block_transfer, fed by the existing `exec_mem_store_*` signals
  - Flat output: `pixel_buf_data <= buf(31) & buf(30) & ... & buf(0)` (combinational concat)

- MEM_WAIT logic: unchanged — it already waits for `mem_stall = '0'`. Now `mem_stall`
  comes from the external MCU instead of from the embedded memory_unit.

- `pixel_buf_valid` (replaces `mem_op_valid`): pulsed in the same EXEC_WAIT → MEM_WAIT
  transition, after `iss_issue_valid = '0'`.

- `pixel_buf_addr` is the same `mem_phys_addr` calculation, driven from `reg_warp_offset`.

- Remove: `do_force_pc`, `csr_start_pc`, `irq_pending` (no host CSR in warp_unit).
  OP_BREAK still asserts `warp_break` for one cycle and halts.

**FSM states:** HALTED, FETCH_ADDR, FETCH_DATA, DECODE, EXEC_WAIT, MEM_WAIT,
ADVANCE_PC — all identical semantics to processor.vhd.

---

### Step 3 — Create `warp_scheduler.vhd`

A pure-FSM entity that sequences warp_offset values from 0 to (frame_width × frame_height)
in steps of WARP_SIZE, controlling one (or more) warp_units.

**Entity ports:**

```vhdl
entity warp_scheduler is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32
    );
    port (
        clk, reset    : in  std_logic;

        -- Frame trigger (from host / test environment)
        frame_start   : in  std_logic;                        -- 1-cycle pulse to begin frame
        frame_width   : in  std_logic_vector(15 downto 0);   -- pixels per row
        frame_height  : in  std_logic_vector(15 downto 0);   -- rows per frame
        frame_done    : out std_logic;                        -- 1-cycle pulse when done

        -- Per-warp control (flat for single warp; extend to arrays for Change 3)
        warp_start    : out std_logic;
        warp_offset   : out std_logic_vector(31 downto 0);
        warp_halted   : in  std_logic
    );
end entity;
```

**Internal signals:**
```
total_pixels : unsigned(31 downto 0)   -- frame_width * frame_height (registered)
next_offset  : unsigned(31 downto 0)   -- increments by WARP_SIZE after each dispatch
```

**FSM states:**

- `IDLE` — wait for `frame_start = '1'`. On entry: latch total_pixels = frame_width *
  frame_height; reset next_offset = 0.

- `DISPATCH` — assert `warp_start = '1'` for exactly one cycle with
  `warp_offset = next_offset`. Advance `next_offset += WARP_SIZE`. Next: `WAIT_HALT`.

- `WAIT_HALT` — wait until `warp_halted = '1'` (warp FSM has returned to HALTED after
  OP_RETURN). The warp's MEM_WAIT already ensures the burst completes before OP_RETURN
  is reached, so no separate MCU-done check is needed. Once halted:
  - If `next_offset < total_pixels`: next state = `DISPATCH`
  - Else: next state = `DONE`

- `DONE` — assert `frame_done = '1'` for one cycle. Next: `IDLE`.

**Implementation note on multiplication:** `frame_width * frame_height` can be computed
with a DSP block or registered as a combinational `unsigned` multiply (safe up to 16×16
bits = 32-bit result). Latch the result in IDLE on the cycle `frame_start` is asserted.

---

### Step 4 — Create `frame_processor.vhd`

New synthesized top. Structural entity — no logic, just wiring.

**Ports:** Same Avalon-MM master interface as current `processor.vhd` (avm_*), plus
`prog_*` instruction memory programming interface, plus `frame_start`/`frame_width`/
`frame_height`/`frame_done` replacing the CSR slave.

If the host still needs CSR-style control (e.g. from Platform Designer), a thin CSR
wrapper can sit above `frame_processor` and translate Avalon writes into
`frame_start`/`frame_width`/`frame_height` signals. This keeps `frame_processor`
itself purely structural.

**Instantiations:**

```
u_imem   : instruction_memory (prog_we/addr/data from ports; rd_addr from warp_unit.imem_addr)
u_sched  : warp_scheduler     (frame_start/width/height/done; warp_start/offset/halted)
u_warp   : warp_unit          (warp_start/offset/halted from scheduler; imem_* from imem;
                               pixel_buf_* to MCU; mem_stall from MCU)
u_mcu    : mcu_block_transfer (pixel_buf_valid/addr/data from warp_unit; cmd/tx to bridge)
u_bridge : avm_burst_bridge   (cmd/tx from MCU; avm_* to DDR3 ports)
```

---

### Step 5 — Testbenches

**`tb_warp_unit.vhd`** (new):
- Instantiate `warp_unit` with a small ROM or BRAM stub for IMEM.
- Feed a test shader program (a few arithmetic instructions + OP_STORE + OP_RETURN).
- Pulse `warp_start` with a known `warp_offset`.
- Verify `pixel_buf_valid` fires after EXEC_WAIT, then assert `mem_stall = '0'` to
  release MEM_WAIT. Verify `warp_halted` asserts after OP_RETURN.

**`tb_warp_scheduler.vhd`** (new):
- Mock `warp_halted`: immediately assert it N cycles after `warp_start` (simulating a
  fast warp completion).
- Drive `frame_start` with frame_width=4, frame_height=2 (8 pixels = 1 warp at 8,
  but WARP_SIZE=32 means 1 dispatch for a sub-warp frame).
- Use a larger frame (e.g. 256×256 = 65536 pixels = 2048 warps) to verify
  `next_offset` sequence: 0, 32, 64, ..., 65504.
- Assert `frame_done` fires exactly once per frame.

**`tb_mcu_block_transfer.vhd`** (update):
- Remove the 32-cycle snoop stimulus loop.
- Instead, drive `pixel_buf_data` with a 1024-bit test pattern directly, then pulse
  `pixel_buf_valid`.
- Test is shorter and more focused on burst correctness.

**Integration: `tb_frame_processor.vhd`** (new, optional):
- End-to-end test with Avalon memory model.
- Assert that DDR3 writes land at the correct addresses for two consecutive warps
  (offsets 0 and 32).

---

### Implementation Order

1. Modify `mcu_block_transfer.vhd` (Step 1) and update its testbench. Verify it still
   passes with the new flat-buffer interface.

2. Create `warp_unit.vhd` (Step 2) by copying `processor.vhd` and making the changes
   described above. Run `tb_warp_unit.vhd` to verify the FSM and pixel buffer logic
   are correct in isolation.

3. Create `warp_scheduler.vhd` (Step 3). Run `tb_warp_scheduler.vhd` to verify the
   offset sequencing and frame_done signal.

4. Create `frame_processor.vhd` (Step 4). Run the full integration testbench and/or
   the existing automated tool-chain tests to verify end-to-end correctness.

5. Delete `processor.vhd` and `memory_unit.vhd` once integration tests pass.

---

### Extension Path to Latency Hiding (Change 3)

The architecture above scales to N concurrent warps with these additions only:

1. **N instances of `warp_unit`**, each with its own VRF, PRF, IFU state, and pixel buffer.

2. **`warp_scheduler` extended:** `warp_start` and `warp_halted` become
   `std_logic_vector(N-1 downto 0)`; `warp_offset` becomes an array. The scheduler
   dispatches a new warp to any idle slot without waiting for in-flight warps to finish.

3. **Shared IMEM with time-multiplexed fetch:** Each warp_unit drives its own
   `imem_addr`. With a single-port BRAM, the scheduler stalls all but one warp's
   FETCH_ADDR per cycle (simple round-robin arbitration). Alternatively, instantiate
   a true dual-port BRAM for N=2.

4. **MCU extended to service N pixel buffers:** Add a priority encoder or round-robin
   arbiter that picks the first `pixel_buf_valid(i) = '1'` warp, drives that warp's
   buffer through the burst, then asserts `mem_stall(i) = '0'` for that warp only.
   Other warps can continue executing concurrently.

5. **No changes** to `mcu_block_transfer` internal logic, `avm_burst_bridge`,
   `instruction_fetch_unit`, `instruction_decoder`, `instruction_issue`, or
   `execution_unit`.

---

## Change 3: In-Core Warp Scheduling (Latency Hiding)

See the Extension Path section above for the incremental steps. The main additional
work beyond the extension path is:
- Arbitration logic in the MCU (or a new `mcu_arbiter.vhd` wrapper)
- IMEM fetch arbitration (if single-port BRAM)
- Verification testbench that proves two warps overlap: Warp 0 enters MEM_WAIT while
  Warp 1 is in EXEC_WAIT
