# test07_control_flow.s
# Test SIMT divergence: even-index threads store 1.0f (white), odd store 0.0f (black).
#
# Architecture notes:
#  - ALU/FPU/IMM instructions run for ALL 32 threads regardless of exec_mask.
#    However, STORE now masks Avalon byte enables based on exec_mask, so
#    each path's STORE only writes to its active threads' pixel locations.
#  - FLUSH is required before BRA_DIV to ensure all threads' ICMP results
#    are settled in the Predicate Register File (PRF) before the branch reads them.
#  - SSY marks the reconvergence point. BRA_DIV: taken threads jump to if_label;
#    not-taken threads fall through to the else path at the next instruction.
#
# Flow:
#   v3 = tid & 1           (0=even, 1=odd)
#   p0 = (v3 == 0)         (predicate: true for even threads)
#   FLUSH                  (wait for all 32 PRF writes before branch)
#   SSY reconv             (save reconvergence PC)
#   BRA_DIV white, p0      (even threads jump to white; odd fall through to black)
#   black: store 0, SYNC
#   white: store 255, SYNC
#   reconv: FLUSH, RETURN
#
# Expected: even pixels = 255, odd pixels = 0
#   pixel 0 (even): 255
#   pixel 1 (odd):  0
#   pixel 2 (even): 255

THREAD_ID v0.xyzw        # v0 = global thread id
LDI_LO v1.xyzw, 0x0001  # v1 = 1 (mask for bit 0)
LDI_LO v2.xyzw, 0x0004  # v2 = 4 (shift for byte addr)
ISHL v5.xyzw, v0, v2    # v5 = 16*tid (byte address)
IAND v3.xyzw, v0, v1    # v3 = tid & 1  (0=even, 1=odd)
LDI_LO v4.xyzw, 0x0000  # v4 = 0 (comparison value)
ICMP_EQ p0, v3, v4      # p0 = (v3 == 0) = (tid is even) = white
FLUSH                    # REQUIRED: wait for all threads' PRF writes before BRA_DIV
SSY reconv               # save reconvergence PC
BRA_DIV white, p0        # even (p0=1) jump to white; odd fall through to black path

# ---- Black path (odd threads, not-taken) ----
LDI_LO v6.xyzw, 0x0000  # v6 = 0 (black) -- runs for ALL threads
STORE v6, 0x0000
SYNC                     # end of black path: switch to white (even) threads

# ---- White path (even threads, taken) ----
white:
LDI_LO v6.xyzw, 0x00FF  # v6 = 255 (white) -- runs for ALL threads
STORE v6, 0x0000
SYNC                     # end of white path: reconverge

# ---- Reconvergence ----
reconv:
FLUSH
RETURN
