# test01_thread_id.s
# Simplest possible test: store raw integer thread ID to memory.
# Expected: pixel N = W=Z=Y=X = N (as raw integer, not float)
# e.g. pixel 0: "00000000 00000000 00000000 00000000"
#      pixel 1: "00000001 00000001 00000001 00000001"
#      pixel 2: "00000002 00000002 00000002 00000002"

THREAD_ID v0.xyzw       # v0.xyzw = absolute thread index
FLUSH
LDI_LO v1.xyzw, 0x0004  # v1 = 4  (shift amount for *16 byte offset)
FLUSH
ISHL v2.xyzw, v0, v1    # v2 = thread_id * 16  (byte address in framebuffer)
FLUSH
STORE v0, 0x0000(v2)    # store v0 at address v2
FLUSH
RETURN
