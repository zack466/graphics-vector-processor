# test02_i2f.s
# Test I2F (integer-to-float) conversion via the FPU.
# Expected: pixel N = {W=255, Z=int(N), Y=int(N), X=int(N)}
# e.g. pixel 0: "FF000000"
#      pixel 1: "FF010101"
#      pixel 2: "FF020202"

THREAD_ID v0.xyzw        # v0 = absolute thread index (integer)
I2F v3.xyzw, v0          # v3 = float(thread_id)
F2I v4.xyzw, v3          # v4 = int(float(thread_id))
LDI_LO v4.w, 0x00FF      # Make alpha opaque
FLUSH
RETURN v4                # write packed pixels from v4 to framebuffer and halt
