# test09_gradient.s
# Draw a 32x32 RGB gradient image.
#   R (X component) = floor((x / 32) * 255)   (increases left to right, 0..247)
#   G (Y component) = floor((y / 32) * 255)   (increases top to bottom, 0..247)
#   B (Z component) = 0
#   A (W component) = 255 (fully opaque)
#
# Architecture note: ALU instructions (IAND, ISHR) are scalar — they compute
# on the X component only and broadcast the result to all four components.
# This is fine here because THREAD_ID and LDI both produce the same value in
# all four components, so the broadcast result is identical to a full-vector op.

THREAD_ID v0.xyzw        # v0 = global_tid = warp_offset + lane (same in all 4 components)
LDI_LO v1.xyzw, 0x001F  # v1 = 0x1F (column mask)
LDI_LO v3.xyzw, 0x0005  # v3 = 5 (row shift amount)
LDI_LO v10.xyzw, 0x0000
LDI_HI v10.xyzw, 0x3D00 # v10 = 0x3D000000 = 0.03125f = 1/32
LDI_LO v13.xyzw, 0x0000
LDI_HI v13.xyzw, 0x437F # v13 = 0x437F0000 = 255.0f

IAND v4.xyzw, v0, v1    # v4 = x = tid & 0x1F  (column 0..31, same in all components)
ISHR v6.xyzw, v0, v3    # v6 = y = tid >> 5     (row 0..31, same in all components)
I2F v8.xyzw, v4         # v8 = float(x) in all 4 components
I2F v9.xyzw, v6         # v9 = float(y) in all 4 components
FMUL v11.xyzw, v8, v10  # v11 = x/32 in all 4 components
FMUL v12.xyzw, v9, v10  # v12 = y/32 in all 4 components

# Initialize v14 = 255.0f in all components.
# This sets the alpha channel (W). X and Y will be overwritten below; Z by FSUB.
LDI_LO v14.xyzw, 0x0000
LDI_HI v14.xyzw, 0x437F # v14 = {255.0f, 255.0f, 255.0f, 255.0f}

FMUL v14.x, v11, v13    # v14.X = R = (x/32) * 255.0f
FMUL v14.y, v12, v13    # v14.Y = G = (y/32) * 255.0f
FSUB v14.z, v13, v13    # v14.Z = 255.0f - 255.0f = 0.0f  (Blue = 0)
# v14.W stays 255.0f from LDI above (Alpha = 255)

F2I v15.xyzw, v14       # convert floats to integers: {255, 0, G_int, R_int}
FLUSH                    # drain pipeline before MCU reads VRF
STORE v15, 0x0000       # store packed RGBA pixels for all 32 threads
FLUSH
RETURN
