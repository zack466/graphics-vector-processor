----------------------------------------------------------------------------
--
--  Generic Register Array
--
--  This is an implementation of a Register Array for register-based
--  microprocessors. It allows the registers to be accessed as single words or
--  quad words. This is intended to be used for a ray-tracing processor, which
--  utilizes 32-bit floats, which are also intended to be organized in 128-bit
--  float vectors.
--
--  Entities included are:
--     RegArray  - the register array
--
--  Revision History:
--     25 Jan 21  Glen George       Initial revision.
--     11 Apr 25  Glen George       Added separate address register interface.
--     14 Jun 25  Zack Huang        Removed address registers and added quadword
--                                  interface (to be used as a vector)
--
----------------------------------------------------------------------------


--
--  RegArray
--
--  This is a generic register array.  It contains regcnt wordsize bit
--  registers along with the appropriate reading and writing controls.  The
--  registers can also be read and written as quadruple width registers.
--
--  Generics:
--    regcnt   - number of registers in the array (must be a multiple of 4)
--    wordsize - width of each register
--
--  Inputs:
--    RegIn      - input bus to the registers
--    RegInSel   - which register to write (log regcnt bits)
--    RegStore   - actually write to a register
--    RegASel    - register to read onto bus A (log regcnt bits)
--    RegBSel    - register to read onto bus B (log regcnt bits)
--    RegQIn     - input bus to the quadruple-width registers
--    RegQInSel  - which quad register to write (log regcnt bits - 2)
--    RegQStore  - actually write to a quad register
--    RegQSel    - register to read onto quad width bus Q (log regcnt bits - 2)
--    clock      - the system clock
--    reset      - the system reset (async, active low)
--
--  Outputs:
--    RegA       - register value for bus A
--    RegB       - register value for bus B
--    RegQ       - register value for bus Q (quadruple width bus)
--

library ieee;
use ieee.std_logic_1164.all;

entity  RegArray  is

    generic (
        regcnt   : integer := 64;    -- default number of registers is 64
        wordsize : integer := 32     -- default width is 32 bits
    );

    port(
        RegIn      : in   std_logic_vector(wordsize - 1 downto 0);
        RegInSel   : in   integer  range regcnt - 1 downto 0;
        RegStore   : in   std_logic;
        RegASel    : in   integer  range regcnt - 1 downto 0;
        RegBSel    : in   integer  range regcnt - 1 downto 0;
        RegQIn     : in   std_logic_vector(4 * wordsize - 1 downto 0);
        RegQInSel  : in   integer  range regcnt/4 - 1 downto 0;
        RegQStore  : in   std_logic;
        RegQSel    : in   integer  range regcnt/4 - 1 downto 0;
        clock      : in   std_logic;
        reset      : in   std_logic;
        RegA       : out  std_logic_vector(wordsize - 1 downto 0);
        RegB       : out  std_logic_vector(wordsize - 1 downto 0);
        RegQ       : out  std_logic_vector(4 * wordsize - 1 downto 0)
    );

end  RegArray;


architecture  behavioral  of  RegArray  is

    type  RegType  is array (regcnt - 1 downto 0) of
                      std_logic_vector(wordsize - 1 downto 0);

    signal  Registers : RegType;                -- the register array

    -- aliases for the quad input words
    alias  RegQIn3 : std_logic_vector(wordsize - 1 downto 0) is RegQIn(4 * wordsize - 1 downto 3 * wordsize);
    alias  RegQIn2 : std_logic_vector(wordsize - 1 downto 0) is RegQIn(3 * wordsize - 1 downto 2 * wordsize);
    alias  RegQIn1 : std_logic_vector(wordsize - 1 downto 0) is RegQIn(2 * wordsize - 1 downto wordsize);
    alias  RegQIn0 : std_logic_vector(wordsize - 1 downto 0) is RegQIn(wordsize - 1 downto 0);

begin

    -- setup the outputs - choose based on select signals
    RegA   <=  Registers(RegASel);
    RegB   <=  Registers(RegBSel);
    RegQ   <=  Registers(4 * RegQSel + 3) & Registers(4 * RegQSel + 2) & 
               Registers(4 * RegQSel + 1) & Registers(4 * RegQSel);


    -- only write registers on the clock, plus async reset (active low)
    process(clock, reset)
    begin
        if (reset = '0') then
            -- set all registers to 0 on async reset
            Registers  <=  (others => (others => '0'));
        elsif  rising_edge(clock)  then
            -- update registers on clock rising edge

            -- handle quad word stores
            if (RegQStore = '1')  then
                Registers(4 * RegQInSel + 3)  <=  RegQIn3;
                Registers(4 * RegQInSel + 2)  <=  RegQIn2;
                Registers(4 * RegQInSel + 1)  <=  RegQIn1;
                Registers(4 * RegQInSel)      <=  RegQIn0;
            end if;

            -- handle normal stores last so they have highest precedence
            if (RegStore = '1')  then
                Registers(RegInSel)  <=  RegIn;
            end if;
        else
            -- have registers retain their value
            Registers  <=  Registers;
        end if;

    end process;

end  behavioral;

