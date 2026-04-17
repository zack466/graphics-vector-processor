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

entity fp_multiply_add_0 is
    generic( latency : integer := 22 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b, c: in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_multiply_add_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_div_0 is
    generic( latency : integer := 14 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_div_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_sqrt_0 is
    generic( latency : integer := 9 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_sqrt_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_min_0 is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_min_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_max_0 is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_max_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_sin_0 is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_sin_0;

-- fp_cos_0 removed: cosine IP was eliminated to save ~600-700 ALMs per FPU lane.
-- Use SIN with a phase-offset (cos(x) = sin(x + pi/2)) in the shader instead.

library ieee;
use ieee.std_logic_1164.all;

entity fp_log2_0 is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_log2_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_exp2_0 is
    generic( latency : integer := 17 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_exp2_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_lt_0 is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(0 downto 0) 
    );
end entity fp_lt_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_eq_0 is
    generic( latency : integer := 3 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a, b   : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(0 downto 0) 
    );
end entity fp_eq_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_fix2float_0 is
    generic( latency : integer := 6 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_fix2float_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_float2fix_0 is
    generic( latency : integer := 6 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_float2fix_0;

library ieee;
use ieee.std_logic_1164.all;

entity fp_rcp_0 is
    generic( latency : integer := 14 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_rcp_0;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity fp_scalar_product_0 is
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
end entity fp_scalar_product_0; 
