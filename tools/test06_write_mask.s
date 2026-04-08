# test06_write_mask.s
# Test ALU per-component write mask.
#
# The write mask field (bits[25:22]) controls which of the X/Y/Z/W components
# are written to the VRF. Unwritten components retain their previous value.
# Since VRF is initialized to 0, unwritten components = 0.
#
# Program:
#   v4.xy = IADD(v0, v0) = 2*tid  [write mask: X and Y only]
#   v4.z  = 0 (never written, stays at VRF init value of 0)
#   v4.w  = 0 (never written)
#
# Expected: pixel N = {W=0, Z=0, Y=2N, X=2N}
#   (memory dump format is W Z Y X per line)
#   pixel 0: "00000000 00000000 00000000 00000000"
#   pixel 1: "00000000 00000000 00000002 00000002"
#   pixel 2: "00000000 00000000 00000004 00000004"

THREAD_ID v0.xyzw        # v0 = global thread id
LDI_LO v1.xyzw, 0x0004  # v1 = 4 (for byte offset)
ISHL v2.xyzw, v0, v1    # v2 = 16*tid (byte address)
IADD v4.xy, v0, v0      # v4.xy = 2*tid, v4.zw = 0 (write mask: X and Y only)
FLUSH                    # drain pipeline before MCU reads VRF
STORE v4, 0x0000(v2)    # store {W=0, Z=0, Y=2*tid, X=2*tid}
FLUSH
RETURN
