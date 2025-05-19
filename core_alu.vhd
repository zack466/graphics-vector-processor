------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 May 14      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package  ALUConstants  is

    constant ParOp_ADD  : std_logic_vector := "0000";
    constant ParOp_SUB  : std_logic_vector := "0001";
    constant ParOp_MUL  : std_logic_vector := "0010";
    constant ParOp_DIV  : std_logic_vector := "0011";

    constant RedOp_NONE : std_logic_vector := "00";
    constant RedOp_SUM  : std_logic_vector := "01";

end package;


-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;
use work.ALUconstants.all;

entity ALU is
    port (
        clock       : in  std_logic;
        OpA         : in  Vector;
        OpB         : in  Vector;
        scalar      : in  std_logic;                        -- use "a" instead of "x", "y", and "z"
        parOp       : in  std_logic_vector(3 downto 0);     -- parallel operation
        redOp       : in  std_logic_vector(1 downto 0);     -- reduction operation
        negMask     : in  std_logic_vector(3 downto 0);     -- negation mask (pre-operation)
        outMask     : in  std_logic_vector(3 downto 0);     -- update mask (post-operation)

        OpC         : out Vector
    );
end ALU;

architecture dataflow of ALU is

    signal R0 : real;
    signal R1 : real;
    signal R2 : real;
    signal R3 : real;

    signal R4 : real;
    signal R5 : real;
    signal R6 : real;
    signal R7 : real;

    signal R8  : real;
    signal R9  : real;
    signal R10 : real;
    signal R11 : real;

    signal R12 : real;
    signal R13 : real;
    signal R14 : real;
    signal R15 : real;

begin

    R0 <= OpA.x when negMask(0) = '0' else -OpA.x;
    R1 <= OpA.y when negMask(1) = '0' else -OpA.y;
    R2 <= OpA.z when negMask(2) = '0' else -OpA.z;
    R3 <= OpA.a when negMask(3) = '0' else -OpA.a;

    R4 <= OpB.x when scalar = '0' else opB.a;
    R5 <= OpB.y when scalar = '0' else opB.a;
    R6 <= OpB.z when scalar = '0' else opB.a;
    R7 <= OpB.a;

    parallel_operation: process (clock, R0, R1, R2, R3, R4, R5, R6, R7) is
    begin
        if rising_edge(clock) then
            if parOp = ParOP_ADD then
                R8 <= R0 + R4;
                R9 <= R1 + R5;
                R10 <= R2 + R6;
                R11 <= R3 + R7;
            elsif ParOp = ParOp_SUB then
                R8 <= R0 - R4;
                R9 <= R1 - R5;
                R10 <= R2 - R6;
                R11 <= R3 - R7;
            elsif ParOp = ParOp_MUL then
                R8 <= R0 * R4;
                R9 <= R1 * R5;
                R10 <= R2 * R6;
                R11 <= R3 * R7;
            elsif ParOp = ParOp_DIV then
                R8 <= R0 / R4;
                R9 <= R1 / R5;
                R10 <= R2 / R6;
                R11 <= R3 / R7;
            end if;
        end if;
    end process;

    reduction_operation: process (R8, R9, R10, R11) is
    begin
        R12 <= R8 when outMask(0) = '1' else R0;
        R13 <= R9 when outMask(1) = '1' else R1;
        R14 <= R10 when outMask(2) = '1' else R2;
        if redOp = RedOP_NONE then
            R15 <= R11 when outMask(3) = '1' else R3;
        elsif RedOp = RedOp_SUM then
            R15 <= R8 + R9 + R10 when outMask(3) = '1' else R3;
        end if;
    end process;

    OpC <= (
        x => R12,
        y => R13,
        z => R14,
        a => R15
    );

end dataflow;
