# test16_mandelbrot.s
# WIDTH: 32
# HEIGHT: 32
#
# Mandelbrot fractal — animated zoom into Seahorse Valley.
#
# Zoom animation (from original shader):
#   zoom = exp(sin(t * 0.4) * 4.5 + 3.5)
#        = exp2((sin(t * 0.4) * 4.5 + 3.5) * log2(e))
#        = exp2(sin(t*0.4) * 6.49213 + 5.04943)
#   Range: ~0.37 (zoomed out) ↔ ~2981 (deep zoom)
#
# Coordinate mapping:
#   c = (-0.7453, 0.1127) + uv / zoom     (Seahorse Valley center)
#
# We actually compute inv_zoom = 1/zoom = exp2(sin(t*0.4) * -6.49213 - 5.04943)
# directly (avoids an FDIV and gives one multiply for c = center + uv*inv_zoom).
#
# z0 = (0, 0); iterate z <- z*z + c for 17 fixed steps (no early exit).
# zx/zy are clamped to [-1000, 1000] each step to prevent IEEE 754 overflow.
#
# Coloring by final |z|^2 (simple in/out — unchanged from original):
#   escape = clamp((|z|^2 - 4) * 0.5, 0, 1)
#     0 → clearly in-set  (blue)
#     1 → clearly escaped (orange)
#
# Register map (stable during the 17-iteration loop body):
#   v0  clamp_min = -1000
#   v1  scratch (reloaded with each constant)
#   v2  time t  (loaded once; currently unused after zoom, but reserved)
#   v3  scratch (coloring: G channel)
#   v4  scratch (coloring: B channel) / float_width (during UV)
#   v5  output pixel RGBA / float_height (during UV)
#   v6  float_tid → float_x → uv.x  (freed after uv*inv_zoom)
#   v7  float_y   → uv.y             (freed after uv*inv_zoom)
#   v8  scratch (y*width, min(W,H), sin arg, inv_zoom)
#   v9  cx  (constant during iterations)
#   v10 cy  (constant during iterations)
#   v11 zx  (updated each iteration)
#   v12 zy  (updated each iteration)
#   v13 new_zx temp
#   v14 new_zy / coloring scratch / constants
#   v15 clamp_max = +1000

# ---- Thread → pixel row / column ----
THREAD_ID v6.xyzw
WIDTH     v3.xyzw
HEIGHT    v5.xyzw

I2F v6.xyzw, v6             # float(tid)
I2F v4.xyzw, v3             # float_width
I2F v5.xyzw, v5             # float_height

# y = floor(tid / width)
FDIV v7.xyzw, v6, v4
LDI_LO v1.xyzw, low(0.4999)
LDI_HI v1.xyzw, high(0.4999)
FSUB v7.xyzw, v7, v1
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

# ---- Time-based inverse zoom ----
# inv_zoom = exp2(sin(t*0.4) * -6.49213 + -5.04943)
TIME v2.xyzw                 # v2 = t

LDI_LO v1.xyzw, low(0.4)
LDI_HI v1.xyzw, high(0.4)
FMUL v8.xyzw, v2, v1         # t * 0.4
SIN  v8.xyzw, v8             # sin(t*0.4)

# Build v14 = -5.04943 (the FMADD accumulator seed).
LDI_LO v14.xyzw, low(-5.04943)
LDI_HI v14.xyzw, high(-5.04943)

# FMADD v14, v8, v1  →  v14 = sin * -6.49213 + -5.04943
LDI_LO v1.xyzw, low(-6.49213)
LDI_HI v1.xyzw, high(-6.49213)
FMADD v14.xyzw, v8, v1

FEXP2 v8.xyzw, v14           # v8 = inv_zoom

# ---- c = center + uv * inv_zoom  (via FMADD) ----
# cx = uv.x * inv_zoom + (-0.7453)
LDI_LO v9.xyzw, low(-0.7453)
LDI_HI v9.xyzw, high(-0.7453)     # v9 = -0.7453 (FMADD seed)
FMADD v9.xyzw, v6, v8             # v9 = uv.x*inv_zoom - 0.7453 = cx

# cy = uv.y * inv_zoom + 0.1127
LDI_LO v10.xyzw, low(0.1127)
LDI_HI v10.xyzw, high(0.1127)     # v10 = 0.1127 (FMADD seed)
FMADD v10.xyzw, v7, v8            # v10 = uv.y*inv_zoom + 0.1127 = cy

# z = (0, 0); clamp constants
FSUB v11.xyzw, v9, v9             # zx = 0
FSUB v12.xyzw, v9, v9             # zy = 0
LDI_LO v15.xyzw, low(1000.0)
LDI_HI v15.xyzw, high(1000.0)     # clamp_max = +1000
FSUB v0.xyzw, v11, v15            # clamp_min = 0 - 1000 = -1000

# ================================================================
# 17 Mandelbrot iterations — unrolled (11 instructions each = 187).
#
#   FMUL v13, v11, v11    zx^2
#   FMUL v14, v12, v12    zy^2
#   FSUB v13, v13, v14    zx^2 - zy^2
#   FADD v13, v13, v9     new_zx = zx^2 - zy^2 + cx
#   FMUL v14, v11, v12    zx * zy
#   FADD v14, v14, v14    2 * zx * zy
#   FADD v14, v14, v10    new_zy = 2*zx*zy + cy
#   FMIN v11, v13, v15    zx = min(new_zx, +1000)
#   FMAX v11, v11, v0     zx = max(zx,    -1000)
#   FMIN v12, v14, v15    zy = min(new_zy, +1000)
#   FMAX v12, v12, v0     zy = max(zy,    -1000)
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
# Coloring by final |z|^2 (unchanged from original).
# escape = clamp((|z|^2 - 4) * 0.5, 0, 1)
#   |z|^2 ≤ 4: escape ≈ 0  (in-set, blue)
#   |z|^2 ≥ 6: escape = 1  (clearly escaped, orange)
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

FSUB v0.xyzw, v9, v9        # v0 = 0.0  (v0's clamp_min role is done)
LDI_LO v1.xyzw, low(1.0)
LDI_HI v1.xyzw, high(1.0)
FMAX v13.xyzw, v13, v0      # clamp >= 0
FMIN v13.xyzw, v13, v1      # clamp <= 1  →  escape factor

FSUB v14.xyzw, v1, v13      # hit = 1 - escape

# Colour channels — write directly into the correct v5 components
# (framebuffer layout: X=B, Y=G, Z=R, W=A). All four lanes of v13/v14
# carry the same escape/hit value, so masked FMULs give per-channel scalars.
LDI_LO v1.xyzw, low(255.0)
LDI_HI v1.xyzw, high(255.0)
FADD v5.xyzw, v1, v0        # v5 = 255 in all lanes (A pre-fill via .w)
FMUL v5.z, v13, v1          # R = escape * 255
FMUL v5.x, v14, v1          # B = hit    * 255

LDI_LO v1.xyzw, low(100.0)
LDI_HI v1.xyzw, high(100.0)
FMUL v5.y, v13, v1          # G = escape * 100
                             # v5.w still = 255 (A)

F2I  v5.xyzw, v5
FLUSH
RETURN v5
