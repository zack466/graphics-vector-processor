--------------------------------------------------------------------------------
-- Package Definition
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package vector_types_pkg is
    subtype word_t is std_logic_vector(31 downto 0);
    type vector_t is array (0 to 3) of word_t;
    type swizzle_sel_t is array (0 to 3) of std_logic_vector(1 downto 0);
end package;
