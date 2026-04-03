-- Execution unit

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;
use work.ALUconstants.all;

entity Execute is
    port (
        clock       : in  std_logic;
        ready       : out std_logic                         -- if the current operation has finished executing
        
        -- TODO: add in required signals
    );

end Execute;

architecture structural of execute is
    
begin

    -- Parameters:
    --  - generic N: number of parallel execution contexts (can assume to be power of 2)
    --  - generic M: number of physical floating point units (assume to be power of 2, less than N)
    --  - generic type register_file_t, consisting of W bits
    -- Registers:
    --  - an array of N register_file_t's
    --  - note that a single vector register consiste of four 32-bit components (Ex: V0 refers to R0, R1, R2, and R3 as a vector)
    -- Takes as input: 32-bit instruction
    -- Implement a state machine as follows:
    --  - idle: does nothing until an instruction is received, then set ready to 0.
    --  - Then, based on the instruction, may transition to one of the following:
    --    - vector_floating: (do one of these per clock)
    --      - for each execution unit i from 1 to N:
    --        - submit four parallel floating-point operations into the operation pipeline (one for each component of two vector registers)
    --    - floating: (do one of these per clock)
    --      - for each execution unit i from 1 to N:
    --        - submit a floating-point operations into the operation pipeline (involving two registers)
    --    - integer: (do one of these per clock)
    --      - for each execution unit i from 1 to N:
    --        - submit an integer operation into the operation pipeline (involving two registers)
    --    - move: (do one of these per clock)
    --      - for each execution unit i from 1 to N:
    --        - submit an operation into the operation pipeline that moves bits between two registers
    --    - memory: (do one of these per clock)
    --      - for each execution unit i from 1 to N:
    --        - coalesce memory requests and prepare to read/write data between registers and memory
    --  - Once the instruction is completed, set ready to 1 and go back to the idle state.
    
end architecture structural;
