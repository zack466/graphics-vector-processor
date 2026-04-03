------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 May 14      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity Control is
    port (
        clock       : in  std_logic;    -- system clock
        reset       : in  std_logic;    -- system reset

        -- Program data/address bus
        program_ab  : out std_logic_vector(31 downto 0);
        program_db  : in  std_logic_vector(31 downto 0)
    );

    constant NUM_REGS : integer := 16;

    signal IR : std_logic_vector(31 downto 0);

    type state is (
        fetch,
        execute,
        memory_access
    );

    signal curr_state : state;
    signal next_state : state;
    signal execute_counter : unsigned(5 downto 0);

    -- ALU signals
    signal neg_mask     : std_logic_vector(3 downto 0);
    signal scalar       : std_logic;
    signal reduce_op    : std_logic_vector(3 downto 0);
    signal parallel_op  : std_logic_vector(3 downto 0);
    signal out_mask     : std_logic_vector(3 downto 0);
    signal dest_reg     : std_logic_vector(3 downto 0);
    signal target_reg   : std_logic_vector(3 downto 0);

    -- register array control signals
    signal RegIn      : std_logic_vector(31 downto 0);
    signal RegInSel   : integer  range 63 downto 0;
    signal RegStore   : std_logic;
    signal RegASel    : integer  range 63 downto 0;
    signal RegBSel    : integer  range 63 downto 0;
    signal RegQIn     : std_logic_vector(127 downto 0);
    signal RegQInSel  : integer  range 15 downto 0;
    signal RegQStore  : std_logic;
    signal RegQSel    : integer  range 15 downto 0;

    -- Outputs to execution unit
    signal float_op     : std_logic_vector(4 downto 0);     -- which floating point operation to perform

end Control;

architecture structural of Control is

    -- The task is to implement a state machine that does the following:
    -- Idle: do nothing, loop
    -- memory_access: not yet specified, but it involves a loop waiting for a read/write to complete
    -- Execute: perform a sequence of FPU (floating point unit) operations to modify a vector, or four consecutive 32-bit registers
    --   - the instruction flow looks like: (after instruction decoding)
    --   - 1. conditionally submit "negate" to the FPU (for the negation mask)
    --   - 2. submit "parallel" operations to the FPU, e.g. multiple of the same operations that acts on the components of a vector register in parallel
    --   - 3. submit "reduction" operations to the FPU, e.g. multiple of the same operations that reduces the components of a vector, such as summing them all and putting them in the fourth component
    --   - since the FPU is pipelined, each operation is accompanied by tag bits that specify:
    --     - the destination register for the final result
    --     - if the instruction is the last instruction to be done
    --   - the FPU deals with pipelining, so the CPU should only have to submit all of these micro-ops (four at a time) and wait for the last one before moving on to the next stage (e.g. first submitting all the negate operations, then the parallel, then reduction, etc)

begin

    clock_proc: process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                
            else
                
            end if;
        end if;
    end process clock_proc;

end structural;

