# test03_ldi.s
# Test LDI_LO + LDI_HI to load a known constant (1.0f = 0x3F800000).
# Expected: every pixel = "3F800000 3F800000 3F800000 3F800000"
# (all components = 1.0 regardless of thread ID)

THREAD_ID v0.xyzw        # v0 = thread index (used for address only)
FLUSH
LDI_LO v1.xyzw, 0x0004   # v1 = 4
FLUSH
ISHL v2.xyzw, v0, v1     # v2 = thread_id * 16 (byte offset)
FLUSH

LDI_LO v3.xyzw, 0x0000   # v3 = 0x????0000
FLUSH
LDI_HI v3.xyzw, 0x3F80   # v3 = 0x3F800000 = 1.0f
FLUSH

STORE v3, 0x0000(v2)     # store 1.0f to all pixels
FLUSH
RETURN
