# test02_i2f.s
# Test I2F (integer-to-float) conversion via the FPU.
# Expected: pixel N = W=Z=Y=X = IEEE-754 float(N)
# e.g. pixel 0: "00000000 00000000 00000000 00000000"  (0.0)
#      pixel 1: "3F800000 3F800000 3F800000 3F800000"  (1.0)
#      pixel 2: "40000000 40000000 40000000 40000000"  (2.0)
#      pixel 3: "40400000 40400000 40400000 40400000"  (3.0)

THREAD_ID v0.xyzw        # v0 = absolute thread index (integer)
FLUSH
LDI_LO v1.xyzw, 0x0004   # v1 = 4
FLUSH
ISHL v2.xyzw, v0, v1     # v2 = thread_id * 16 (byte offset)
FLUSH
I2F v3.xyzw, v0          # v3 = float(thread_id)
FLUSH
STORE v3, 0x0000(v2)     # store float value
FLUSH
RETURN
