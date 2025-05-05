# Instruction Set

Smallest element of computation is a 128-bit vector, consisting of four 32-bit floats (or signed/unsigned integers?) WXYZ.
- each core should have access to some local constants too (like thread ID, x/y coordinates, etc)

Supported instructions:
- parallel floating-point add/sub/multiply/divide/shift
- parallel transcendental functions (sin/cos/log/exp/sqrt)
- parallel integer/logical add/sub/shift/and/or/not/xor
- reduction operations (min, max, sum), put result in all elements of new vector?
- compare operations (eq, lt, gt, approx)
- stack operations (push/pop/drop/dup/over)
- integer to float, float to integer
- memory operations (load/store)
- jump / conditional branch / call / ret

Instruction modifiers:
- zero mask
- negate mask
- input mask (swizzle?)
- output mask
- conditional mask? (choosing to do instruction or not based on status register)

# Algorithm:

1. Load thread state
2. Generate primary ray
3. Intersect ray with scene (loop)
4. Use intersection data to determine if:
  A. accumulate color, generate new ray, loop to (3)
  B. finalize color, end loop

If we go with a streaming approach, then the core should have each step as a different kernel.

1. Compute primary rays.
2. Intersect ray with scene
3. Use intersection data to accumulate color. Either extend ray or cull it. Loop to 3.

# References
- [AMD R600 ISA](https://www.x.org/docs/AMD/old/r600isa.pdf)
