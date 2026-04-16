library ieee;
use ieee.std_logic_1164.all;

package fp_sim_types is
    -- Type for vector operations (dimension of 4, 32-bit floats)
    type slv_array_4 is array (0 to 3) of std_logic_vector(31 downto 0);
end package fp_sim_types;

---------------------------------------------------------
-- Pipeline Entities
---------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

entity Pipeline is
    generic ( latency : integer := 1 );
    port(
        clock    : in std_logic;
        data_in  : in real;
        data_out : out real
    );
end Pipeline;

library ieee;
use ieee.std_logic_1164.all;

entity Pipeline_sl is
    generic ( latency : integer := 1 );
    port(
        clock    : in std_logic;
        data_in  : in std_logic;
        data_out : out std_logic
    );
end Pipeline_sl;

---------------------------------------------------------
-- Floating Point Arithmetic Entities
---------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use work.fp_sim_types.all;

entity fp_multiply_add is
    generic( latency : integer := 22 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b, c: in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_multiply_add;

library ieee;
use ieee.std_logic_1164.all;

entity fp_div is
    generic( latency : integer := 14 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_div;

library ieee;
use ieee.std_logic_1164.all;

entity fp_sqrt is
    generic( latency : integer := 9 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_sqrt;

library ieee;
use ieee.std_logic_1164.all;

entity fp_rsqrt is
    generic( latency : integer := 28 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_rsqrt;

library ieee;
use ieee.std_logic_1164.all;

entity fp_min is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_min;

library ieee;
use ieee.std_logic_1164.all;

entity fp_max is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_max;

library ieee;
use ieee.std_logic_1164.all;

entity fp_sin is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_sin;

library ieee;
use ieee.std_logic_1164.all;

entity fp_cos is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_cos;

library ieee;
use ieee.std_logic_1164.all;

entity fp_log2 is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_log2;

library ieee;
use ieee.std_logic_1164.all;

entity fp_exp2 is
    generic( latency : integer := 17 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_exp2;

library ieee;
use ieee.std_logic_1164.all;

entity fp_lt is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(0 downto 0) 
    );
end entity fp_lt;

library ieee;
use ieee.std_logic_1164.all;

entity fp_eq is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(0 downto 0) 
    );
end entity fp_eq;

library ieee;
use ieee.std_logic_1164.all;

entity fp_fix2float is
    generic( latency : integer := 6 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_fix2float;

library ieee;
use ieee.std_logic_1164.all;

entity fp_float2fix is
    generic( latency : integer := 6 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_float2fix;

library ieee;
use ieee.std_logic_1164.all;

entity fp_rcp is
    generic( latency : integer := 14 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_rcp;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity fp_scalar_product is
    generic( latency : integer := 37 );
    port (
        clk    : in  std_logic                     := '0';             --    clk.clk
        areset : in  std_logic                     := '0';             -- areset.reset
        a0     : in  std_logic_vector(31 downto 0) := (others => '0'); --     a0.a0
        b0     : in  std_logic_vector(31 downto 0) := (others => '0'); --     b0.b0
        a1     : in  std_logic_vector(31 downto 0) := (others => '0'); --     a1.a1
        b1     : in  std_logic_vector(31 downto 0) := (others => '0'); --     b1.b1
        a2     : in  std_logic_vector(31 downto 0) := (others => '0'); --     a2.a2
        b2     : in  std_logic_vector(31 downto 0) := (others => '0'); --     b2.b2
        a3     : in  std_logic_vector(31 downto 0) := (others => '0'); --     a3.a3
        b3     : in  std_logic_vector(31 downto 0) := (others => '0'); --     b3.b3
        q      : out std_logic_vector(31 downto 0)                     --      q.q
    );
end entity fp_scalar_product; 
