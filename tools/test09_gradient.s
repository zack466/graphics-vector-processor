# test09_gradient.s
# WIDTH: 128
# HEIGHT: 64
# Draw an RGB gradient image using dynamic WIDTH and HEIGHT uniforms.
#   R (X) = floor((x / WIDTH) * 255)
#   G (Y) = floor((y / HEIGHT) * 255)
#   B (Z) = 0
#   A (W) = 255 (fully opaque)

THREAD_ID v0.xyzw        # v0 = global_tid
WIDTH v1.xyzw            # v1 = width
HEIGHT v2.xyzw           # v2 = height

# -------------------------------------------------------------------------
# 1. Convert integers to floats to prepare for division
# -------------------------------------------------------------------------
I2F v3.xyzw, v0          # v3 = float(tid)
I2F v4.xyzw, v1          # v4 = float(width)
I2F v5.xyzw, v2          # v5 = float(height)

# -------------------------------------------------------------------------
# 2. Compute float_y = floor(tid / width)
# We must use F2I briefly just to truncate the fraction, then go right 
# back to float space.
# -------------------------------------------------------------------------
FDIV v7.xyzw, v3, v4     # v7 = float(tid) / float_width
F2I  v7.xyzw, v7         # v7 = int_y (Truncate fraction)
I2F  v7.xyzw, v7         # v7 = float_y (Back to float space)

# -------------------------------------------------------------------------
# 3. Compute float_x = tid - (y * width) entirely in floats
# -------------------------------------------------------------------------
FMUL v8.xyzw, v7, v4     # v8 = float_y * float_width
FSUB v8.xyzw, v3, v8     # v8 = float_x = float_tid - (float_y * float_width)

# -------------------------------------------------------------------------
# 4. Normalize x and y to [0.0, 1.0] ranges
# -------------------------------------------------------------------------
FDIV v8.xyzw, v8, v4     # v8 = x_norm = float_x / float_width
FDIV v9.xyzw, v7, v5     # v9 = y_norm = float_y / float_height

# -------------------------------------------------------------------------
# 5. Scale to [0, 255] and pack into final RGBA vector
# -------------------------------------------------------------------------
LDI_LO v10.xyzw, low(255.0)
LDI_HI v10.xyzw, high(255.0)  # v10 = 255.0f

# Initialize output vector with Alpha=255.0 (W component)
LDI_LO v11.xyzw, low(255.0)
LDI_HI v11.xyzw, high(255.0)  # v11 = {255.0f, 255.0f, 255.0f, 255.0f}

FMUL v11.x, v8, v10      # v11.X (Red)   = x_norm * 255.0f
FMUL v11.y, v9, v10      # v11.Y (Green) = y_norm * 255.0f
FSUB v11.z, v10, v10     # v11.Z (Blue)  = 255.0f - 255.0f = 0.0f

# -------------------------------------------------------------------------
# 6. Writeback to Pixel Buffer
# -------------------------------------------------------------------------
F2I v11.xyzw, v11        # Convert RGBA floats to integers: {255, 0, G, R}
FLUSH                    # Drain pipeline before pixel snoop reads VRF
RETURN v11               # End shader, write pixel buffer
