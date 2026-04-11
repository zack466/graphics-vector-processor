import sys
import struct

def hex_to_float(hex_str):
    if 'X' in hex_str or 'U' in hex_str:
        return 0.0
    try:
        int_val = int(hex_str, 16)
        return struct.unpack('!f', struct.pack('!I', int_val))[0]
    except Exception:
        return 0.0

def main():
    dump_file = "src/memory_dump.hex"
    with open(dump_file, 'r') as f:
        lines = f.readlines()
        
    print(f"Total lines: {len(lines)}")
    if len(lines) > 0:
        for i in range(10):
            if i < len(lines):
                parts = lines[i].strip().split()
                if len(parts) == 4:
                    print(f"Line {i}: {lines[i].strip()}")

if __name__ == '__main__':
    main()
