# test04_alu_chain.s
# Test dependent ALU chain WITHOUT FLUSH between arithmetic instructions.
#
# The barrel scheduler issues one instruction per thread per cycle (32 threads).
# Each same-thread instruction is naturally separated by 32 cycles, which
# exceeds the ~29-cycle ALU writeback latency. No FLUSH is needed between
# dependent ALU instructions.
#
# Program (no FLUSH between any arithmetic ops):
#   v0 = THREAD_ID (global tid)
#   v3 = IADD(v0, v0) = 2*tid         [depends on v0, no FLUSH needed]
#   v2 = ISHL(v0, 4)  = 16*tid        [depends on v0 and v1, no FLUSH needed]
#   v4 = IADD(v3, v3) = 4*tid         [chained, depends on v3, no FLUSH needed]
#
# Expected: pixel N = {W=4N, Z=4N, Y=4N, X=4N} as raw integers
#   pixel 0: "FF000000"
#   pixel 1: "FF040404"
#   pixel 2: "FF080808"

THREAD_ID v0.xyzw        # v0 = global thread id (warp_offset + lane)
IADD v3.xyzw, v0, v0    # v3 = 2*tid  [no FLUSH: 32-cycle sep > 29-cycle latency]
IADD v4.xyzw, v3, v3    # v4 = 4*tid  [no FLUSH: chained dep on v3]
LDI_LO v4.w, 0x00FF      # Make alpha opaque
FLUSH                    # drain pipeline before MCU reads VRF
RETURN v4               # write packed pixels from v4 to framebuffer and halt
