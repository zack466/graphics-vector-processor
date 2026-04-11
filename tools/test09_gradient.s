# test09_gradient.s
# Draw a 32x32 RGB gradient image.
#   R (X component) = x / 32   (increases left to right)
#   G (Y component) = y / 32   (increases top to bottom)
#   B (Z component) = 0.0f
#   A (W component) = 255.0f   (fully opaque)
#
# Memory layout (from runner.py + dump format):
#   parts[3] = X = R,  parts[2] = Y = G,  parts[1] = Z = B,  parts[0] = W = A
#
# Approach:
#   - Compute x = global_tid & 0x1F,  y = global_tid >> 5
#   - Convert to float, scale by 1/32 = 0x3D000000 = 0.03125f
#   - Use per-component write mask to assemble: v14 = {R, G, 0, 255.0f}
#   - Z never written -> stays 0 (VRF initialized to 0)
#   - Convert floats to integers (0-255) using F2I
#   - No FLUSH needed between any arithmetic instructions (barrel scheduler provides
#     32-cycle natural separation, FPU_MAX_LATENCY = 28 cycles)

THREAD_ID v0.xyzw        # v0 = global_tid
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (mask for lower 5 bits)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (shift for >>5)
LDI_LO v10.xyzw, 0x0000
LDI_HI v10.xyzw, 0x3D00 # v10 = 0x3D000000 = 0.03125f = 1/32
LDI_LO v13.xyzw, 0x0000
LDI_HI v13.xyzw, 0x437F # v13 = 0x437F0000 = 255.0f (alpha constant and scale factor)
IAND v4.xyzw, v0, v1    # v4 = x (column, 0..31)
ISHR v6.xyzw, v0, v3    # v6 = y (row, 0..31)
I2F v8.xyzw, v4         # v8 = float(x) in all 4 components
I2F v9.xyzw, v6         # v9 = float(y) in all 4 components
FMUL v11.xyzw, v8, v10  # v11 = x/32 in all 4 components (R value)
FMUL v12.xyzw, v9, v10  # v12 = y/32 in all 4 components (G value)
# Assemble output vector v14 = {X=R*255, Y=G*255, Z=0, W=255.0f}
# Z is left as 0 (VRF initialized to 0, never written)
LDI_LO v15.xyzw, 0x0000
LDI_HI v15.xyzw, 0x437F # v15 = 255.0f in all components
LDI_LO v16.xyzw, 0x0000 # v16 = 0.0f
FMUL v14.x, v11, v13    # v14.X = (x/32) * 255.0f = R  [write X only]
FMUL v14.y, v12, v13    # v14.Y = (y/32) * 255.0f = G  [write Y only]
IADD v14.z, v16, v16    # v14.Z = 0.0f
IADD v14.w, v15, v16    # v14.W = 255.0f
F2I v15.xyzw, v14       # Convert float RGBA to integer (0-255)
FLUSH                    # drain pipeline before MCU reads VRF
STORE v15, 0x0000       # store {W=255, Z=0, Y=G, X=R}
FLUSH
RETURN
