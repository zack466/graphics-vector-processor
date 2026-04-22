import sys
import re
import struct  # Added for IEEE 754 float conversion

# Types (must match INST_TYPE_* constants in processor_constants_pkg.vhd)
TYPE_FPU  = 0
TYPE_CTRL = 1
TYPE_RED  = 2
TYPE_ALU  = 3
TYPE_IMM  = 4
TYPE_SYS  = 6

# FPU Opcodes
FPU_OPCODES = {
    'FADD': 1, 'FSUB': 2, 'FMUL': 3, 'FMADD': 4, 'FDIV': 5, 'FSQRT': 6,
    'FLOG2': 7, 'FEXP2': 8, 'FMIN': 9, 'FMAX': 10, 'FCMP_LT': 11, 'FCMP_EQ': 12,
    'F2I': 13, 'I2F': 14, 'SIN': 16, 'COS': 17, 'MOV': 18, 'PAND': 24, 'POR': 25, 'PXOR': 26
}

# ALU Opcodes
ALU_OPCODES = {
    'IADD': 0, 'ISUB': 1, 'IAND': 2, 'IOR': 3, 'IXOR': 4, 'ISHL': 5, 'ISHR': 6,
    'IMUL': 7, 'IINC': 8, 'IDEC': 9, 'ISAR': 10, 'ICMP_EQ': 11, 'ICMP_SLT': 12,
    'ICMP_ULT': 13, 'THREAD_ID': 14, 'WIDTH': 15, 'HEIGHT': 16, 'TIME': 17
}

# CTRL Opcodes
CTRL_OPCODES = {
    'JMP': 48, 'BRA_Z': 49, 'BRA_NZ': 50, 'BRA_DIV': 51, 'SSY': 52, 'SYNC': 53,
    'BRA_L': 54, 'BRA_X': 55, 'PUSH_L': 56, 'POP_L': 57
}

# RED Modes
RED_MODES = {
    'DOT': 0, 'SQ_MAG': 1, 'SUM': 2, 'ABS_SUM': 3
}

# IMM Opcodes
IMM_OPCODES = {
    'LDI_LO': 0, 'LDI_HI': 1
}

# SYS Opcodes
SYS_OPCODES = {
    'FLUSH': 62, 'RETURN': 63, 'BREAK': 60, 'INT': 61
}

def parse_reg(token):
    token = token.strip()
    mask = 15  # default write mask: all
    swiz = 0   # default swizzle: pass

    if '.' in token:
        base, mod = token.split('.')
        # Check if it's a splat swizzle
        if len(mod) == 4 and all(c == mod[0] for c in mod):
            if mod[0] == 'x': swiz = 4
            elif mod[0] == 'y': swiz = 5
            elif mod[0] == 'z': swiz = 6
            elif mod[0] in ('w', 'a'): swiz = 7
        elif mod == 'xyzw':
            swiz = 0
        else:
            # It's a write mask
            mask = 0
            if 'x' in mod: mask |= 1
            if 'y' in mod: mask |= 2
            if 'z' in mod: mask |= 4
            if 'w' in mod or 'a' in mod: mask |= 8
    else:
        base = token

    if base.startswith('v') or base.startswith('p') or base.startswith('r'):
        reg = int(base[1:])
    else:
        reg = int(base)
    
    return reg, mask, swiz

# --- NEW: Helper function to parse immediates with low()/high() macros ---
def parse_imm_value(token):
    match = re.match(r'(?i)^(low|high)\((.+)\)$', token)
    if match:
        func = match.group(1).lower()
        val_str = match.group(2)
        
        # Determine if it's a float or int
        is_hex = val_str.lower().startswith('0x')
        if not is_hex and ('.' in val_str or 'e' in val_str.lower()):
            # Pack as big-endian float, unpack as big-endian unsigned int to get raw bits
            num32 = struct.unpack('>I', struct.pack('>f', float(val_str)))[0]
        else:
            # Mask to 32 bits to properly handle two's complement for negative integers
            num32 = int(val_str, 0) & 0xFFFFFFFF
            
        if func == 'low':
            return num32 & 0xFFFF
        else: # high
            return (num32 >> 16) & 0xFFFF
    else:
        # Standard raw value fallback
        val = int(token, 0)
        if val < 0:
            val = (val & 0xFFFFFFFF)
        return val & 0xFFFF

def assemble_line(line, labels, pc):
    # Remove comments
    line = line.split('#')[0].strip()
    if not line or line.endswith(':'): return None

    # Parse mnemonic and args
    parts = line.replace(',', ' ').split()
    mnemonic = parts[0].upper()
    args = parts[1:]

    # SYS
    if mnemonic in SYS_OPCODES:
        op = SYS_OPCODES[mnemonic]
        if mnemonic == 'RETURN' and args:
            # RETURN reg: encodes register index in bits[17:14] (standard rs1 field)
            reg, _, _ = parse_reg(args[0])
            return (op << 26) | (reg << 14) | TYPE_SYS
        return (op << 26) | TYPE_SYS

    # IMM
    if mnemonic in IMM_OPCODES:
        # e.g. LDI_LO v1.xy, low(3.14)
        # Encoding: [31:30]=sub-op  [29:26]=write_mask  [25:10]=imm16  [7:4]=rd  [3:0]=type
        op = IMM_OPCODES[mnemonic]   # 0=LDI_LO, 1=LDI_HI  (placed in bits [31:30])
        dest, mask, _ = parse_reg(args[0])
        
        # We rejoin the remaining args to easily bypass spaces the initial `.split()` stripped out. 
        # (e.g. ['low(', '-3.14', ')'] becomes 'low(-3.14)')
        imm_str = "".join(args[1:])
        imm_val = parse_imm_value(imm_str)
        
        return (op << 30) | (mask << 26) | (imm_val << 10) | (dest << 4) | TYPE_IMM

    # CTRL
    if mnemonic in CTRL_OPCODES:
        # Format: OP [TARGET] (SYNC has no target; JMP/BRA_*/SSY require one)
        op = CTRL_OPCODES[mnemonic]
        if args:
            target_str = args[0]
            if target_str in labels:
                target_addr = labels[target_str]
            else:
                target_addr = int(target_str, 0) & 0xFFFF
        else:
            target_addr = 0  # SYNC uses no target address
            
        # Defaults for branch predicate: Sel=0, Mod=0 (ANY)
        p_sel = 0
        p_mod = 0
        
        # If args provide predicate: BRA_NZ TARGET, p0.ANY
        if len(args) > 1:
            p_sel, _, _ = parse_reg(args[1].split('.')[0])
            mod_str = args[1].split('.')[1].upper() if '.' in args[1] else 'ANY'
            if mod_str == 'ANY': p_mod = 0
            elif mod_str == 'ALL': p_mod = 1
            elif mod_str == 'X': p_mod = 2
            elif mod_str == 'A': p_mod = 3
            
        return (op << 26) | (target_addr << 10) | (p_sel << 6) | (p_mod << 4) | TYPE_CTRL

    # RED
    if mnemonic in RED_MODES:
        # e.g., SUM v3.y, v0.yyyy, v1
        # [31:30] Mode | [29:26] Mask | [25:22] Dest   | [21:18] Src1
        # [17:14] Src2 | [13:11] Swz A| [10:8]  Swz B  | [3:0] Type
        mode = RED_MODES[mnemonic]
        dest, mask, _ = parse_reg(args[0])
        src1, _, swizA = parse_reg(args[1])
        src2, _, swizB = parse_reg(args[2]) if len(args) > 2 else (0, 15, 0)
        
        return (mode << 30) | (mask << 26) | (dest << 22) | (src1 << 18) | (src2 << 14) | (swizA << 11) | (swizB << 8) | TYPE_RED

    # FPU
    if mnemonic in FPU_OPCODES:
        # [31:26] Opcode | [25:22] Mask | [21:18] Dest | [17:14] Src1
        # [13:10] Src2   | [9:7] Swiz A | [6] Cmp_Inv | [5] Cmp_Swap | [3:0] Type
        op = FPU_OPCODES[mnemonic]
        
        cmp_inv = 0
        cmp_swap = 0
        if mnemonic.endswith('_INV'): cmp_inv = 1
        if mnemonic.endswith('_SWAP'): cmp_swap = 1
        
        dest, mask, _ = parse_reg(args[0])
        src1, _, swizA = parse_reg(args[1]) if len(args) > 1 else (0, 15, 0)
        src2, _, _ = parse_reg(args[2]) if len(args) > 2 else (0, 15, 0)
        
        return (op << 26) | (mask << 22) | (dest << 18) | (src1 << 14) | (src2 << 10) | (swizA << 7) | (cmp_inv << 6) | (cmp_swap << 5) | TYPE_FPU

    # ALU
    if mnemonic in ALU_OPCODES:
        # [31:26] Opcode | [25:22] Mask | [21:18] Dest | [17:14] Src1
        # [13:10] Src2 | [9:7] Swiz A | [3:0] Type
        op = ALU_OPCODES[mnemonic]
        dest, mask, _ = parse_reg(args[0])
        src1, _, swizA = parse_reg(args[1]) if len(args) > 1 else (0, 15, 0)
        src2, _, _ = parse_reg(args[2]) if len(args) > 2 else (0, 15, 0)
        
        return (op << 26) | (mask << 22) | (dest << 18) | (src1 << 14) | (src2 << 10) | (swizA << 7) | TYPE_ALU

    raise ValueError(f"Unknown instruction: {mnemonic}")

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    # Pass 1: Resolve Labels
    labels = {}
    pc = 0
    for line in lines:
        l = line.split('#')[0].strip()
        if not l: continue
        if l.endswith(':'):
            labels[l[:-1]] = pc
        else:
            pc += 1

    # Pass 1b: Validate — RETURN reg must not appear inside a divergent SSY...SYNC block.
    ssy_count = 0
    sync_count = 0
    for line in lines:
        l = line.split('#')[0].strip()
        if not l or l.endswith(':'): continue
        mnemonic = l.replace(',', ' ').split()[0].upper()
        args = l.replace(',', ' ').split()[1:]
        if mnemonic == 'SSY':
            ssy_count += 1
        elif mnemonic == 'SYNC':
            sync_count += 1
        elif mnemonic == 'RETURN' and args:
            if ssy_count * 2 > sync_count:
                raise ValueError(
                    "RETURN reg cannot appear inside a divergent path "
                    "(between SSY and its two SYNC instructions). "
                    "Move RETURN after the reconvergence label.")

    # Pass 2: Assemble
    machine_code = []
    pc = 0
    for line in lines:
        l = line.split('#')[0].strip()
        if not l or l.endswith(':'): continue
        try:
            code = assemble_line(l, labels, pc)
            if code is not None:
                machine_code.append(code)
                pc += 1
        except Exception as e:
            print(f"Error parsing line: {line}")
            raise e

    # Write output
    with open(output_file, 'w') as f:
        for code in machine_code:
            # f.write(f"0x{code:08X}\n")  # for copying into tcl script
            f.write(f"{code:08X}\n")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python assembler.py <input.s> <output.hex>")
        sys.exit(1)
    
    assemble(sys.argv[1], sys.argv[2])
    print(f"Assembled {sys.argv[1]} to {sys.argv[2]}")
