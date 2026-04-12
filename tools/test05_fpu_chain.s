# test05_fpu_chain.s
# Test dependent FPU chain WITHOUT FLUSH between arithmetic instructions.
#
# FPU pipeline latency = 28 cycles. With 32 threads in the barrel scheduler,
# the same thread's next instruction is issued 32 cycles later (32 > 28+1=29),
# so no FLUSH is needed between consecutive FPU instructions either.
#
# Program (no FLUSH between any arithmetic ops):
#   v0 = THREAD_ID
#   v1 = I2F(v0)       = float(tid)       [FPU, no FLUSH from THREAD_ID]
#   v3 = FMUL(v1, v1)  = float(tid^2)     [FPU, chained dep on v1, no FLUSH]
#
# Expected: pixel N = {W=255, Z=int(N^2), Y=int(N^2), X=int(N^2)}
#   pixel 0: "FF000000"
#   pixel 1: "FF010101"
#   pixel 2: "FF040404"
#   pixel 3: "FF090909"
#   pixel 4: "FF101010"

THREAD_ID v0.xyzw        # v0 = global thread id (integer)
I2F v1.xyzw, v0         # v1 = float(tid)   [FPU, no FLUSH needed]
FMUL v3.xyzw, v1, v1    # v3 = tid^2        [FPU, chained dep on v1, no FLUSH]
F2I v4.xyzw, v3         # v4 = int(tid^2)   [FPU, chained dep on v3, no FLUSH]
LDI_LO v4.w, 0x00FF      # Make alpha opaque
FLUSH                    # drain pipeline before MCU reads VRF
RETURN v4               # write packed pixels from v4 to framebuffer and halt
