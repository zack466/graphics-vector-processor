# Reductions:
# - sum, min, max, put in A

# SIN (component-wise sin)
# COS (component-wise cos)
# TAN (component-wise tan)
# SQRT (component-wise sqrt)
class UnaryInstruction:
    """
    Does OP(A) -> B
    """
    def __init__(self, reg_a, reg_b):
        self.reg_a = reg_a
        self.reg_b = reg_b

        # if should perform a reduction operation, putting result in the A
        # component of the target register (c)
        self.reduce = None  

        # determine which components will actually be updated to their new
        # values (any "0000" is technically a no-op)
        self.mask = None

# ADD (component-wise add)
# MUL (component-wise mul)
#  - DOT is just MUL with add reduction
#  - SCALE is MUL with use_a true
class BinaryInstruction:
    """
    Does OP(A, B) -> C
    """
    def __init__(self, reg_a, reg_b, reg_c):
        self.reg_a = reg_a
        self.reg_b = reg_b
        self.reg_c = reg_c

        # negate x/y/z/a before use
        self.neg_mask = None

        # can also use fourth component instead of x/y/z
        # if needed, can implement swizzle instead (more bits though)
        self.use_a = False

        # if should perform a reduction operation on the X, Y and Z components,
        # putting result in the A component of the target register (c)
        self.reduce = None  

        # determine which components will actually be updated to their new
        # values (any "0000" is technically a no-op)
        self.out_mask = None


class MovInstruction:
    """
    Memory (or immediate) -> Reg
        - word-wise, doubleword-wise, or quadword-wise
    Reg -> Memory
    Reg -> Reg
        - includes using
    """
    def __init__(self, source, dest):
        pass
