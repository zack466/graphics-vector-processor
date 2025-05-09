----------------------------------------------------------------------------
--
--  Vector Register Array
--
--  This is an implementation of a Register Array containing 128-bit vectors,
--  used in the path tracing processor.
--
--  Entities included are:
--     VectorRegArray  - the vector register array
--
--  Revision History:
--     25 May 09    Zack Huang      Initial revision
--
----------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

use work.types.all;


entity  VectorRegArray  is

    generic (
        regcnt   : integer := 16     -- default number of registers is 16
    );

    port(
        VecIn      : in   Vector;
        VecInSel   : in   integer  range regcnt - 1 downto 0;
        VecStore   : in   std_logic;
        VecASel    : in   integer  range regcnt - 1 downto 0;
        VecBSel    : in   integer  range regcnt - 1 downto 0;
        clock      : in   std_logic;
        reset      : in   std_logic;
        VecA       : out  Vector;
        VecB       : out  Vector
    );

end  VectorRegArray;


architecture structural of VectorRegArray is

    signal RegIn    : std_logic_vector(127 downto 0);
    signal RegA     : std_logic_vector(127 downto 0);
    signal RegB     : std_logic_vector(127 downto 0);
    
begin

    RegIn <= to_slv(to_float(VecIn.x)) &
             to_slv(to_float(VecIn.y)) &
             to_slv(to_float(VecIn.z)) &
             to_slv(to_float(VecIn.a));

    VecA <= (
        x => to_real(to_float(RegA(127 downto 96))),
        y => to_real(to_float(RegA(95 downto 64))),
        z => to_real(to_float(RegA(63 downto 32))),
        a => to_real(to_float(RegA(31 downto 0)))
    );
    
    internal_array: entity work.RegArray
    generic map (
        regcnt => regcnt,
        wordsize => 128
    )
    port map (
        RegIn => RegIn,
        RegInSel => VecInSel,
        RegStore => VecStore,
        RegASel => VecASel,
        RegBSel => VecBSel,
        clock => clock,
        reset => reset,
        RegA => RegA,
        RegB => RegB,

        -- unused
        RegAxIn => (others => '0'),
        RegAxInSel => 0,
        RegAxStore => '0',
        RegA1Sel => 0,
        RegA2Sel => 0,
        RegDIn => (others => '0'),
        RegDInSel => 0,
        RegDStore => '0',
        RegDSel => 0
    );
    
    
end architecture structural;
