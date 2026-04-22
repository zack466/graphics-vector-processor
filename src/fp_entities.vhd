-- ============================================================================
-- FILE: fp_entities.vhd
-- ============================================================================
--
-- Wrapper entity declarations for all floating-point and pipeline operations
-- used by the execution unit. Each entity has two architecture implementations:
-- a structural one instantiating the corresponding Altera floating-point IP
-- core, and a pipelined simulation model used in automated testbenches.
--
-- This separation allows the target architecture to be switched between the
-- Altera IP and the simulation model without modifying any instantiation sites
-- in the top-level design.
--
-- The `latency` generic reflects the pipeline depth of the Altera IP core it
-- corresponds to. It has no effect in the structural (IP) architecture and is
-- used only by the simulation models to replicate the correct output delay.
--
-- Entities:
--   Pipeline              : Delay line for real-valued signals.
--   Pipeline_sl           : Delay line for std_logic signals.
--   fp_multiply_add_0     : Fused multiply-add (a*b + c).
--   fp_div_0              : Floating-point division.
--   fp_sqrt_0             : Floating-point square root.
--   fp_min_0              : Floating-point minimum of two inputs.
--   fp_max_0              : Floating-point maximum of two inputs.
--   fp_sin_0              : Floating-point sine.
--   fp_cos_0              : Floating-point cosine.
--   fp_log2_0             : Floating-point log base 2.
--   fp_exp2_0             : Floating-point 2^a.
--   fp_lt_0               : Floating-point less-than comparison.
--   fp_eq_0               : Floating-point equality comparison.
--   fp_fix2float_0        : Integer to float conversion.
--   fp_float2fix_0        : Float to integer conversion.
--   fp_scalar_product_0   : 4-element dot product.
--
-- ============================================================================

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

library ieee;
use ieee.std_logic_1164.all;

entity fp_cos_0 is
    generic( latency : integer := 21 );
    port (
        clk    : in  std_logic := '0';
        areset : in  std_logic := '0';
        a      : in  std_logic_vector(31 downto 0);
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_cos_0;

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

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity fp_scalar_product_0 is
    generic( latency : integer := 37 );
    port (
        clk    : in  std_logic                     := '0';
        areset : in  std_logic                     := '0';
        a0     : in  std_logic_vector(31 downto 0) := (others => '0');
        b0     : in  std_logic_vector(31 downto 0) := (others => '0');
        a1     : in  std_logic_vector(31 downto 0) := (others => '0');
        b1     : in  std_logic_vector(31 downto 0) := (others => '0');
        a2     : in  std_logic_vector(31 downto 0) := (others => '0');
        b2     : in  std_logic_vector(31 downto 0) := (others => '0');
        a3     : in  std_logic_vector(31 downto 0) := (others => '0');
        b3     : in  std_logic_vector(31 downto 0) := (others => '0');
        q      : out std_logic_vector(31 downto 0)
    );
end entity fp_scalar_product_0;
