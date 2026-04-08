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
#   pixel 0: "00000000 00000000 00000000 00000000"
#   pixel 1: "00000004 00000004 00000004 00000004"
#   pixel 2: "00000008 00000008 00000008 00000008"

THREAD_ID v0.xyzw        # v0 = global thread id (warp_offset + lane)
LDI_LO v1.xyzw, 0x0004  # v1 = 4 (shift amount for *16 byte offset)
IADD v3.xyzw, v0, v0    # v3 = 2*tid  [no FLUSH: 32-cycle sep > 29-cycle latency]
ISHL v2.xyzw, v0, v1    # v2 = 16*tid [no FLUSH: same reason]
IADD v4.xyzw, v3, v3    # v4 = 4*tid  [no FLUSH: chained dep on v3]
FLUSH                    # drain pipeline before MCU reads VRF
STORE v4, 0x0000(v2)    # store 4*tid to framebuffer
FLUSH
RETURN
