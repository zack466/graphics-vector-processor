import sys
from tools.runner import hex_to_float

def main():
    dump_file = "src/memory_dump.hex"
    with open(dump_file, 'r') as f:
        lines = f.readlines()
        
    print(f"Total lines: {len(lines)}")
    if len(lines) > 0:
        for i in [0, 31, 32, 1023]:
            if i < len(lines):
                parts = lines[i].strip().split()
                if len(parts) == 4:
                    r = hex_to_float(parts[3])
                    g = hex_to_float(parts[2])
                    b = hex_to_float(parts[1])
                    a = hex_to_float(parts[0])
                    print(f"Pixel {i:4d} (x={i%32:2d}, y={i//32:2d}): R={r:.3f}, G={g:.3f}, B={b:.3f}, A={a:.3f}")

if __name__ == '__main__':
    main()
