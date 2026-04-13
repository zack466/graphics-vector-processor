"""
runner.py — Run automated processor tests.

Usage (from repo root):
    python tools/runner.py [test_names...] [--no-rebuild] [--no-images]

Examples:
    python tools/runner.py                        # Runs all tests
    python tools/runner.py test09                 # Runs any test matching 'test09'
    python tools/runner.py tools/test01_basic.s   # Runs a specific file

Workflow:
    1. Build VHDL once (make clean && make build in src/, then elaborate tb_frame_processor_automated)
    2. For each matched tools/test[0-9][0-9]_*.s (sorted):
       a. Parse assembly file for # WIDTH: X and # HEIGHT: Y comments
       b. Assemble to src/program.hex
       c. Run the simulation executable with -gFRAME_WIDTH=X -gFRAME_HEIGHT=Y
       d. Optionally generate a PNG image of size X by Y from src/memory_dump.hex
       e. Report PASS / FAIL
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
import re

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
# Image generation
# ---------------------------------------------------------------------------

def hex_to_float(hex_str):
    if 'X' in hex_str or 'U' in hex_str:
        return 0.0
    try:
        int_val = int(hex_str, 16)
        return struct.unpack('!f', struct.pack('!I', int_val))[0]
    except Exception:
        return 0.0


def generate_image(dump_file, output_png, width, height):
    from PIL import Image
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

    if not pixels or width * height == 0:
        return

    # Pad with transparent pixels if the dump was shorter than expected
    expected_pixels = width * height
    if len(pixels) < expected_pixels:
        pixels.extend([(0, 0, 0, 0)] * (expected_pixels - len(pixels)))

    img = Image.new('RGBA', (width, height))
    img.putdata(pixels[:expected_pixels])
    img.save(output_png)
    print(f"    Saved {os.path.basename(output_png)} ({width}x{height})")


# ---------------------------------------------------------------------------
# Run one test
# ---------------------------------------------------------------------------

def run_test(asm_file, gen_images):
    name = os.path.splitext(os.path.basename(asm_file))[0]

    # Parse assembly file for dimensions
    width = 32
    height = 32
    with open(asm_file, 'r') as f:
        for line in f:
            # Only parse comments at the top of the file
            if line.startswith('#') or line.startswith('//'):
                w_match = re.search(r'WIDTH:\s*(\d+)', line, re.IGNORECASE)
                h_match = re.search(r'HEIGHT:\s*(\d+)', line, re.IGNORECASE)
                if w_match: width = int(w_match.group(1))
                if h_match: height = int(h_match.group(1))
            elif line.strip():
                # Stop looking once we hit actual code
                break

    # Assemble
    asm_result = subprocess.run(
        [sys.executable, os.path.join(TOOLS_DIR, "assembler.py"), asm_file, HEX_FILE],
        capture_output=True, text=True
    )
    if asm_result.returncode != 0:
        return "FAIL (assembler error)", asm_result.stderr.strip()

    # Simulate with dynamic dimensions
    t0 = time.time()
    sim_cmd = [SIM_EXE] + RUNFLAGS + [f"-gFRAME_WIDTH={width}", f"-gFRAME_HEIGHT={height}"]
    
    sim_result = subprocess.run(
        sim_cmd,
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
        generate_image(DUMP_FILE, png_path, width, height)

    return f"PASS ({elapsed:.1f}s)", ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run automated processor tests")
    parser.add_argument("tests", nargs="*", 
                        help="Optional: Specific test files or names to run (e.g. 'test09' or 'tools/test01_basic.s'). If omitted, runs all tests.")
    parser.add_argument("--no-rebuild", action="store_true",
                        help="Skip VHDL rebuild (use existing simulation binary)")
    parser.add_argument("--no-images", action="store_true",
                        help="Skip PNG image generation")
    args = parser.parse_args()

    # Discover all numbered tests
    pattern = os.path.join(TOOLS_DIR, "test[0-9][0-9]_*.s")
    all_test_files = sorted(glob.glob(pattern))

    if not all_test_files:
        print(f"No test files found matching {pattern}")
        sys.exit(1)

    # Filter tests based on user arguments
    if args.tests:
        test_files = []
        for t in args.tests:
            if os.path.exists(t) and t.endswith('.s'):
                # Explicit path provided
                test_files.append(t)
            else:
                # Substring match against available files
                matched = [f for f in all_test_files if t in os.path.basename(f)]
                if matched:
                    test_files.extend(matched)
                else:
                    print(f"Warning: Could not find any test matching '{t}'")
        
        # Deduplicate and sort
        test_files = sorted(list(set(test_files)))
        
        if not test_files:
            print("No valid tests found to run. Exiting.")
            sys.exit(1)
    else:
        test_files = all_test_files

    # Build phase
    if not args.no_rebuild:
        build_once()
    elif not os.path.exists(SIM_EXE):
        print(f"Simulation binary not found: {SIM_EXE}")
        print("Run without --no-rebuild first.")
        sys.exit(1)

    # Run phase
    results = []
    for asm_file in test_files:
        name = os.path.splitext(os.path.basename(asm_file))[0]
        print(f"  {name:<30} ... ", end="", flush=True)
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
