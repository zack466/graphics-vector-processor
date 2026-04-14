# test12_ray_march.s
# WIDTH: 64
# HEIGHT: 64
#
# Ray-marches a sphere at (0,0,3) from a pinhole camera at the origin.
# 5 unrolled SDF sphere march steps; colors by the final marched distance t:
#   close hit  (t ~2-3)  => warm orange
#   grazing hit (t ~4-6) => amber
#   miss        (t >7)   => dark blue sky
#
# New instructions vs earlier tests:
#   FADD  — step accumulation (t += sdf)
#   FSQRT — |q| for SDF
#   DOT   — |q|^2 = q·q without a separate multiply loop
#   FMAX  — branchless clamp-low
#   FMIN  — branchless clamp-high
#   MOV   — splat a single component into all four (for component packing)
#
# Register map (stable through march body):
#   v8  ray direction normalized: (nx, ny, nz, 0)
#   v9  march parameter t (scalar, all 4 same)
#   v10 current point  p = dir * t  (temp, 3-wide)
#   v11 q = p - center             (temp, 3-wide; last iteration kept for normal)
#   v12 sphere center: (0, 0, 3, 0)
#   v13 SDF value per step         (|q| - radius)
#   v14 0.0 constant
#   v15 255.0 constant
#   v0  sphere radius (1.0)
# After march, v1-v7 are free for coloring temporaries.

# ---- Compute per-pixel UV coords ----
THREAD_ID v0.xyzw
WIDTH     v1.xyzw
HEIGHT    v2.xyzw

I2F v3.xyzw, v0              # float(tid)
I2F v4.xyzw, v1              # float(width)
I2F v5.xyzw, v2              # float(height)

FDIV v6.xyzw, v3, v4         # tid / width
F2I  v6.xyzw, v6             # floor -> row y
I2F  v6.xyzw, v6             # float_y

FMUL v7.xyzw, v6, v4         # y * width
FSUB v7.xyzw, v3, v7         # float_x

FDIV v7.xyzw, v7, v4         # x_norm [0,1]
FDIV v6.xyzw, v6, v5         # y_norm [0,1]

# ---- Load basic constants ----
LDI_LO v14.xyzw, low(0.0)
LDI_HI v14.xyzw, high(0.0)

LDI_LO v15.xyzw, low(255.0)
LDI_HI v15.xyzw, high(255.0)

# ---- Map to centered UV in [-1,1] ----
LDI_LO v0.xyzw, low(2.0)
LDI_HI v0.xyzw, high(2.0)
LDI_LO v13.xyzw, low(1.0)
LDI_HI v13.xyzw, high(1.0)

FMUL v7.xyzw, v7, v0         # x_norm * 2
FMUL v6.xyzw, v6, v0         # y_norm * 2
FSUB v7.xyzw, v7, v13        # u = x_norm*2 - 1  (per-thread col coord)
FSUB v6.xyzw, v6, v13        # v = y_norm*2 - 1  (per-thread row coord)

# ---- Build unnormalized ray direction (u, v, 1.5, 0) in v8 ----
# Focal length 1.5 gives ~67 degree vertical FOV.
MOV v8.xyzw, v14             # v8 = {0, 0, 0, 0}
MOV v8.x,    v7              # v8.x = u
MOV v8.y,    v6              # v8.y = v
LDI_LO v8.z, low(1.5)
LDI_HI v8.z, high(1.5)       # v8.z = 1.5

# ---- Normalize ray direction: v8 /= |v8| ----
DOT   v13.xyzw, v8, v8       # |dir|^2 (w=0 contributes nothing)
FSQRT v13.xyzw, v13          # |dir|
FDIV  v8.xyzw,  v8, v13      # v8 = (nx, ny, nz, 0)  normalized

# ---- Init march ----
# Sphere center stored as (0, 0, 3, 0) via component-masked writes
LDI_LO v12.xyzw, low(0.0)
LDI_HI v12.xyzw, high(0.0)   # v12 = {0, 0, 0, 0}
LDI_LO v12.z,    low(3.0)
LDI_HI v12.z,    high(3.0)   # v12.z = 3.0  → v12 = (0, 0, 3, 0)

LDI_LO v0.xyzw,  low(1.0)
LDI_HI v0.xyzw,  high(1.0)   # v0 = sphere radius = 1.0

LDI_LO v9.xyzw,  low(0.0)
LDI_HI v9.xyzw,  high(0.0)   # v9 = t = 0.0  (march distance)

# ================================================================
# SDF March — 5 unrolled steps
# Each step:
#   p   = dir * t
#   q   = p - sphere_center
#   d   = sqrt(q·q) - radius
#   t  += d
# ================================================================

# ---- Step 1 ----
FMUL v10.xyzw, v8, v9        # p = dir * t
FSUB v11.xyzw, v10, v12      # q = p - center
DOT  v13.xyzw, v11, v11      # |q|^2
FSQRT v13.xyzw, v13          # |q|
FSUB v13.xyzw, v13, v0       # sdf = |q| - radius
FADD v9.xyzw,  v9, v13       # t += sdf

# ---- Step 2 ----
FMUL v10.xyzw, v8, v9
FSUB v11.xyzw, v10, v12
DOT  v13.xyzw, v11, v11
FSQRT v13.xyzw, v13
FSUB v13.xyzw, v13, v0
FADD v9.xyzw,  v9, v13

# ---- Step 3 ----
FMUL v10.xyzw, v8, v9
FSUB v11.xyzw, v10, v12
DOT  v13.xyzw, v11, v11
FSQRT v13.xyzw, v13
FSUB v13.xyzw, v13, v0
FADD v9.xyzw,  v9, v13

# ---- Step 4 ----
FMUL v10.xyzw, v8, v9
FSUB v11.xyzw, v10, v12
DOT  v13.xyzw, v11, v11
FSQRT v13.xyzw, v13
FSUB v13.xyzw, v13, v0
FADD v9.xyzw,  v9, v13

# ---- Step 5 ----
FMUL v10.xyzw, v8, v9
FSUB v11.xyzw, v10, v12
DOT  v13.xyzw, v11, v11
FSQRT v13.xyzw, v13
FSUB v13.xyzw, v13, v0
FADD v9.xyzw,  v9, v13

# ================================================================
# Coloring: sharp hit / miss based on final SDF value (v13).
#
# After 5 march steps a hit ray has converged to sdf ≈ 0;
# a miss ray has sdf >> 0.  We use a tight linear ramp with
# K=20 (transition band = 1/K = 0.05 world units) to produce
# a near-binary step:
#
#   sdf_pos   = max(v13, 0)          -- treat inside as "hit"
#   hit       = clamp(1 - sdf_pos*K, 0, 1)
#   miss      = 1 - hit
#   R = hit * 220 + miss *  20
#   G = hit * 100 + miss *  30
#   B = hit *  30 + miss * 180
# ================================================================

LDI_LO v1.xyzw, low(20.0)
LDI_HI v1.xyzw, high(20.0)     # v1 = K = 20.0
LDI_LO v2.xyzw, low(1.0)
LDI_HI v2.xyzw, high(1.0)      # v2 = 1.0

FMAX v13.xyzw, v13, v14         # sdf_pos = max(sdf, 0)
FMUL v3.xyzw,  v13, v1          # sdf_pos * K
FSUB v3.xyzw,  v2,  v3          # 1 - sdf_pos*K
FMAX v3.xyzw,  v3,  v14         # clamp >= 0
FMIN v3.xyzw,  v3,  v2          # clamp <= 1  -> v3 = hit factor

FSUB v4.xyzw, v2, v3            # v4 = miss factor

# R = hit * 220 + miss * 20
LDI_LO v5.xyzw, low(220.0)
LDI_HI v5.xyzw, high(220.0)
FMUL v6.xyzw, v3, v5            # hit * 220
LDI_LO v5.xyzw, low(20.0)
LDI_HI v5.xyzw, high(20.0)
FMUL v7.xyzw, v4, v5            # miss * 20
FADD v11.x, v6, v7              # R

# G = hit * 100 + miss * 30
LDI_LO v5.xyzw, low(100.0)
LDI_HI v5.xyzw, high(100.0)
FMUL v6.xyzw, v3, v5
LDI_LO v5.xyzw, low(30.0)
LDI_HI v5.xyzw, high(30.0)
FMUL v7.xyzw, v4, v5
FADD v11.y, v6, v7              # G

# B = hit * 30 + miss * 180
LDI_LO v5.xyzw, low(30.0)
LDI_HI v5.xyzw, high(30.0)
FMUL v6.xyzw, v3, v5
LDI_LO v5.xyzw, low(180.0)
LDI_HI v5.xyzw, high(180.0)
FMUL v7.xyzw, v4, v5
FADD v11.z, v6, v7              # B

# A = 255
MOV v11.w, v15

# ---- Write pixel ----
F2I  v11.xyzw, v11
FLUSH
RETURN v11
