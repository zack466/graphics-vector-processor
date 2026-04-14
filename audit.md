# VHDL Design Audit Report

This document contains a file-by-file audit of the VHDL designs in the `src/` directory, identifying potential bugs, issues, synthesis problems, efficiency concerns, and complexity considerations.

## `src/processor_constants_pkg.vhd`
- **Audit:** The constants are well documented and comprehensive.
- **Issues:**
  - `SWIZ_X` is defined as `"100"` (which is 4). However, the documentation in `vector_types_pkg.vhd` mentions that codes 0-3 are for X/Y/Z/W. This is a minor documentation mismatch.
  - The reliance on padding all execution units to `FPU_MAX_LATENCY` (28 cycles) simplifies the writeback collision logic but wastes cycles for faster integer and logical operations. This is an architectural trade-off but functioning as designed.

## `src/vector_types.vhd`
- **Audit:** Clean and standard types definition.
- **Issues:**
  - Minor comment discrepancy regarding `swizzle_sel_t` valid range as mentioned above.

## `src/swizzle_network.vhd`
- **Audit:** Combinational multiplexer with predicate logic injection.
- **Issues / Complexity:**
  - Standard VHDL-1993 sensitivity lists are used correctly, but VHDL-2008 `process(all)` would be cleaner as recommended in the project instructions.
  - Fully combinational matrix might have a slightly long routing delay if placed far from the VRF, but should meet timing easily on Cyclone V for a 128-bit bus if not operating at extreme frequencies.

## `src/vector_reg_file.vhd`
- **Audit:** M10K optimized quad-replicated 128-bit register file.
- **Issues / Bugs:**
  - **Confusing Signal Naming:** `rd_addr_A` and `rd_data_A` are used for Port A *writes* (rd meaning Register Destination), whereas `rd_addr_B` and `rd_data_B` are used for Port B *reads* (rd meaning Read Data). This is extremely confusing.
  - **FIFO Overflow:** The collision buffer uses a 64-entry FIFO but does not have an overflow check or full-flag output to stall the MCU if it exceeds capacity. If the MCU bursts more than 64 writes while the FPU pipeline is consistently writing, data will be lost.
  - **M10K Inference:** The split of RAMs into four independent elements x, y, z, w per replica correctly infers 16 separate RAM blocks, efficiently implementing bit-masking without read-modify-write.

## `src/predicate_reg_file.vhd`
- **Audit:** Distributed PRF for warp execution masks.
- **Issues / Efficiency:**
  - **Synchronous Reset on RAM:** The inclusion of `if reset = '1' then prf <= (others => "0000");` forces the synthesis tool to infer this memory as individual Flip-Flops (ALMs) rather than distributed MLAB RAM blocks, because MLABs do not support a mass clear. This consumes ~2048 registers. For 512x4 this is acceptable but not fully optimal.
  - **IFU 32-wide Async Read:** The synthesis tool will successfully optimize the 32 reads across threads into 32 separate 4-to-1 multiplexers because `i * 16` is constant per loop iteration, so the massive MUX complexity is avoided.
  - `ifu_pred_sel` is 2-bit, meaning only the first 4 predicate registers can be used for branch conditions, limiting PRF usage.

## `src/instruction_memory.vhd`
- **Audit:** M10K optimized memory with registered read address.
- **Issues:** None. The single-cycle pipeline matches M10K block inference guidelines perfectly.

## `src/pixel_buffer_ram.vhd`
- **Audit:** Parallel mixed-width RAM (4x32 write, 128 read).
- **Issues:**
  - Standard dual-port M10K block RAM is correctly inferred using `rd_addr_reg`. Even though it effectively acts as a read-address clock-enable when `rd_en` is active, Quartus handles this optimally without inferring logic blocks.

## `src/instruction_fetch_unit.vhd`
- **Audit:** Complex SIMT divergence stack and PC management.
- **Issues / Bugs:**
  - **Hardcoded WARP_SIZE Assumptions:** The conditions `all_taken`, `none_taken`, and `is_divergent` evaluate mask comparisons against a hardcoded `x"00000000"`. If the generic `WARP_SIZE` is altered from its default of 32, this code will cause a VHDL type/length mismatch simulation and synthesis failure. It should use `(others => '0')`.
  - **Stack Overflow / Out-of-Bounds:** Both the divergence stack (`sp`) and call stack (`csp`) lack bounds checking when pushing or popping. If an overflow occurs, integer variables defined with ranges `0 to STACK_DEPTH` will cause VHDL simulation to halt with a constraint error.

## `src/instruction_decoder.vhd`
- **Audit:** Pure combinational decode stage.
- **Issues:**
  - Clean and efficient implementation. The usage of variables with initial defaults guarantees latch-free synthesis and correctly maps opcodes to functional records.

## `src/fpu_lane.vhd`
- **Audit:** Parallel FPU pipeline multiplexer.
- **Issues:**
  - Flawless latency matching and synchronization. The combinational bypass at the output defensively handles the case where an IP's latency exactly matches `FPU_MAX_LATENCY`, bypassing the final shift register correctly.
  - The `LAT_FRSQRT` IP core appears to be missing in the IP instantiations even though its constant is defined in the constants package and dictates `FPU_MAX_LATENCY`.

## `src/alu_lane.vhd`
- **Audit:** Combinational integer ALU with delay padding.
- **Issues / Complexity:**
  - **Area Inefficiency:** Creating a 28-stage shift register for a 32-bit result plus control bits consumes approximately 896 flip-flops per ALU lane. With 32 logical threads in a warp, if instantiated physically (though this design time-multiplexes threads over a single physical lane), it would be huge. However, since the `warp_unit` sweeps threads over 1 physical ALU lane, it only requires 1x 896 FFs, which is easily absorbed by Altera AltShift_Taps / MLABs.

## `src/writeback_controller.vhd`
- **Audit:** Writeback metadata shift register.
- **Issues:** None. Clean implementation correctly delaying control signals to match arithmetic latency.

## `src/vector_reduction_unit.vhd`
- **Audit:** 4-component float reduction unit.
- **Issues / Bugs:**
  - **Latent Bug:** The pipeline delay loop uses the condition `if LAT_REDUCT = i - 1 then res_pipe(i) <= raw_result;`. If the IP core latency `LAT_REDUCT` is ever increased to equal `FPU_MAX_LATENCY`, the injection point `i` evaluates to `FPU_MAX_LATENCY + 1`, which is outside the loop bounds (`1 to FPU_MAX_LATENCY`). `raw_result` will never be captured, and the output will always be zero. It lacks the combinational output bypass block that was correctly implemented in `fpu_lane.vhd`.

## `src/execution_unit.vhd`
- **Audit:** Top-level execution pipeline wiring.
- **Issues:**
  - Clean wiring. The FLUSH token tracking is correct, holding `flush_active_out` until the 28-stage pipeline fully clears out.
  - The ALU comparison scalar output is replicated correctly across all 4 vector components for the PRF writeback using the vector write mask.

## `src/warp_scheduler.vhd` & `src/warp_unit.vhd`
- **Audit:** Frame-level FSM and single-warp instantiation.
- **Issues / Bugs:**
  - Correct decoupled architecture utilizing a multi-cycle state machine (`HALTED` -> `FETCH` -> `DECODE` -> `EXEC_WAIT` -> `ADVANCE_PC`).
  - No major bugs discovered in the FSM or pipeline control paths. The `warp_scheduler` correctly waits for `warp_halted` to fall to `0` before waiting for it to rise again to avoid a race condition.

## `src/mcu_block_transfer.vhd`
- **Audit:** Avalon memory control pipeline for block transfers.
- **Issues:**
  - Logic correctly manages the 1-cycle M10K read latency. When `tx_ready` is low (Avalon waitrequest), the MCU properly drops `rd_en` to freeze the `pixel_buffer_ram` output, ensuring no pixel data is dropped.

## `src/avm_burst_bridge.vhd`
- **Audit:** Avalon-MM burst master translation layer.
- **Issues:**
  - Fully compliant Avalon-MM Master design. The bridge correctly latches the address and burst count on the first cycle and holds them steady across the burst, accurately mirroring `avm_waitrequest` back to `tx_ready`.

## `src/frame_processor.vhd`
- **Audit:** Top-level wiring component.
- **Issues:**
  - Syntactically correct and structurally sound. Wiring aligns well with Qsys IP core requirements.

## `src/sync_fifo.vhd`
- **Audit:** General purpose synchronous FIFO (M10K).
- **Issues:**
  - BRAM inference is correctly designed via the `tail` pointer acting as a read-enable-gated address register with a combinational output. This seamlessly infers Altera Simple Dual-Port RAM.

**Overall Project Complexity & Synthesizability:**
The architecture relies heavily on Cyclone V M10K block RAM inferences (VRF, PRF, Pixel Buffer, Instruction Memory, and FIFOs). Careful attention has been paid to the synchronous read requirements to ensure M10K blocks are correctly generated. However, the PRF's synchronous reset prevents M10K inference, forcing it into logic elements. Additionally, the ALU pipeline padding utilizes a large amount of shift registers; while Altera AltShift_Taps can optimize this, it remains an area-heavy approach. Finally, the missing `FRSQRT` IP core combined with `LAT_REDUCT` == `FPU_MAX_LATENCY` combinational bypass bugs are the most critical functional flaws that will need addressing.
## `tools/assembler.py`
- **Audit:** Basic script to compile pseudo-assembly to hex.
- **Issues / Complexity:**
  - `parse_imm_value` has a flaw: it accurately parses float literals via struct packing, but assumes integers are correctly parsed by `int(val_str, 0)`. The masking `& 0xFFFFFFFF` prevents python's arbitrarily large integers, but relying on float conversions for literals with decimal points uses standard Python floats, which are IEEE 754 Double Precision underneath. Converting them to 32-bit floats via struct is correct, but doesn't handle all edge cases of floating point precision flawlessly.
  - The `RETURN reg` instruction correctly overrides the `rs1` mapping on the CPU end, but in the assembler it uses `(reg << 4)` mapping to the `rd` field (`[7:4]`). Since `warp_unit` overrides `rs1_addr_local <= ifu_inst_out(7 downto 4);` for RETURN, this successfully wires together, but is non-standard.
  - No handling of negative values for un-suffixed integer parsing beyond `& 0xFFFFF` (only lower 16 bits used by IMM instructions anyway).

## `tools/runner.py`
- **Audit:** Automated test runner managing `make build` and image rendering.
- **Issues:**
  - Robust script that dynamically parses Width/Height from `.s` comments, runs ghdl, and converts Hex dumps to PNGs.
  - Correctly implements double-buffering logic for QSys testing, extracting multiple frames.

## VHDL Testbenches (`src/tb_*.vhd`)
- **Audit:** Complete suite of VHDL testbenches for all execution units.
- **Issues / Synchronization Bugs:**
  - **Violation of Design Principles:** The project states: "Always obey strict synchronous design principles. Testbench code should synchronize itself using `wait until rising_edge(clk)` and should never have arbitrary waits like `wait until 1 ns`."
  - Testbenches extensively use absolute timing constructs. For example, `tb_avm.vhd`, `tb_avm_sim_memory.vhd`, and `tb_frame_processor_automated.vhd` repeatedly use `wait for 50 ns;`, `wait for 20 ns;`, `wait for 130 ns;`, etc.
  - Instead of `wait for 50 ns; wait until rising_edge(clk);`, the correct pattern is a loop: `for i in 1 to 5 loop wait until rising_edge(clk); end loop;`.
  - While using `clk <= not clk after CLK_PERIOD / 2;` is standard for generating the clock itself, arbitrary combinational wait delays should be minimized.
  - In `tb_frame_processor_automated.vhd`, there is a hardcoded loop `while loop_count < 100000 loop`, acting as a timeout. If the test takes longer, it forcefully asserts `report "TEST PASSED"` and finishes. This means if the test hangs due to an actual bug, it will incorrectly report passing just because it hit the timeout!
  - **Memory Dump Checker:** `tb_full_execution_integration.vhd` and `tb_frame_processor.vhd` both rely heavily on dumping memory to files via `std.textio`. This is generally fine for GHDL, but could fail in hardware-in-the-loop tests.

