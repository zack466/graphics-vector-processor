# test07_control_flow.s
# Test even/odd thread pixel values using branchless ALU computation.
#
# Previously this test used SIMT divergence (SSY/BRA_DIV/SYNC) with STORE
# inside each divergent path. Since RETURN reg cannot occur within a divergent
# path and STORE has been removed, the pixel value is now computed branchlessly:
#
#   parity    = tid & 1          (0 for even, 1 for odd)
#   not_parity = 1 - parity      (1 for even, 0 for odd)
#   pixel     = not_parity * 255 (255 for even threads, 0 for odd threads)
#
# Expected output: even pixels = 255 (white), odd pixels = 0 (black)

THREAD_ID v0.xyzw        # v0 = thread_id (same value in all four components)
LDI_LO v1.xyzw, 0x0001  # v1 = 1
IAND v2.xyzw, v0, v1    # v2 = tid & 1 = parity (0=even, 1=odd)
ISUB v3.xyzw, v1, v2    # v3 = 1 - parity (1=even, 0=odd)
LDI_LO v4.xyzw, 0x00FF  # v4 = 255
IMUL v5.xyzw, v3, v4    # v5 = pixel value (255 for even threads, 0 for odd threads)
FLUSH
RETURN v5
