# test15_checkerboard.s
# WIDTH: 64
# HEIGHT: 64
#
# Time-animated moving checkerboard (adapted from GLSL).
# uv   = (2*coord - resolution) / min(W, H)  -- aspect-corrected
# grid = uv * 5 + (2*t, 0)                   -- horizontal scroll
# c    = floor(grid)                           -- integer cell coordinates
# is_even = (c.x + c.y) mod 2
# color_byte = 51  if is_even == 0  (dark  0.2 * 255)
#            = 204 if is_even == 1  (light 0.8 * 255)
# → branchless: color_byte = 51 + 153 * is_even
#
# floor for potentially negative grid values: add 1000 (even constant) before
# F2I so the truncate-toward-zero equals floor. Parity is preserved because
# 1000 is even: (floor(x+1000) + floor(y+1000)) mod 2 == (floor(x) + floor(y)) mod 2.
#
# is_even computed via float mod-2:
#   half  = sum / 2
#   floor_half = I2F(F2I(half))       -- positive, so trunc == floor
#   is_even = sum - 2 * floor_half    -- yields 0.0 or 1.0
#
# New instructions vs earlier tests: none.
#
# Register map:
#   v0  scratch (constants)
#   v1  float_width
#   v2  float_height
#   v3  t_seconds
#   v4  min(W, H)
#   v5  float_x → uv.x → grid.x → cx_f
#   v6  float_y → uv.y → grid.y → cy_f
#   v7  float(tid)
#   v8  checker_sum → is_even
#   v9  scratch (half_sum, 2*floor_half)
#   v10 output pixel (R, G, B, A)

THREAD_ID v7.xyzw
WIDTH     v1.xyzw
HEIGHT    v2.xyzw
TIME      v3.xyzw

I2F v7.xyzw, v7             # float(tid)
I2F v1.xyzw, v1             # float_width
I2F v2.xyzw, v2             # float_height
I2F v3.xyzw, v3             # float(time_ms)

# t = time_ms / 1000
LDI_LO v0.xyzw, low(1000.0)
LDI_HI v0.xyzw, high(1000.0)
FDIV v3.xyzw, v3, v0        # v3 = t_seconds

# y = floor(tid / width)
FDIV v6.xyzw, v7, v1
F2I  v6.xyzw, v6
I2F  v6.xyzw, v6             # float_y

# x = float_tid - float_y * float_width
FMUL v0.xyzw, v6, v1
FSUB v5.xyzw, v7, v0        # float_x

# uv.x = (2*x - W) / min(W, H)
FMIN v4.xyzw, v1, v2        # min(W, H)
FADD v5.xyzw, v5, v5        # 2*x
FSUB v5.xyzw, v5, v1        # 2*x - W
FDIV v5.xyzw, v5, v4        # uv.x

# uv.y = (2*y - H) / min(W, H)
FADD v6.xyzw, v6, v6        # 2*y
FSUB v6.xyzw, v6, v2        # 2*y - H
FDIV v6.xyzw, v6, v4        # uv.y

# grid = uv * 5;  grid.x += 2*t  (horizontal scroll)
LDI_LO v0.xyzw, low(5.0)
LDI_HI v0.xyzw, high(5.0)
FMUL v5.xyzw, v5, v0        # uv.x * 5
FMUL v6.xyzw, v6, v0        # uv.y * 5
FADD v5.xyzw, v5, v3        # grid.x + t
FADD v5.xyzw, v5, v3        # grid.x + 2*t  (add t twice)

# Add 1000 (even) to guarantee positivity, then floor via F2I
LDI_LO v0.xyzw, low(1000.0)
LDI_HI v0.xyzw, high(1000.0)
FADD v5.xyzw, v5, v0        # grid.x + 1000
FADD v6.xyzw, v6, v0        # grid.y + 1000
F2I  v5.xyzw, v5            # floor cx (int)
F2I  v6.xyzw, v6            # floor cy (int)
I2F  v5.xyzw, v5            # cx as float
I2F  v6.xyzw, v6            # cy as float

# checker_sum = cx + cy
FADD v8.xyzw, v5, v6

# is_even = checker_sum mod 2  (0.0 or 1.0)
#   half      = checker_sum / 2
#   floor_half = F2I(half) → I2F   (positive: trunc == floor)
#   is_even   = checker_sum - 2 * floor_half
LDI_LO v0.xyzw, low(2.0)
LDI_HI v0.xyzw, high(2.0)
FDIV v9.xyzw, v8, v0        # half_sum
F2I  v9.xyzw, v9
I2F  v9.xyzw, v9             # float floor(half_sum)
FMUL v9.xyzw, v9, v0        # 2 * floor_half
FSUB v8.xyzw, v8, v9        # is_even = 0.0 or 1.0

# color_byte = 51 + 153 * is_even  →  51 (dark) or 204 (light)
LDI_LO v0.xyzw, low(153.0)
LDI_HI v0.xyzw, high(153.0)
FMUL v8.xyzw, v8, v0
LDI_LO v0.xyzw, low(51.0)
LDI_HI v0.xyzw, high(51.0)
FADD v8.xyzw, v8, v0        # v8 = color in [0,255]

# Pack output: R=G=B=color_byte, A=255
LDI_LO v10.xyzw, low(255.0)
LDI_HI v10.xyzw, high(255.0)
MOV v10.x, v8               # R
MOV v10.y, v8               # G
MOV v10.z, v8               # B
                             # v10.w = 255 (A, already set by LDI above)

F2I  v10.xyzw, v10
FLUSH
RETURN v10
