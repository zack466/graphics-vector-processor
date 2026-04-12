# test01_thread_id.s
# Simplest possible test: store raw integer thread ID to memory.
# Expected: pixel N = {W=255, Z=N, Y=N, X=N}
# e.g. pixel 0: "FF000000"
#      pixel 1: "FF010101"
#      pixel 2: "FF020202"

THREAD_ID v0.xyzw       # v0.xyzw = absolute thread index
LDI_LO v0.w, 0x00FF     # Make alpha opaque
FLUSH
RETURN v0               # write packed pixels from v0 to framebuffer and halt
