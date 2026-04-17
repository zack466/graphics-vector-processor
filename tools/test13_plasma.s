# test13_plasma.s
# WIDTH: 64
# HEIGHT: 64
#
# TIME-animated plasma effect using SIN.
# Each channel is a phase-shifted sine wave over pixel UV coords:
#   R = sin(u*4 + t)         * 127 + 128
#   G = sin(v*4 + u + t)     * 127 + 128   (diagonal ripple)
#   B = sin((u+v)*3 + t)     * 127 + 128
# where t = time_ms / 1000 (seconds).
#
# New instructions vs earlier tests:
#   SIN  — floating-point sine (input in radians)
#   TIME — elapsed-time uniform in milliseconds
#   FADD — phase accumulation
#
# Register map (stable throughout):
#   v0  0.0 (clamp-low constant, computed from self-subtract)
#   v1  width (int) -> reused as 4.0 / 3.0 temp constant
#   v2  height (int) -> reused as R channel result temp
#   v3  time_ms (int) -> float(time_ms) -> time_seconds -> G result temp
#   v4  float_width  (kept until normalization; then x/B result temp)
#   v5  float_height (kept until normalization)
#   v6  float_tid -> float_x -> x_norm (freed after u scale)
#   v7  float_y -> y_norm (freed after v scale)
#   v8  t = time_seconds (kept throughout)
#   v9  u [0, 2pi]  (kept throughout)
#   v10 v [0, 2pi]  (kept throughout)
#   v11 127.0
#   v12 128.0
#   v13 255.0
#   v14 output pixel (R, G, B, A)
#   v15 (unused)

# ---- Thread → pixel row / column ----
THREAD_ID v6.xyzw             # store tid directly in v6 to save a copy
WIDTH     v1.xyzw
HEIGHT    v2.xyzw
TIME      v3.xyzw             # time_ms as integer

I2F v6.xyzw, v6               # v6 = float(tid)
I2F v4.xyzw, v1               # v4 = float_width   (keep until normalization)
I2F v5.xyzw, v2               # v5 = float_height  (keep until normalization)
I2F v3.xyzw, v3               # v3 = float(time_ms)

# time in seconds
LDI_LO v8.xyzw, low(1000.0)
LDI_HI v8.xyzw, high(1000.0)
FDIV v8.xyzw, v3, v8          # v8 = t = time_ms / 1000

# y = floor(tid / width)
FDIV v7.xyzw, v6, v4          # float_tid / float_width
LDI_LO v1.xyzw, low(0.4999)
LDI_HI v1.xyzw, high(0.4999)
FSUB v7.xyzw, v7, v1
F2I  v7.xyzw, v7
I2F  v7.xyzw, v7              # v7 = float_y

# x = float_tid - float_y * float_width
FMUL v9.xyzw, v7, v4          # float_y * float_width
FSUB v6.xyzw, v6, v9          # v6 = float_x  (v6 now re-used as float_x)

# normalize to [0,1]
FDIV v6.xyzw, v6, v4          # v6 = x_norm   (v4 free after this line)
FDIV v7.xyzw, v7, v5          # v7 = y_norm   (v4, v5 free)

# ---- Load constants ----
LDI_LO v11.xyzw, low(127.0)
LDI_HI v11.xyzw, high(127.0)  # v11 = 127.0

LDI_LO v12.xyzw, low(128.0)
LDI_HI v12.xyzw, high(128.0)  # v12 = 128.0

LDI_LO v13.xyzw, low(255.0)
LDI_HI v13.xyzw, high(255.0)  # v13 = 255.0

# ---- Scale to radians: u = x_norm * 2pi, v_coord = y_norm * 2pi ----
LDI_LO v0.xyzw, low(6.2832)
LDI_HI v0.xyzw, high(6.2832)
FMUL v9.xyzw,  v6, v0         # v9  = u [0, 2pi]
FMUL v10.xyzw, v7, v0         # v10 = v [0, 2pi]

# 0.0 for clamp-low (self-subtract now that v0 is no longer needed as 2pi)
FSUB v0.xyzw, v9, v9          # v0 = 0.0

# ================================================================
# R channel: sin(u*4 + t) * 127 + 128, clamped [0,255]
# Result stored in v2 until packing.
# ================================================================
LDI_LO v1.xyzw, low(4.0)
LDI_HI v1.xyzw, high(4.0)
FMUL v2.xyzw, v9, v1          # u * 4
FADD v2.xyzw, v2, v8          # u*4 + t
SIN  v2.xyzw, v2              # sin(u*4 + t)
FMUL v2.xyzw, v2, v11         # * 127
FADD v2.xyzw, v2, v12         # + 128
FMAX v2.xyzw, v2, v0          # clamp >= 0
FMIN v2.xyzw, v2, v13         # clamp <= 255   -> v2 = R

# ================================================================
# G channel: sin(v*4 + u + t) * 127 + 128, clamped [0,255]
# Result stored in v3 until packing.
# ================================================================
LDI_LO v1.xyzw, low(4.0)
LDI_HI v1.xyzw, high(4.0)
FMUL v3.xyzw, v10, v1         # v * 4
FADD v3.xyzw, v3,  v9         # v*4 + u
FADD v3.xyzw, v3,  v8         # v*4 + u + t
SIN  v3.xyzw, v3
FMUL v3.xyzw, v3, v11
FADD v3.xyzw, v3, v12
FMAX v3.xyzw, v3, v0
FMIN v3.xyzw, v3, v13         # v3 = G

# ================================================================
# B channel: sin((u+v)*3 + t) * 127 + 128, clamped [0,255]
# Result goes directly into v4.
# ================================================================
FADD v4.xyzw, v9, v10         # u + v
LDI_LO v1.xyzw, low(3.0)
LDI_HI v1.xyzw, high(3.0)
FMUL v4.xyzw, v4, v1          # (u+v) * 3
FADD v4.xyzw, v4, v8          # (u+v)*3 + t
SIN  v4.xyzw, v4
FMUL v4.xyzw, v4, v11
FADD v4.xyzw, v4, v12
FMAX v4.xyzw, v4, v0
FMIN v4.xyzw, v4, v13         # v4 = B

# ================================================================
# Pack (R, G, B, A) into output register v14.
# After each SIN channel's FMIN, all 4 components hold the same
# channel value, so a masked FADD copies the scalar to one lane.
# ================================================================
LDI_LO v14.xyzw, low(255.0)
LDI_HI v14.xyzw, high(255.0)  # v14 = 255 (A lane pre-filled in all components)
FADD v14.z, v2, v0             # R
FADD v14.y, v3, v0             # G
FADD v14.x, v4, v0             # B
                                # v14.w = 255 (already set by LDI above)

# ---- Write pixel ----
F2I  v14.xyzw, v14
FLUSH
RETURN v14
