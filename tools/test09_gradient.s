# test09_gradient.s
# Draw a 32x32 RGB gradient image.
#   R (X component) = x / 32   (increases left to right)
#   G (Y component) = y / 32   (increases top to bottom)
#   B (Z component) = 0.0f
#   A (W component) = 1.0f     (fully opaque)
#
# Memory layout (from runner.py + dump format):
#   parts[3] = X = R,  parts[2] = Y = G,  parts[1] = Z = B,  parts[0] = W = A
#
# Approach:
#   - Compute x = global_tid & 0x1F,  y = global_tid >> 5
#   - Convert to float, scale by 1/32 = 0x3D000000 = 0.03125f
#   - Use per-component write mask to assemble: v14 = {R, G, 0, 1.0f}
#   - Z never written -> stays 0 (VRF initialized to 0)
#   - No FLUSH needed between any arithmetic instructions (barrel scheduler provides
#     32-cycle natural separation, FPU_MAX_LATENCY = 28 cycles)

THREAD_ID v0.xyzw        # v0 = global_tid
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (mask for lower 5 bits)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (shift for >>5)
LDI_LO v5.xyzw, 0x0004  # v5 = 4 (shift for byte addr)
LDI_LO v10.xyzw, 0x0000
LDI_HI v10.xyzw, 0x3D00 # v10 = 0x3D000000 = 0.03125f = 1/32
LDI_LO v13.xyzw, 0x0000
LDI_HI v13.xyzw, 0x3F80 # v13 = 0x3F800000 = 1.0f (alpha constant)
IAND v4.xyzw, v0, v1    # v4 = x (column, 0..31)
ISHR v6.xyzw, v0, v3    # v6 = y (row, 0..31)
ISHL v2.xyzw, v0, v5    # v2 = global_tid * 16 (byte address)
I2F v8.xyzw, v4         # v8 = float(x) in all 4 components
I2F v9.xyzw, v6         # v9 = float(y) in all 4 components
FMUL v11.xyzw, v8, v10  # v11 = x/32 in all 4 components (R value)
FMUL v12.xyzw, v9, v10  # v12 = y/32 in all 4 components (G value)
# Assemble output vector v14 = {X=R, Y=G, Z=0, W=1.0f}
# Z is left as 0 (VRF initialized to 0, never written)
FMUL v14.x, v11, v13    # v14.X = R * 1.0f = R  [write X only]
FMUL v14.y, v12, v13    # v14.Y = G * 1.0f = G  [write Y only]
FMUL v14.w, v13, v13    # v14.W = 1.0f * 1.0f = 1.0f [write W only]
FLUSH                    # drain pipeline before MCU reads VRF
STORE v14, 0x0000(v2)   # store {W=1.0, Z=0, Y=G, X=R}
FLUSH
RETURN
