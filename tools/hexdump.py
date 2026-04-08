#!/usr/bin/env python3
"""
hexdump.py - Display memory_dump.hex with annotated addresses and float interpretations.

Usage:
    python tools/hexdump.py [dump_file] [--count N] [--floats]

Arguments:
    dump_file  Path to hex dump (default: src/memory_dump.hex)
    --count N  Number of lines to show (default: 32)
    --floats   Also show IEEE-754 float interpretation of each word
"""

import sys
import struct


def hex_to_float(hex_str):
    try:
        iv = int(hex_str, 16)
        return struct.unpack('!f', struct.pack('!I', iv))[0]
    except Exception:
        return float('nan')


def main():
    dump_file = "src/memory_dump.hex"
    count = 32
    show_floats = False

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--count':
            count = int(args[i+1]); i += 2
        elif args[i] == '--floats':
            show_floats = True; i += 1
        elif not args[i].startswith('--'):
            dump_file = args[i]; i += 1
        else:
            i += 1

    print(f"{'Pixel':>5}  {'Addr':>10}  {'W (bits[127:96])':>18}  {'Z (bits[95:64])':>17}  {'Y (bits[63:32])':>17}  {'X (bits[31:0])':>17}")
    print("-" * 100)

    with open(dump_file, 'r') as f:
        for idx, line in enumerate(f):
            if idx >= count:
                break
            parts = line.strip().split()
            if len(parts) != 4:
                continue
            addr = idx * 16
            w, z, y, x = parts[0], parts[1], parts[2], parts[3]
            if show_floats:
                wf = hex_to_float(w)
                zf = hex_to_float(z)
                yf = hex_to_float(y)
                xf = hex_to_float(x)
                print(f"{idx:>5}  0x{addr:08X}  {w} ({wf:>9.4f})  {z} ({zf:>9.4f})  {y} ({yf:>9.4f})  {x} ({xf:>9.4f})")
            else:
                print(f"{idx:>5}  0x{addr:08X}  {w:>18}  {z:>17}  {y:>17}  {x:>17}")


if __name__ == '__main__':
    main()
