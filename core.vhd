------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 May 09      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity Core is
    port (
        clock       : in  std_logic;    -- system clock
        reset       : in  std_logic;    -- system reset

        -- Program data/address bus
        program_ab  : out std_logic_vector(31 downto 0);
        program_db  : in  std_logic_vector(31 downto 0);

        -- Data data/address bus + read/write signals
        data_ab     : out std_logic_vector(31 downto 0);
        data_db     : inout std_logic_vector(127 downto 0);
        rd          : out std_logic;
        wr          : out std_logic 
    );

    constant NUM_REGS : integer := 16;

end Core;

architecture structural of Core is

    signal VecIn      : Vector;
    signal VecInSel   : integer  range NUM_REGS - 1 downto 0;
    signal VecStore   : std_logic;
    signal VecASel    : integer  range NUM_REGS - 1 downto 0;
    signal VecBSel    : integer  range NUM_REGS - 1 downto 0;
    signal VecA       : Vector;
    signal VecB       : Vector;

begin

    registers: entity work.VectorRegArray
    generic map (
        regcnt => NUM_REGS
    )
    port map (
        VecIn => VecIn,
        VecInSel => VecInSel,
        VecStore => VecStore,
        VecASel => VecASel,
        VecBSel => VecBSel,
        clock => clock,
        reset => reset,
        VecA => VecA,
        VecB => VecB
    );

end structural;

