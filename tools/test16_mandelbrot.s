# test16_mandelbrot.s
# WIDTH: 32
# HEIGHT: 32
#
# Mandelbrot fractal — static full-set view, 17 fixed iterations.
#
# Coordinate mapping (shows the complete Mandelbrot set with some margin):
#   cx = uv.x * 1.75 - 0.75     x ∈ [-2.5, 1.0]
#   cy = uv.y * 1.25             y ∈ [-1.25, 1.25]
#
# z0 = (0, 0); iterate z <- z*z + c for 17 fixed steps (no early exit).
# zx/zy are clamped to [-1000, 1000] each step to prevent IEEE 754 overflow.
#
# The animated zoom from the original shader is omitted here; at the
# depth it produces (zoom ≈ 191 at t=1s) all pixels land inside the set
# and 17 iterations cannot resolve any boundary → all-blue output.
# A static wide view clearly shows both interior and exterior.
#
# Coloring by final |z|^2:
#   escape = clamp((|z|^2 - 4) * 0.5, 0, 1)
#            → 0 for clearly in-set (|z|^2 ≤ 4)
#            → 1 for clearly escaped (|z|^2 ≥ 6)
#   R = escape * 255   (orange/yellow exterior)
#   G = escape * 100
#   B = hit   * 255   (blue interior)   where hit = 1 - escape
#   A = 255
#
# IMEM budget: 32 (setup) + 17×11 (iterations) + 29 (coloring) = 248 / 256
#
# Register map (stable during the 17-iteration loop body):
#   v0  clamp_min = -1000
#   v1  scratch (reloaded with each constant)
#   v2  scratch (coloring: R channel)
#   v3  scratch (coloring: G channel)
#   v4  float_width  (freed after UV)
#   v5  float_height (freed after UV)
#   v6  float_tid → float_x → uv.x  (freed after cx)
#   v7  float_y   → uv.y             (freed after cy)
#   v8  scratch    (y*width, min(W,H))
#   v9  cx  (constant during iterations)
#   v10 cy  (constant during iterations)
#   v11 zx  (updated each iteration)
#   v12 zy  (updated each iteration)
#   v13 new_zx temp
#   v14 new_zy / coloring scratch
#   v15 clamp_max = +1000

# ---- Thread → pixel row / column ----
THREAD_ID v6.xyzw
WIDTH     v2.xyzw
HEIGHT    v5.xyzw

I2F v6.xyzw, v6             # float(tid)
I2F v4.xyzw, v2             # float_width
I2F v5.xyzw, v5             # float_height

# y = floor(tid / width)
FDIV v7.xyzw, v6, v4
F2I  v7.xyzw, v7
I2F  v7.xyzw, v7             # float_y

# x = float_tid - float_y * float_width
FMUL v8.xyzw, v7, v4
FSUB v6.xyzw, v6, v8        # float_x

# uv = (2*coord - resolution) / min(W, H)
FMIN v8.xyzw, v4, v5        # min(W, H)
FADD v6.xyzw, v6, v6        # 2*x
FSUB v6.xyzw, v6, v4        # 2*x - W
FDIV v6.xyzw, v6, v8        # uv.x
FADD v7.xyzw, v7, v7        # 2*y
FSUB v7.xyzw, v7, v5        # 2*y - H
FDIV v7.xyzw, v7, v8        # uv.y

# cx = uv.x * 1.75 - 0.75   (x spans [-2.5, 1.0], covers full set)
LDI_LO v1.xyzw, low(1.75)
LDI_HI v1.xyzw, high(1.75)
FMUL v9.xyzw, v6, v1
LDI_LO v1.xyzw, low(-0.75)
LDI_HI v1.xyzw, high(-0.75)
FADD v9.xyzw, v9, v1        # v9 = cx

# cy = uv.y * 1.25           (y spans [-1.25, 1.25], covers full set)
LDI_LO v1.xyzw, low(1.25)
LDI_HI v1.xyzw, high(1.25)
FMUL v10.xyzw, v7, v1       # v10 = cy

# z = (0, 0); clamp constants
FSUB v11.xyzw, v9, v9       # zx = 0  (cx - cx)
FSUB v12.xyzw, v9, v9       # zy = 0
LDI_LO v15.xyzw, low(1000.0)
LDI_HI v15.xyzw, high(1000.0)  # clamp_max
FSUB v0.xyzw, v11, v15      # clamp_min = 0 - 1000 = -1000

# ================================================================
# 17 Mandelbrot iterations — unrolled, fixed iteration count.
#
# Per-iteration body (11 instructions):
#   FMUL v13, v11, v11    zx^2
#   FMUL v14, v12, v12    zy^2
#   FSUB v13, v13, v14    zx^2 - zy^2
#   FADD v13, v13, v9     new_zx = zx^2 - zy^2 + cx
#   FMUL v14, v11, v12    zx * zy
#   FADD v14, v14, v14    2 * zx * zy
#   FADD v14, v14, v10    new_zy = 2*zx*zy + cy
#   FMIN v11, v13, v15    zx = clamp(new_zx, *, +1000)
#   FMAX v11, v11, v0     zx = clamp(zx,    -1000, *)
#   FMIN v12, v14, v15    zy = clamp(new_zy, *, +1000)
#   FMAX v12, v12, v0     zy = clamp(zy,    -1000, *)
# ================================================================

# ---- Iteration 1 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 2 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 3 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 4 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 5 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 6 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 7 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 8 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 9 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 10 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 11 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 12 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 13 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 14 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 15 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 16 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ---- Iteration 17 ----
FMUL v13.xyzw, v11, v11
FMUL v14.xyzw, v12, v12
FSUB v13.xyzw, v13, v14
FADD v13.xyzw, v13, v9
FMUL v14.xyzw, v11, v12
FADD v14.xyzw, v14, v14
FADD v14.xyzw, v14, v10
FMIN v11.xyzw, v13, v15
FMAX v11.xyzw, v11, v0
FMIN v12.xyzw, v14, v15
FMAX v12.xyzw, v12, v0

# ================================================================
# Coloring by final |z|^2.
# escape = clamp((|z|^2 - 4) * 0.5, 0, 1)
#   |z|^2 ≤ 4: escape ≈ 0  (in-set, blue)
#   |z|^2 ≥ 6: escape = 1  (clearly escaped, orange)
# Use v9 (cx, constant) as a zero source: cx - cx = 0.
# ================================================================
FMUL v13.xyzw, v11, v11     # zx^2
FMUL v14.xyzw, v12, v12     # zy^2
FADD v13.xyzw, v13, v14     # |z|^2

LDI_LO v1.xyzw, low(4.0)
LDI_HI v1.xyzw, high(4.0)
FSUB v13.xyzw, v13, v1      # |z|^2 - 4

LDI_LO v1.xyzw, low(0.5)
LDI_HI v1.xyzw, high(0.5)
FMUL v13.xyzw, v13, v1      # * 0.5

FSUB v14.xyzw, v9, v9       # 0.0  (cx - cx)
LDI_LO v1.xyzw, low(1.0)
LDI_HI v1.xyzw, high(1.0)
FMAX v13.xyzw, v13, v14     # clamp >= 0
FMIN v13.xyzw, v13, v1      # clamp <= 1  →  escape factor

FSUB v14.xyzw, v1, v13      # hit = 1 - escape

# Colour channels; pack into v5.
LDI_LO v1.xyzw, low(255.0)
LDI_HI v1.xyzw, high(255.0)
FMUL v2.xyzw, v13, v1       # R = escape * 255
FMUL v4.xyzw, v14, v1       # B = hit   * 255
MOV  v5.xyzw, v1            # v5 = 255 in all lanes  (A pre-fill)

LDI_LO v1.xyzw, low(100.0)
LDI_HI v1.xyzw, high(100.0)
FMUL v3.xyzw, v13, v1       # G = escape * 100

MOV v5.x, v2                 # R
MOV v5.y, v3                 # G
MOV v5.z, v4                 # B
                              # v5.w = 255 (A, from MOV v5.xyzw above)

F2I  v5.xyzw, v5
FLUSH
RETURN v5
