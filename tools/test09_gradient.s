# test09_gradient.s
# WIDTH: 64
# HEIGHT: 16
# Draw an RGB gradient image using dynamic WIDTH and HEIGHT uniforms.
#   R (X) = floor((x / WIDTH) * 255)
#   G (Y) = floor((y / HEIGHT) * 255)
#   B (Z) = 0
#   A (W) = 255 (fully opaque)
#
# Architecture note: Because there is no IDIV instruction, this shader uses
# the FPU to compute `y = floor(tid / width)`. This is a fantastic integration
# test, proving that the ALU and FPU pipelines are perfectly latency-matched 
# and can trade data back and forth without stalling!

THREAD_ID v0.xyzw        # v0 = global_tid
WIDTH v1.xyzw            # v1 = width
HEIGHT v2.xyzw           # v2 = height

# -------------------------------------------------------------------------
# 1. Convert integers to floats to prepare for division
# -------------------------------------------------------------------------
I2F v3.xyzw, v0          # v3 = float(tid)
I2F v4.xyzw, v1          # v4 = float(width)
I2F v2.xyzw, v2          # v2 = float(height) (Overwrites int height!)

# -------------------------------------------------------------------------
# 2. Compute y_int = floor(tid / width)
# Note: 1.0/width is perfectly exact for power-of-2 widths in IEEE 754.
# -------------------------------------------------------------------------
FRCP v5.xyzw, v4         # v5 = 1.0f / width
FMUL v3.xyzw, v3, v5     # v3 = float(tid) * (1.0f / width) (Overwrites float tid)
F2I  v6.xyzw, v3         # v6 = y_int 

# -------------------------------------------------------------------------
# 3. Compute x_int = tid - (y_int * width)
# -------------------------------------------------------------------------
IMUL v7.xyzw, v6, v1     # v7 = y_int * width
ISUB v0.xyzw, v0, v7     # v0 = x_int (Overwrites tid!)

# -------------------------------------------------------------------------
# 4. Normalize x and y to [0.0, 1.0] ranges
# -------------------------------------------------------------------------
I2F  v0.xyzw, v0         # v0 = float(x_int) (Overwrites x_int)
I2F  v6.xyzw, v6         # v6 = float(y_int) (Overwrites y_int)
FRCP v2.xyzw, v2         # v2 = 1.0f / height (Overwrites float height)

FMUL v0.xyzw, v0, v5     # v0 = x_norm = float(x) * (1.0f / width)
FMUL v6.xyzw, v6, v2     # v6 = y_norm = float(y) * (1.0f / height)

# -------------------------------------------------------------------------
# 5. Scale to [0, 255] and pack into final RGBA vector
# -------------------------------------------------------------------------
# Re-use v1 for the 255.0f constant (width is no longer needed)
LDI_LO v1.xyzw, 0x0000
LDI_HI v1.xyzw, 0x437F   # v1 = 255.0f

# Re-use v2 for the output vector (1.0f / height is no longer needed)
# Initialize output vector with Alpha=255.0 (W component)
LDI_LO v2.xyzw, 0x0000
LDI_HI v2.xyzw, 0x437F   # v2 = {255.0f, 255.0f, 255.0f, 255.0f}

FMUL v2.x, v0, v1        # v2.X (Red)   = x_norm * 255.0f
FMUL v2.y, v6, v1        # v2.Y (Green) = y_norm * 255.0f
FSUB v2.z, v1, v1        # v2.Z (Blue)  = 255.0f - 255.0f = 0.0f

# -------------------------------------------------------------------------
# 6. Writeback to Pixel Buffer
# -------------------------------------------------------------------------
F2I v2.xyzw, v2          # Convert RGBA floats to integers: {255, 0, G, R} (Overwrites float vector)
FLUSH                    # Drain pipeline before pixel snoop reads VRF
RETURN v2                # End shader, write pixel buffer
