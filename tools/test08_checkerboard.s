# test08_checkerboard.s
# Draw a 32x32 checkerboard pattern using branchless ALU computation.
#
# Each warp covers 32 pixels in one row. The testbench runs 32 warps with
# warp_offset = 0, 32, 64, ..., 992, so:
#   x = global_tid & 0x1F  (column: 0..31)
#   y = global_tid >> 5    (row:    0..31)
#
# Color rule: white (255) if (x + y) is even, black (0) if (x + y) is odd.
#
# Since RETURN reg cannot occur within a divergent path (and STORE has been
# removed), the checkerboard is computed branchlessly:
#
#   parity    = (x + y) & 1      (0=even=white, 1=odd=black)
#   not_parity = 1 - parity      (1=white, 0=black)
#   pixel     = not_parity * 255 (255=white, 0=black)

THREAD_ID v0.xyzw        # v0 = global_tid = warp_offset + lane
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (column mask)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (row shift amount)
IAND v4.xyzw, v0, v1    # v4 = x = global_tid & 0x1F  (column 0..31)
ISHR v6.xyzw, v0, v3    # v6 = y = global_tid >> 5     (row 0..31)
IADD v7.xyzw, v4, v6    # v7 = x + y
LDI_LO v8.xyzw, 0x0001  # v8 = 1
IAND v9.xyzw, v7, v8    # v9 = (x+y) & 1 = parity (0=white, 1=black)
ISUB v10.xyzw, v8, v9   # v10 = 1 - parity (1=white, 0=black)
LDI_LO v11.xyzw, 0x00FF # v11 = 255
IMUL v12.xyzw, v10, v11 # v12 = pixel value (255=white, 0=black)
FLUSH
RETURN v12
