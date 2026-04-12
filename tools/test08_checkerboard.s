# test08_checkerboard.s
# Draw a 32x32 checkerboard pattern.
#
# Each warp covers 32 pixels in one row. The testbench runs 32 warps with
# warp_offset = 0, 32, 64, ..., 992, so:
#   x = global_tid & 0x1F  (column: 0..31)
#   y = global_tid >> 5    (row:    0..31)
#
# Color rule: white if (x + y) is even, black if (x + y) is odd.
#   white = 255, black = 0
#
# Architecture note: ALU/FPU/IMM run for ALL threads regardless of exec_mask.
# STORE masks Avalon byte enables based on exec_mask, so each path's STORE 
# only writes to its active threads' pixel locations.

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
# Both divergent paths already STOREd their pixels with exec_mask byte enables.
# BREAK halts the warp without a second pixel write (which would overwrite the
# divergent STOREs with the wrong value from the last-executed path's register).
reconv:
FLUSH
BREAK
