"""
run_all_tests.py — Run all automated processor tests in one go.

Usage (from repo root):
    python tools/run_all_tests.py [--no-rebuild] [--no-images]

Workflow:
    1. Build VHDL once (make clean && make build in src/, then elaborate tb_frame_processor_automated)
    2. For each tools/test[0-9][0-9]_*.s (sorted):
       a. Assemble to src/program.hex
       b. Run the simulation executable directly (no rebuild)
       c. Optionally generate a PNG image from src/memory_dump.hex
       d. Report PASS / FAIL
    3. Print a summary table

Pass --no-rebuild to skip step 1 (useful if VHDL sources haven't changed).
Pass --no-images to skip PNG generation.
"""

import sys
import os
import glob
import subprocess
import struct
import argparse
import time

REPO_ROOT  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR    = os.path.join(REPO_ROOT, "src")
TOOLS_DIR  = os.path.join(REPO_ROOT, "tools")
HEX_FILE   = os.path.join(SRC_DIR, "program.hex")
DUMP_FILE  = os.path.join(SRC_DIR, "memory_dump.hex")
SIM_EXE    = os.path.join(SRC_DIR, "work", "tb_frame_processor_automated")
RUNFLAGS   = ["--ieee-asserts=disable", "--stop-time=10ms"]


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

def build_once():
    print("=" * 60)
    print("Building VHDL (make clean && make build && ghdl -e) ...")
    print("=" * 60)

    subprocess.run(["make", "clean"], cwd=SRC_DIR, check=True, capture_output=True)
    result = subprocess.run(["make", "build"], cwd=SRC_DIR, capture_output=True, text=True)
    if result.returncode != 0:
        print("make build FAILED")
        print(result.stdout[-4000:])
        print(result.stderr[-4000:])
        sys.exit(1)

    # Elaborate the automated testbench
    result = subprocess.run(
        ["ghdl", "-e", "--std=08", f"--workdir=work/", "-o", SIM_EXE, "tb_frame_processor_automated"],
        cwd=SRC_DIR, capture_output=True, text=True
    )
    if result.returncode != 0:
        print("ghdl -e FAILED")
        print(result.stdout)
        print(result.stderr)
        sys.exit(1)

    print("Build OK.\n")


# ---------------------------------------------------------------------------
# Image generation (shared with runner.py)
# ---------------------------------------------------------------------------

def hex_to_float(hex_str):
    if 'X' in hex_str or 'U' in hex_str:
        return 0.0
    try:
        int_val = int(hex_str, 16)
        return struct.unpack('!f', struct.pack('!I', int_val))[0]
    except Exception:
        return 0.0


def generate_image(dump_file, output_png):
    from PIL import Image
    import math
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
                    r = val & 0xFF
                    g = (val >> 8) & 0xFF
                    b = (val >> 16) & 0xFF
                    a = (val >> 24) & 0xFF
                    pixels.append((r, g, b, a))

    if not pixels:
        return

    width = 8 if len(pixels) == 32 else int(math.sqrt(len(pixels)))
    height = len(pixels) // width
    if width * height == 0:
        return

    img = Image.new('RGBA', (width, height))
    img.putdata(pixels[:width * height])
    img.save(output_png)
    print(f"    Saved {os.path.basename(output_png)} ({width}x{height})")


# ---------------------------------------------------------------------------
# Run one test
# ---------------------------------------------------------------------------

def run_test(asm_file, gen_images):
    name = os.path.splitext(os.path.basename(asm_file))[0]

    # Assemble
    asm_result = subprocess.run(
        [sys.executable, os.path.join(TOOLS_DIR, "assembler.py"), asm_file, HEX_FILE],
        capture_output=True, text=True
    )
    if asm_result.returncode != 0:
        return "FAIL (assembler error)", asm_result.stderr.strip()

    # Simulate
    t0 = time.time()
    sim_result = subprocess.run(
        [SIM_EXE] + RUNFLAGS,
        cwd=SRC_DIR, capture_output=True, text=True
    )
    elapsed = time.time() - t0

    if sim_result.returncode != 0:
        return f"FAIL (sim exit {sim_result.returncode})", (sim_result.stderr or sim_result.stdout)[-800:]

    # Check for simulation assertion failures in output
    combined = sim_result.stdout + sim_result.stderr
    if "assertion violation" in combined.lower() or "error" in combined.lower():
        # Filter out expected "note" lines; only flag real errors
        error_lines = [l for l in combined.splitlines()
                       if "error" in l.lower() and "note" not in l.lower()]
        if error_lines:
            return "FAIL (sim error)", "\n".join(error_lines[:5])

    # Generate image
    if gen_images and os.path.exists(DUMP_FILE):
        png_path = os.path.join(TOOLS_DIR, name + ".png")
        generate_image(DUMP_FILE, png_path)

    return f"PASS ({elapsed:.1f}s)", ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run all automated processor tests")
    parser.add_argument("--no-rebuild", action="store_true",
                        help="Skip VHDL rebuild (use existing simulation binary)")
    parser.add_argument("--no-images", action="store_true",
                        help="Skip PNG image generation")
    args = parser.parse_args()

    # Discover numbered tests: test01_*.s, test02_*.s, ...
    pattern = os.path.join(TOOLS_DIR, "test[0-9][0-9]_*.s")
    test_files = sorted(glob.glob(pattern))

    if not test_files:
        print(f"No test files found matching {pattern}")
        sys.exit(1)

    if not args.no_rebuild:
        build_once()
    elif not os.path.exists(SIM_EXE):
        print(f"Simulation binary not found: {SIM_EXE}")
        print("Run without --no-rebuild first.")
        sys.exit(1)

    results = []
    for asm_file in test_files:
        name = os.path.splitext(os.path.basename(asm_file))[0]
        print(f"  {name} ... ", end="", flush=True)
        status, detail = run_test(asm_file, not args.no_images)
        print(status)
        if detail:
            for line in detail.splitlines()[:5]:
                print(f"    {line}")
        results.append((name, status))

    # Summary
    print()
    print("=" * 60)
    print("RESULTS")
    print("=" * 60)
    passed = 0
    for name, status in results:
        mark = "✓" if status.startswith("PASS") else "✗"
        print(f"  {mark} {name:<35} {status}")
        if status.startswith("PASS"):
            passed += 1
    print()
    print(f"  {passed}/{len(results)} tests passed")
    print("=" * 60)

    if passed < len(results):
        sys.exit(1)


if __name__ == "__main__":
    main()
