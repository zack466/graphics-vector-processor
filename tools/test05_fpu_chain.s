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
# Expected: pixel N = {float(N^2), float(N^2), float(N^2), float(N^2)}
#   pixel 0: "00000000 00000000 00000000 00000000"  (0.0)
#   pixel 1: "3F800000 3F800000 3F800000 3F800000"  (1.0)
#   pixel 2: "40800000 40800000 40800000 40800000"  (4.0)
#   pixel 3: "41100000 41100000 41100000 41100000"  (9.0)
#   pixel 4: "41800000 41800000 41800000 41800000"  (16.0)

THREAD_ID v0.xyzw        # v0 = global thread id (integer)
LDI_LO v5.xyzw, 0x0004  # v5 = 4 (shift amount for byte addr)
ISHL v2.xyzw, v0, v5    # v2 = 16*tid (byte address)
I2F v1.xyzw, v0         # v1 = float(tid)   [FPU, no FLUSH needed]
FMUL v3.xyzw, v1, v1    # v3 = tid^2        [FPU, chained dep on v1, no FLUSH]
FLUSH                    # drain pipeline before MCU reads VRF
STORE v3, 0x0000(v2)    # store float(tid^2)
FLUSH
RETURN
