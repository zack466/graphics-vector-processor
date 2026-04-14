# test11_sdf_circles.s
# WIDTH: 64
# HEIGHT: 64
#
# Draws a glowing SDF circle using DOT product for squared distance,
# FSQRT for the actual distance, and FMIN/FMAX for branchless clamping.
# Produces: orange/red ring glow, green fill inside, blue-sky outside.
#
# New instructions vs earlier tests:
#   DOT  — 4-component dot product (squared distance from origin)
#   FSQRT — square root for Euclidean distance
#   FADD  — float add (offset)
#   FMIN  — branchless clamp-high
#   FMAX  — branchless clamp-low
#   MOV   — component-masked copy for packing different scalars into one register
#
# Register map:
#   v0  tid (int)
#   v1  width (int) -> later reused as a float constant
#   v2  height (int)
#   v3  float(tid)
#   v4  float(width)
#   v5  float(height)
#   v6  float_y -> y_norm -> v (centered [-1,1])
#   v7  float_x -> x_norm -> u (centered [-1,1])
#   v8  2D point (u, v, 0, 0) for DOT
#   v9  distance / sdf = dist - radius
#   v10 temp (|sdf|, per-channel intermediates)
#   v11 output pixel (R, G, B, A) built component-by-component
#   v12 2.0
#   v13 1.0
#   v14 0.0
#   v15 255.0

# ---- Thread → pixel (x, y) ----
THREAD_ID v0.xyzw
WIDTH     v1.xyzw
HEIGHT    v2.xyzw

I2F v3.xyzw, v0              # float(tid)
I2F v4.xyzw, v1              # float(width)
I2F v5.xyzw, v2              # float(height)

FDIV v6.xyzw, v3, v4         # tid / width
F2I  v6.xyzw, v6             # floor -> row y
I2F  v6.xyzw, v6             # float_y

FMUL v7.xyzw, v6, v4         # float_y * float_width
FSUB v7.xyzw, v3, v7         # float_x = tid - y*width

FDIV v7.xyzw, v7, v4         # x_norm in [0,1]
FDIV v6.xyzw, v6, v5         # y_norm in [0,1]

# ---- Load constants ----
LDI_LO v12.xyzw, low(2.0)
LDI_HI v12.xyzw, high(2.0)

LDI_LO v13.xyzw, low(1.0)
LDI_HI v13.xyzw, high(1.0)

LDI_LO v14.xyzw, low(0.0)
LDI_HI v14.xyzw, high(0.0)

LDI_LO v15.xyzw, low(255.0)
LDI_HI v15.xyzw, high(255.0)

# ---- Map to centered UV in [-1,1] ----
FMUL v7.xyzw, v7, v12        # x_norm * 2
FMUL v6.xyzw, v6, v12        # y_norm * 2
FSUB v7.xyzw, v7, v13        # u = x_norm*2 - 1
FSUB v6.xyzw, v6, v13        # v = y_norm*2 - 1

# ---- Build 2D point (u, v, 0, 0) in v8 for DOT ----
MOV v8.xyzw, v14             # v8 = {0, 0, 0, 0}
MOV v8.x, v7                 # v8.x = u  (per-thread: pixel column coord)
MOV v8.y, v6                 # v8.y = v  (per-thread: pixel row coord)

# ---- SDF: circle at origin, radius 0.45 ----
DOT   v9.xyzw, v8, v8        # v9 = u^2 + v^2  (broadcast scalar)
FSQRT v9.xyzw, v9            # v9 = dist = sqrt(u^2 + v^2)

LDI_LO v10.xyzw, low(0.45)
LDI_HI v10.xyzw, high(0.45)
FSUB v9.xyzw, v9, v10        # v9 = sdf = dist - 0.45
                              # sdf < 0 → inside circle

# ---- -sdf (used for R and G channels) ----
FSUB v8.xyzw, v14, v9        # v8 = -sdf

# ---- |sdf| = max(sdf, -sdf) ----
FMAX v10.xyzw, v9, v8        # v10 = |sdf|

# ---- R: ring glow = (1 - |sdf|*5) clamped [0,1], scaled to [0,255] ----
LDI_LO v1.xyzw, low(5.0)
LDI_HI v1.xyzw, high(5.0)
FMUL v10.xyzw, v10, v1       # |sdf| * 5
FSUB v10.xyzw, v13, v10      # 1 - |sdf|*5
FMAX v10.xyzw, v10, v14      # clamp low to 0
FMIN v10.xyzw, v10, v13      # clamp high to 1
FMUL v11.x, v10, v15         # R = ring_glow * 255

# ---- G: interior fill = (-sdf * 2) clamped [0,1], scaled ----
FMUL v10.xyzw, v8, v12       # v10 = -sdf * 2
FMAX v10.xyzw, v10, v14      # clamp low
FMIN v10.xyzw, v10, v13      # clamp high
FMUL v11.y, v10, v15         # G = interior_fill * 255

# ---- B: sky/outer haze = (sdf*2 + 0.7) clamped [0,1] ----
FMUL v10.xyzw, v9, v12       # sdf * 2
LDI_LO v1.xyzw, low(0.7)
LDI_HI v1.xyzw, high(0.7)
FADD v10.xyzw, v10, v1       # sdf*2 + 0.7
FMAX v10.xyzw, v10, v14      # clamp low
FMIN v10.xyzw, v10, v13      # clamp high
FMUL v11.z, v10, v15         # B = sky_haze * 255

# ---- A = 255 (fully opaque) ----
MOV v11.w, v15

# ---- Write pixel ----
F2I  v11.xyzw, v11
FLUSH
RETURN v11
