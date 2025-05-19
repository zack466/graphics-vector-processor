------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     25 May 14    Zack Huang      Initial Revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.types.all;
use work.util.all;

entity core_tb is
end core_tb;

architecture behavioral of core_tb is

begin
    -- Instantiate UUT
    UUT: entity work.Core
    port map(
    );

    process is

    begin

        wait;
    end process;
end behavioral;
