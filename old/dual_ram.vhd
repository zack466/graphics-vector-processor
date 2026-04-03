------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 Sep 24      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- This entity describes a true dual-port synchronous RAM with read enables. It
-- has two independent ports, Port A and Port B, each with its own write enable
-- and read enable signal. The outputs are registered to improve timing
-- performance.
entity Ram_Dual_Port is
    generic (
        G_DATA_WIDTH : natural := 32;   -- Width of the data bus
        G_ADDR_WIDTH : natural := 8     -- Width of the address bus (RAM depth = 2^G_ADDR_WIDTH)
    );
    port (
        -- System Inputs
        i_clk   : in  std_logic;    -- System clock (both ports share the same clock)
        i_rst   : in  std_logic;    -- Asynchronous reset

        -- Port A Interface
        i_we_a    : in  std_logic;                                      -- Write enable for Port A
        i_re_a    : in  std_logic;                                      -- Read enable for Port A
        i_addr_a  : in  std_logic_vector(G_ADDR_WIDTH - 1 downto 0);    -- Address for Port A
        i_data_a  : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);    -- Data input for Port A
        o_data_a  : out std_logic_vector(G_DATA_WIDTH - 1 downto 0);    -- Registered data output for Port A

        -- Port B Interface
        i_we_b    : in  std_logic;                                      -- Write enable for Port B
        i_re_b    : in  std_logic;                                      -- Read enable for Port B
        i_addr_b  : in  std_logic_vector(G_ADDR_WIDTH - 1 downto 0);    -- Address for Port B
        i_data_b  : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);    -- Data input for Port B
        o_data_b  : out std_logic_vector(G_DATA_WIDTH - 1 downto 0)     -- Registered data output for Port B
    );
end entity Ram_Dual_Port;

architecture rtl of Ram_Dual_Port is

    -- Constants
    constant C_RAM_DEPTH : natural := 2**G_ADDR_WIDTH;

    -- Types
    -- Define the memory array type
    type t_ram is array (0 to C_RAM_DEPTH - 1) of std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    -- Signals
    signal s_ram : t_ram;   -- The shared RAM memory array

    -- Synthesis attribute to guide Quartus on which memory resource to use.
    attribute ramstyle : string;
    attribute ramstyle of s_ram : signal is "M10K"; -- Explicitly suggest M10K for Cyclone V, ~5 Mb total

begin

    -- This single process handles all memory operations for both ports.
    -- The read enable signals act as clock enables for the output registers.
    p_ram_access : process (i_clk, i_rst)
    begin
        if i_rst = '1' then
            -- Block RAMs do not have a synchronous reset for their contents.
            -- This is for simulation purposes only.
            null;
        elsif rising_edge(i_clk) then
            -- Port A Operations
            if i_we_a = '1' then
                s_ram(to_integer(unsigned(i_addr_a))) <= i_data_a;
            end if;

            -- If read enable is active, register the data from the specified address.
            -- This maintains the registered output and "read-before-write" behavior.
            if i_re_a = '1' then
                o_data_a <= s_ram(to_integer(unsigned(i_addr_a)));
            end if;

            -- Port B Operations
            if i_we_b = '1' then
                s_ram(to_integer(unsigned(i_addr_b))) <= i_data_b;
            end if;

            -- If read enable is active, register the data from the specified address.
            if i_re_b = '1' then
                o_data_b <= s_ram(to_integer(unsigned(i_addr_b)));
            end if;
        end if;
    end process p_ram_access;

end architecture rtl;
