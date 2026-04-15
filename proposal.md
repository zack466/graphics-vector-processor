# Proposal Phase 1: Single-Warp Latency Hiding (Immediate Next Step)

Before scaling to multiple warps, latency hiding can be implemented for the current single-warp design. The goal is to allow the warp to begin computing the next thread block immediately after rendering its pixels, overlapping the next block's compute time with the memory controller's (MCU) DDR3 burst transfer.

## 1. Architectural Overview
Instead of the warp halting and waiting in a `MEM_WAIT` state until the MCU finishes writing to memory, the system will use a `clean/dirty` synchronization flag. 
- The M10K pixel buffer will be extracted from the `warp_unit` and instantiated at the top-level `frame_processor`.
- A top-level `pixel_buf_dirty` flag will track whether the buffer is currently being drained by the MCU.
- The warp can instantly transition to `HALTED` after filling the buffer, allowing the `warp_scheduler` to dispatch the next block while the MCU runs in the background.
- If the warp finishes computing the *new* block very quickly and decodes `OP_RETURN` while `pixel_buf_dirty` is still `'1'`, it will simply stall in the `DECODE` state until the MCU finishes.

## 2. Warp Unit Modifications (`src/warp_unit.vhd`)
- **Remove M10K Buffer:** Delete the internal `pixel_buffer_ram` instantiation.
- **New Output Ports:** Add synchronous write ports to push packed pixels up to the top level: `pixel_wr_en`, `pixel_wr_addr` (5-bit), and `pixel_wr_data` (32-bit).
- **New Input Port:** Add `pixel_buf_dirty` (1-bit).
- **FSM Updates:**
  - Remove the `MEM_WAIT` state.
  - In `DECODE`, when parsing `OP_RETURN`: check `pixel_buf_dirty`. If `'1'`, stall the FSM (do not assert `iss_valid_in`). If `'0'`, assert `iss_valid_in` and proceed to `EXEC_WAIT`.
  - In `EXEC_WAIT`, when the 32nd thread is successfully written to the top-level buffer, pulse `pixel_buf_valid` for one cycle and transition the FSM directly to `HALTED`.

## 3. Frame Processor Top-Level (`src/frame_processor.vhd`)
- **Instantiate Pixel Buffer:** Move the `pixel_buffer_ram` here. Connect the warp's `pixel_wr_*` ports to its write interface, and the MCU's `pixel_rd_*` ports to its read interface.
- **Clean/Dirty Flag Management:**
  - Introduce `signal pixel_buf_dirty : std_logic := '0';`
  - When `warp_pixel_valid` pulses (from the warp), set `pixel_buf_dirty <= '1'`.
  - When `mcu_pixel_done` pulses (from the MCU), clear `pixel_buf_dirty <= '0'`.
  - Route `pixel_buf_dirty` back into the `warp_unit` to control its stall logic.

## 4. MCU Modifications (`src/mcu_block_transfer.vhd`)
- **Remove Stall Signal:** Remove the `mem_stall` output, as the warp no longer blocks on it.
- **Completion Pulse:** Add a `pixel_buf_done` output port. Pulse this high for exactly one clock cycle when transitioning from `STORE_BURST` back to `IDLE` (after the 8th and final Avalon beat is accepted).

## 5. Warp Scheduler (`src/warp_scheduler.vhd`)
- **No changes needed!** Because the `warp_unit` transitions to `HALTED` instantly upon filling the buffer, the scheduler will naturally see `warp_halted='1'` and dispatch the next block on the very next cycle.


# Proposal Phase 2: Integrating Multiple Warp Units for Asynchronous Pixel Rendering

This document outlines a detailed architectural plan for scaling the `frame_processor` to support multiple concurrent warp units, implementing latency-hiding by overlapping compute with memory transfers.

## 1. Architectural Overview
The core idea is to decouple the completion of a warp's computational workload from the physical DDR3 memory transfer of its rendered pixels. 

By giving each warp unit its own dedicated M10K pixel buffer and a local `pixel_buffer_busy` state flag, a warp can completely offload its pixel data and immediately return to the scheduler to be assigned a new block of pixels. While the newly scheduled warp begins fetching and computing its next thread block, the central memory controller (MCU) asynchronously arbitrates, reads the filled pixel buffer, and bursts it to memory. 

The only required synchronization is if the warp finishes computing its *new* block and reaches the final `OP_RETURN` instruction before the MCU has finished draining its *previous* buffer. In this rare case, the warp will momentarily stall until the memory transfer completes.

## 2. Warp Unit Modifications (`src/warp_unit.vhd`)

**Decoupling the Memory Wait State:**
- Add a new internal register: `signal pixel_buffer_busy : std_logic := '0';`
- Remove the `MEM_WAIT` FSM state. Currently, after `OP_RETURN` finishes writing to the pixel buffer, the FSM sits in `MEM_WAIT` until `mem_stall` deasserts.
- **New Behavior:** When the 32nd thread of `OP_RETURN` writes to the pixel buffer, set `pixel_buffer_busy <= '1'` and transition the FSM **directly to `HALTED`**. This allows the `warp_scheduler` to instantly detect that the warp is free and dispatch a new pixel block to it.

**Implementing the Pipeline Stall:**
- The warp will start executing the new block while `pixel_buffer_busy` is still `'1'`.
- If the warp finishes the new block and decodes the `OP_RETURN` instruction again, it must check `pixel_buffer_busy`.
- If `pixel_buffer_busy = '1'`, the FSM will stall in the `DECODE` state (or just prior to issuing threads to `EXEC_WAIT`), preventing the new pixels from overwriting the M10K RAM.
- Once the MCU finishes its burst, it will pulse a new input port `pixel_buf_done`. This clears `pixel_buffer_busy <= '0'`, allowing the warp to proceed with executing `OP_RETURN`.

**MCU Interface Changes:**
- Remove the `mem_stall` input.
- Add a `pixel_buf_done : in std_logic` pulse.
- Change `pixel_buf_valid` to be a level signal directly driven by `pixel_buffer_busy` (or a standalone request flag cleared by `pixel_buf_done`).

## 3. MCU Block Transfer Modifications (`src/mcu_block_transfer.vhd`)

The MCU must evolve from a 1:1 pipeline into a 1:N arbitrated controller.

- **Port Array Upgrades:**
  - `pixel_buf_valid` becomes an array of `NUM_WARPS` bits.
  - `base_addr` becomes an array of `ADDR_WIDTH` vectors.
  - `pixel_rd_data` becomes an array of `DATA_WIDTH` vectors.
  - Add an output `pixel_buf_done` as an array of `NUM_WARPS` bits.

- **Arbiter Logic:**
  - Introduce a `selected_warp` integer register.
  - In the `IDLE` state, implement a Round-Robin or Priority arbiter that scans the `pixel_buf_valid` array.
  - When an active buffer is found, latch its index into `selected_warp`, latch the corresponding `base_addr(selected_warp)`, and transition to `STORE_CMD`.

- **Multiplexing the M10K Interface:**
  - Use `selected_warp` to route `pixel_rd_en` and `pixel_rd_addr` exclusively to the active warp unit.
  - Multiplex the incoming `pixel_rd_data(selected_warp)` into the Avalon TX data channel.

- **Completion Handshake:**
  - Upon successfully transferring the 8th beat in `STORE_BURST`, pulse `pixel_buf_done(selected_warp) <= '1'` for exactly one clock cycle before returning to `IDLE`.

## 4. Warp Scheduler Modifications (`src/warp_scheduler.vhd`)

The scheduler must dispatch blocks to any available warp to keep the pipeline saturated.

- Add a `NUM_WARPS` generic.
- Convert `warp_start`, `warp_offset`, and `warp_halted` to arrays sized by `NUM_WARPS`.
- **FSM Upgrades:**
  - Change the `WAIT_HALT` and `DISPATCH` logic into a continuous scanning loop.
  - In the dispatch evaluation state, check if `next_offset < total_pixels`. If true, scan the `warp_halted` array for the first index `i` where `warp_halted(i) = '1'`.
  - Assert `warp_start(i)` for 1 cycle and assign `warp_offset(i) <= next_offset`. Advance `next_offset` by `WARP_SIZE`.
  - The scheduler should be able to dispatch warps back-to-back on consecutive clock cycles if multiple warps are halted.
  - To transition to `DONE`, the scheduler must verify that `next_offset >= total_pixels` **and** that all bits in `warp_halted` are `'1'` (meaning all dispatched blocks have entirely finished execution).

## 5. Frame Processor Top-Level (`src/frame_processor.vhd`)

- Add `NUM_WARPS` to the `frame_processor` generic list.
- Define custom VHDL package array types (e.g., `addr_array_t`, `data_array_t`) to cleanly wire the multi-warp interfaces.
- **Warp Instantiation Loop:** Use a `for i in 0 to NUM_WARPS - 1 generate` block to instantiate the multiple `warp_unit` entities.

**Crucial Detail regarding Instruction Memory (`u_imem`):**
Because M10K block RAMs on Cyclone V support a maximum of 2 independent read ports, a single shared `instruction_memory` entity cannot feed 4 or 8 independent warp units executing at different Program Counters. 
To resolve this without introducing cache-stalls, the `instruction_memory` instantiation **must be moved inside the generate loop**. Every warp unit gets its own physical copy of the instruction memory (which takes extremely few M10K blocks given typical shader sizes). During host programming, the `prog_we`, `prog_wr_addr`, and `prog_wr_data` signals are simply broadcast to all replicated memory instances simultaneously, guaranteeing they all hold identical shader code.
