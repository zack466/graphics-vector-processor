# Agent Instructions: Graphics Vector Processing Unit

Welcome! This document contains context and guidelines for autonomous agents working on this repository.

## Running the Project
The VHDL designs are located in `src/`, and the testbenches can be run using `cd src && make test-XXX` where XXX is the name of the testbench.
The testbenches can all be listed using `cd src && make test`.
If you add any source files for designs/testbenches, they must be added to the Makefile in the same directory as your modification.
Furthermore, a set of automated testbenches are located in `tools/` and can be run using the Python scripts in that directory.

## Project Overview
This project is vector-based graphics processor in VHDL, intended to run on a Intel Cyclone V SE 5CSEBA6U23I7 device (110K LEs, 112 DSP blocks, 557 M10K blocks).
The processor acts on 128-bit tuples (x, y, z, w) of standard IEEE 32-bit floating-point numbers.

## Technical Stack & Architecture
- **Simulation:** Uses `GHDL` for all testbenching and simulation.
- **Synthesis:** Will use `Quartus` for synthesis. Quartus project files are in a separate repository.
- **Waveform Viewer:** Uses `gtkwave` to view waveforms.
- **Toolchain:** Uses `python` for assembly, simulating entire programs, and checking the output pixel data.

## VHDL Style
When writing designs/testbenches in VHDL, always abide by these guideleines:
- Use VHDL-2008 constructs to make testbench code easier to read/write. Using VHDL-1993 constructs in designs is preferred for compatibility.
- Always obey strict synchronous design principles. Testbench code should synchronize itself using `wait until rising_edge(clk)` and should never have arbitrary waits like `wait until 1 ns`.
- Always add brief, informative comments for each declared input/output/signal. Also add comments for all processes or statements that do something non-obvious.
- All implementation designs should be well-documented, and VHDL entities should include a block of comments explaining how the entity is used, inputs/outputs, and exact timing/clock constraints.
- Try to follow the style of the existing code for naming and general style

## Development Process
After making changes or fixing a bug, log your progress and **append** it to a file called `journal.md` in the project's root directory.
When modifying a file with nontrivial changes, always ensure that the comments in the file are kept up-to-date.
Furthermore, changes to the design of the project should be kept up-to-date in `README.md`, which contains the design document.
