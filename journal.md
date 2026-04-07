# TODO
- fix vector reg tests (module was edited to ensure usage of M10K nodes for synthesis)
- test that thread id instruction actually works

# Agent changes
Claude made the following changes:

  ---
  Thread ID instruction (OP_THREAD_ID)

  processor_constants_pkg.vhd
  - Added CSR_ADDR_WARP_OFFSET = "110" — new R/W CSR for the warp base thread offset
  - Added OP_THREAD_ID = "001110" in the ALU opcode section

  processor.vhd
  - Added csr_warp_offset signal with reset + CSR write handler for CSR_ADDR_WARP_OFFSET
  - Added csr_warp_offset to the CSR read mux
  - Routes csr_warp_offset and iss_thread_id into the execution unit as new ports

  execution_unit.vhd
  - New ports: warp_offset_in (32-bit) and thread_id_in (5-bit)
  - s1_thread_id captures thread_id_in in the stage-1 latch (cycles through 0–31 with the barrel scheduler)
  - Both passed through to the ALU lane

  alu_lane.vhd
  - New ports: thread_id and warp_offset
  - OP_THREAD_ID case: raw_res <= unsigned(warp_offset) + resize(unsigned(thread_id), 32)
  - No decoder changes needed — OP_THREAD_ID in INST_TYPE_ALU already falls through to the vrf_we='1' branch correctly

  Usage: Write the warp's pixel base index to CSR_ADDR_WARP_OFFSET, then OP_THREAD_ID rd, mask in ALU type gives each thread rd = base + lane_index.

  ---
  MCU regression fix

  Root cause: d3c3942 ("modifications for fitting") tried a JIT VRF-read approach for stores (to eliminate the 32×128-bit thread_data array) but had two bugs: (1) the load path in DISPATCH was
  left as a stub comment — causing loads to hang forever, and (2) HANDLE_WRITE read reg_read_data only 1 cycle after setting reg_read_addr, but the VRF has 2-cycle synchronous read latency (both
  MCU and VRF are clocked processes), so every word after the first was stale.

  Fix: Restored the original DISPATCH load path and reverted HANDLE_WRITE to the thread_data approach. The JIT optimization would require either a 2-cycle pre-fetch pipeline or a stall state per
  word, making it slower than the GATHER_DATA approach it was meant to replace — worth revisiting separately if ALM budget is tight.

  Makefile: Added --stop-time=100ms to RUNFLAGS so any future infinite loops are caught immediately instead of hanging indefinitely.
