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

        -- Data data/address bus + read/write signals
        ab          : out std_logic_vector(31 downto 0);
        db_in       : in  std_logic_vector(127 downto 0);
        db_out      : out std_logic_vector(127 downto 0);
        mem_rdy     : in  std_logic;

        rd          : out std_logic;
        wr          : out std_logic 
    );

    constant NUM_REGS : integer := 16;

end Core;

architecture structural of Core is

begin


end structural;

