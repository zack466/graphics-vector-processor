# test10_call_stack.s
# Tests the call stack instructions (BRA_L, BRA_X, PUSH_L, POP_L) and the
# MOV instruction.
#
# Program flow:
#   1. Clear v1, then call the leaf function.
#      leaf: loads v1.xyzw = 0x42 (integer 66) and returns with BRA_X.
#   2. IADD v2.xyzw, v1, v15 -- copies v1 into v2
#   3. Call outer (non-leaf function that itself calls leaf):
#      outer: PUSH_L saves the caller's link, BRA_L calls leaf again,
#             POP_L restores the link, BRA_X returns.
#   4. FLUSH + RETURN v2
#      Stores 32 copies of v2 = {0x42,0x42,0x42,0x42} to the framebuffer
#      and halts the warp (combined store+halt instruction).
#
# Expected pixel output:
#   Each of the 32 threads stores v2, whose four 8-bit lanes are all 0x42,
#   so every pixel word = 0x42424242.

# --- Main ---
LDI_LO v1.xyzw, 0x0000     # clear v1 so the leaf call is observable
BRA_L leaf                  # call leaf; link_reg = PC+1 (= next instruction)
LDI_LO v15.xyzw, 0x0000     # clear v15 (tests MOV replacement)
IADD v2.xyzw, v1, v15       # v2 = v1 = 0x42 in all components (tests MOV replacement)
BRA_L outer                 # call outer (non-leaf); link_reg = PC+1
FLUSH
RETURN v2                   # write 32 threads' v2 to framebuffer and halt warp

# --- leaf (PC 6) ---
# Leaf function: sets v1 = 0x42 in all four vector components.
leaf:
LDI_LO v1.xyzw, 0x0042     # v1 = 66 (0x42) -- same value in all 4 components
BRA_X                       # return to caller via link register

# --- outer (PC 8) ---
# Non-leaf function: saves its own return address, calls leaf, then returns.
outer:
PUSH_L                      # push link_reg (outer's return addr) onto call stack
BRA_L leaf                  # call leaf; link_reg = PC+1 (instruction after BRA_L)
POP_L                       # restore outer's return address from call stack
BRA_X                       # return to main via (restored) link register
