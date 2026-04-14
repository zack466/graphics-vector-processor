# test14_pastel.s
# WIDTH: 64
# HEIGHT: 64
#
# Pastel animated waves (adapted from GLSL).
# uv  = (2*coord - resolution) / min(W, H)  -- aspect-corrected centered coords
# wave = (uv.x + uv.y) * 5 + t_seconds      -- diagonal travelling wave
# R = sin(wave + 0) * 0.3 + 0.7
# G = sin(wave + 2) * 0.3 + 0.7             -- phase-shifted for color variation
# B = sin(wave + 4) * 0.3 + 0.7
#
# All three sin evaluations are dispatched in a single SIN instruction by
# packing the three phase-shifted arguments into the x/y/z lanes of one register.
# Result is in [0.4, 1.0] by construction, so no clamping needed.
#
# New instructions vs earlier tests: none (reuses FADD / SIN / MOV patterns).
#
# Register map:
#   v0  scratch (constants, intermediates)
#   v1  float_width
#   v2  float_height
#   v3  t_seconds
#   v4  min(W, H)
#   v5  float_x → uv.x
#   v6  float_y → uv.y
#   v7  wave (broadcast to all 4 lanes)
#   v8  float(tid)         (freed after x/y split)
#   v9  scratch
#   v10 phase vector (wave, wave+2, wave+4, wave) → sin result → scaled color
#   v11 output pixel (R, G, B, A)

THREAD_ID v8.xyzw
WIDTH     v1.xyzw
HEIGHT    v2.xyzw
TIME      v3.xyzw

I2F v8.xyzw, v8             # float(tid)
I2F v1.xyzw, v1             # float_width
I2F v2.xyzw, v2             # float_height
I2F v3.xyzw, v3             # float(time_ms)

# t = time_ms / 1000
LDI_LO v0.xyzw, low(1000.0)
LDI_HI v0.xyzw, high(1000.0)
FDIV v3.xyzw, v3, v0        # v3 = t_seconds

# y = floor(tid / width)
FDIV v6.xyzw, v8, v1
F2I  v6.xyzw, v6
I2F  v6.xyzw, v6             # v6 = float_y

# x = float_tid - float_y * float_width
FMUL v0.xyzw, v6, v1        # y * width
FSUB v5.xyzw, v8, v0        # v5 = float_x

# uv.x = (2*x - W) / min(W, H)
FMIN v4.xyzw, v1, v2        # v4 = min(W, H)
FADD v5.xyzw, v5, v5        # 2*x
FSUB v5.xyzw, v5, v1        # 2*x - W
FDIV v5.xyzw, v5, v4        # v5 = uv.x

# uv.y = (2*y - H) / min(W, H)
FADD v6.xyzw, v6, v6        # 2*y
FSUB v6.xyzw, v6, v2        # 2*y - H
FDIV v6.xyzw, v6, v4        # v6 = uv.y

# wave = (uv.x + uv.y) * 5 + t
FADD v7.xyzw, v5, v6        # uv.x + uv.y
LDI_LO v0.xyzw, low(5.0)
LDI_HI v0.xyzw, high(5.0)
FMUL v7.xyzw, v7, v0        # * 5
FADD v7.xyzw, v7, v3        # + t  →  v7 = wave

# Build phase vector: v10 = (wave, wave+2, wave+4, wave)
MOV v10.xyzw, v7            # all lanes = wave
LDI_LO v0.xyzw, low(2.0)
LDI_HI v0.xyzw, high(2.0)
FADD v10.y, v7, v0          # v10.y = wave + 2
LDI_LO v0.xyzw, low(4.0)
LDI_HI v0.xyzw, high(4.0)
FADD v10.z, v7, v0          # v10.z = wave + 4

# Evaluate sin for all three channels in one instruction
SIN v10.xyzw, v10            # v10 = (sin(w), sin(w+2), sin(w+4), sin(w))

# color = sin * 0.3 + 0.7  →  range [0.4, 1.0], no clamping required
LDI_LO v0.xyzw, low(0.3)
LDI_HI v0.xyzw, high(0.3)
FMUL v10.xyzw, v10, v0
LDI_LO v0.xyzw, low(0.7)
LDI_HI v0.xyzw, high(0.7)
FADD v10.xyzw, v10, v0

# Scale [0,1] → [0,255]
LDI_LO v0.xyzw, low(255.0)
LDI_HI v0.xyzw, high(255.0)
FMUL v10.xyzw, v10, v0      # v10 = (R, G, B, ?) in [0,255]

# Pack output: A=255 pre-filled, then set R, G, B from x/y/z lanes
MOV v11.xyzw, v0             # v11 = (255, 255, 255, 255)  — sets A
MOV v11.x, v10               # R = v10.x
MOV v11.y, v10               # G = v10.y
MOV v11.z, v10               # B = v10.z

F2I  v11.xyzw, v11
FLUSH
RETURN v11
