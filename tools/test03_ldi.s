# test03_ldi.s
# Test LDI_LO + LDI_HI to load a known constant (255.0f = 0x437F0000).
# Expected: every pixel = 255 (0x000000FF in all components)

THREAD_ID v0.xyzw        # v0 = thread index (used for address only)
FLUSH

LDI_LO v3.xyzw, 0x0000   # v3 = 0x????0000
FLUSH
LDI_HI v3.xyzw, 0x437F   # v3 = 0x437F0000 = 255.0f
FLUSH

F2I v4.xyzw, v3          # v4 = 255
FLUSH

STORE v4, 0x0000         # store 255 to all pixels
FLUSH
RETURN
