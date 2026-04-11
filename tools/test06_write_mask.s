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
# Expected: pixel N = {W=255, Z=0, Y=2N, X=2N}
#   (memory dump format is W Z Y X per line)
#   pixel 0: "FF000000"
#   pixel 1: "FF000202"
#   pixel 2: "FF000404"

THREAD_ID v0.xyzw        # v0 = global thread id
LDI_LO v4.xyzw, 0x0000   # clear v4
FLUSH                    # settle v4 before modifying
IADD v4.xy, v0, v0      # v4.xy = 2*tid, v4.zw = 0 (write mask: X and Y only)
LDI_LO v4.w, 0x00FF      # Make alpha opaque
FLUSH                    # drain pipeline before MCU reads VRF
STORE v4, 0x0000        # store {W=255, Z=0, Y=2*tid, X=2*tid}
FLUSH
RETURN
