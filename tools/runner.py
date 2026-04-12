import sys
import os
import struct
import subprocess

def hex_to_float(hex_str):
    if 'X' in hex_str or 'U' in hex_str:
        return 0.0
    try:
        # Convert hex string to 32-bit unsigned integer
        int_val = int(hex_str, 16)
        # Pack as integer and unpack as float
        return struct.unpack('!f', struct.pack('!I', int_val))[0]
    except Exception:
        return 0.0

def generate_image(dump_file, output_png):
    try:
        from PIL import Image
    except ImportError:
        print("Pillow not installed. Skipping image generation.")
        print("Install with: pip install Pillow")
        return

    pixels = []
    with open(dump_file, 'r') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) == 4:
                # The line contains four 32-bit pixels (from 128-bit word)
                # Dump order: parts[0] is pixel 3, parts[1] is pixel 2, parts[2] is pixel 1, parts[3] is pixel 0
                for part in reversed(parts):
                    try:
                        val = int(part, 16)
                    except ValueError:
                        val = 0
                    # Pixel format is W, Z, Y, X (Alpha, Blue, Green, Red)
                    # W = val >> 24, Z = (val >> 16) & 0xFF, Y = (val >> 8) & 0xFF, X = val & 0xFF
                    r = val & 0xFF
                    g = (val >> 8) & 0xFF
                    b = (val >> 16) & 0xFF
                    a = (val >> 24) & 0xFF
                    pixels.append((r, g, b, a))

    if not pixels:
        print("No pixels found in dump.")
        return

    # Assume a square image for now, or 8x4 for 32 threads
    if len(pixels) == 32:
        width = 8
    else:
        import math
        width = int(math.sqrt(len(pixels)))
    
    height = len(pixels) // width
    
    if width * height == 0:
        return

    img = Image.new('RGBA', (width, height))
    img.putdata(pixels[:width*height])
    img.save(output_png)
    print(f"Saved framebuffer image to {output_png} ({width}x{height})")

def main():
    if len(sys.argv) < 2:
        print("Usage: python runner.py <test.s>")
        sys.exit(1)

    asm_file = sys.argv[1]
    hex_file = "src/program.hex"
    dump_file = "src/memory_dump.hex"
    
    # 1. Assemble
    print(f"Assembling {asm_file}...")
    subprocess.run([sys.executable, "tools/assembler.py", asm_file, hex_file], check=True)
    
    # 2. Run simulation
    print("Running simulation...")
    # Clean and build first to ensure up-to-date
    subprocess.run(["make", "clean"], cwd="src", check=True, capture_output=True)
    subprocess.run(["make", "build"], cwd="src", check=True, capture_output=True)
    
    result = subprocess.run(["make", "test-tb_frame_processor_automated"], cwd="src", capture_output=True, text=True)
    if result.returncode != 0:
        print("Simulation failed!")
        print(result.stdout)
        print(result.stderr)
        sys.exit(1)
        
    print("Simulation completed successfully.")
    
    # 3. Generate Image
    generate_image(dump_file, asm_file.replace('.s', '.png'))

if __name__ == '__main__':
    main()
