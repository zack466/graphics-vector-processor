---------------------------------------------------------
-- Floating Point Arithmetic Architectures
---------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_multiply_add;
architecture structural of fp_multiply_add is
begin
    fp_multiply_add.fp_multiply_add port map(clk=>clk, areset=>areset, a=>a, b=>b, c=>c, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_div;
architecture structural of fp_div is
begin
    fp_div.fp_div port map(clk=>clk, areset=>areset, a=>a, b=>b, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_sqrt;
architecture structural of fp_sqrt is
begin
    fp_sqrt.fp_sqrt port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_rsqrt;
architecture structural of fp_rsqrt is
begin
    fp_rsqrt.fp_rsqrt port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_min;
architecture structural of fp_min is
begin
    fp_min.fp_min port map(clk=>clk, areset=>areset, a=>a, b=>b, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_max;
architecture structural of fp_max is
begin
    fp_max.fp_max port map(clk=>clk, areset=>areset, a=>a, b=>b, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_sin;
architecture structural of fp_sin is
begin
    fp_sin.fp_sin port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_cos;
architecture structural of fp_cos is
begin
    fp_cos.fp_cos port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_log2;
architecture structural of fp_log2 is
begin
    fp_log2.fp_log2 port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_exp2;
architecture structural of fp_exp2 is
begin
    fp_exp2.fp_exp2 port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_lt;
architecture structural of fp_lt is
begin
    fp_lt.fp_lt port map(clk=>clk, areset=>areset, a=>a, b=>b, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_eq;
architecture structural of fp_eq is
begin
    fp_eq.fp_eq port map(clk=>clk, areset=>areset, a=>a, b=>b, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_fix2float;
architecture structural of fp_fix2float is
begin
    fp_fix2float.fp_fix2float port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_float2fix;
architecture structural of fp_float2fix is
begin
    fp_float2fix.fp_float2fix port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_rcp;
architecture structural of fp_rcp is
begin
    fp_rcp.fp_rcp port map(clk=>clk, areset=>areset, a=>a, q=>q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library fp_scalar_product;
architecture structural of fp_scalar_product is
begin
    fp_scalar_product.fp_scalar_product port map(
        clk=>clk, 
        areset=>areset, 
        a0=>a0, 
        a1=>a1, 
        a2=>a2, 
        a3=>a3, 
        b0=>b0, 
        b1=>b1, 
        b2=>b2, 
        b3=>b3, 
        q=>q
    );
end architecture;
