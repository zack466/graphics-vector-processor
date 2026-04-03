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
use work.ALUConstants.all;

entity core_ALU_tb is
end core_ALU_tb;

architecture behavioral of core_ALU_tb is

    -- Stimulus signals for unit under test
    signal clock        : std_logic;
    signal OpA          : Vector;
    signal OpB          : Vector;
    signal scalar       : std_logic;                        -- use "a" instead of "x", "y", and "z"
    signal parOp        : std_logic_vector(3 downto 0);     -- parallel operation
    signal redOp        : std_logic_vector(1 downto 0);     -- reduction operation
    signal negMask      : std_logic_vector(3 downto 0);     -- negation mask (pre-operation)
    signal outMask      : std_logic_vector(3 downto 0);     -- update mask (post-operation)

    -- Outputs from unit under test
    signal OpC          : Vector;

begin

    -- Instantiate UUT
    UUT: entity work.ALU
    port map(
        clock => clock,
        OpA => OpA,
        OpB => OpB,
        scalar => scalar,
        parOp => parOp,
        redOp => redOp,
        negMask => negMask,
        outMask => outMask,
        OpC => OpC
    );

    process
        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;
    begin
        OpA <= ( x => 0.0, y => 1.0, z => 1.0, a => 0.1 );
        OpB <= ( x => 1.0, y => 1.0, z => 0.5, a => 0.1 );
        scalar <= '1';
        ParOp <= ParOp_DIV;
        RedOp <= RedOp_SUM;
        negMask <= "0000";
        outMask <= "1111";

        Tick;

        report vector_to_string(OpC);

        wait;
        
    end process ;


end behavioral;
