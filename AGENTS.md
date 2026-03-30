# Agent Instructions: Graphics Vector Processing Unit

Welcome! This document contains context and guidelines for autonomous agents working on this repository.

## Running the Project
**IMPORTANT:** You must use `make` to compile and simulate the files in this repository.
If you add any source files for designs/testbenches, they must be added to the Makefile in the same directory as your modification.

## Project Overview
This project is vector-based graphics processor in VHDL, intended to run on a Intel Cyclone V SE 5CSEBA6U23I7 device (110K LEs, 112 DSP blocks, 557 M10K blocks).
The processor acts on 128-bit tuples (x, y, z, a) of standard IEEE 32-bit floating-point numbers.

## Technical Stack & Architecture
- **Simulation:** Uses `GHDL` for all testbenching and simulation.
- **Synthesis:** Will `Quartus` for synthesis. Quartus project files are in a separate repository.
- **Waveform Viewer:** Uses `gtkwave` to view waveforms.

## VHDL Style
When writing designs/testbenches in VHDL, always abide by these guideleines:
- Use VHDL-2008 constructs to make testbench code easier to read/write. Using VHDL-1993 constructs in designs is preferred for compatibility.
- Always obey strict synchronous design principles. Testbench code should synchronize itself using `wait until rising_edge(clk)` and should never have arbitrary waits like `wait until 1 ns`.
- Always add brief, informative comments for each declared input/output/signal. Also add comments for all processes or statements that do something non-obvious.
- Otherwise, try to follow the style of the existing code for naming and general style
