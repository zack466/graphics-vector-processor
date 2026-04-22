-- ============================================================================
-- FILE: fp_architectures_sim.vhd
-- ============================================================================
--
-- Simulation architecture implementations for all entities declared in
-- fp_entities.vhd. Each architecture computes the result combinationally
-- using VHDL's real type and ieee.math_real, then passes it through a
-- Pipeline instance to replicate the correct output latency of the
-- corresponding Altera IP core. This file is used in simulation only;
-- the synthesis equivalent is in fp_architectures_structural.vhd.
--
-- Comparison operations (fp_lt_0, fp_eq_0) use Pipeline_sl rather than
-- Pipeline since their output is std_logic rather than real.
--
-- ============================================================================

---------------------------------------------------------
-- Pipeline Architectures
---------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

architecture dataflow of Pipeline is
    signal pipe : real_vector(0 to latency - 1);
begin
    pipeline_input: process(clock)
    begin
        if rising_edge(clock) then
            pipe(0) <= data_in;
        end if;
    end process;
    
    pipeline_iter: for i in 1 to latency - 1 generate
        process(clock)
        begin
            if rising_edge(clock) then
                pipe(i) <= pipe(i - 1);
            end if;
        end process;
    end generate pipeline_iter;

    data_out <= pipe(latency - 1);
end architecture dataflow;

library ieee;
use ieee.std_logic_1164.all;

architecture dataflow of Pipeline_sl is
    signal pipe : std_logic_vector(0 to latency - 1) := (others => '0');
begin
    process(clock)
    begin
        if rising_edge(clock) then
            pipe(0) <= data_in;
            for i in 1 to latency - 1 loop
                pipe(i) <= pipe(i - 1);
            end loop;
        end if;
    end process;

    data_out <= pipe(latency - 1) when latency > 0 else data_in;
end architecture dataflow;

---------------------------------------------------------
-- Floating Point Arithmetic Architectures
---------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_multiply_add_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= (to_real(to_float(a)) * to_real(to_float(b))) + to_real(to_float(c));

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_div_0 is
    signal math_res, pipelined_res : real;
begin
    -- Guard against divide-by-zero; returns 0.0 to match Altera IP behaviour.
    math_res <= to_real(to_float(a)) / to_real(to_float(b)) when to_real(to_float(b)) /= 0.0 else 0.0;

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_sqrt_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= sqrt(to_real(to_float(a)));

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_min_0 is
    signal real_a, real_b, math_res, pipelined_res : real;
begin
    real_a <= to_real(to_float(a));
    real_b <= to_real(to_float(b));
    math_res <= real_a when real_a < real_b else real_b;

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_max_0 is
    signal real_a, real_b, math_res, pipelined_res : real;
begin
    real_a <= to_real(to_float(a));
    real_b <= to_real(to_float(b));
    math_res <= real_a when real_a > real_b else real_b;

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_sin_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= sin(to_real(to_float(a)));
    
    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);
        
    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_cos_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= cos(to_real(to_float(a)));
    
    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);
        
    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_log2_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= log2(to_real(to_float(a)));
    
    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);
        
    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_exp2_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= 2.0 ** to_real(to_float(a));
    
    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);
        
    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_lt_0 is
    signal logic_res : std_logic;
begin
    logic_res <= '1' when to_real(to_float(a)) < to_real(to_float(b)) else '0';

    pipe_inst: entity work.Pipeline_sl
        generic map(latency => latency)
        port map(clock => clk, data_in => logic_res, data_out => q(0));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_eq_0 is
    signal logic_res : std_logic;
begin
    logic_res <= '1' when to_real(to_float(a)) = to_real(to_float(b)) else '0';

    pipe_inst: entity work.Pipeline_sl
        generic map(latency => latency)
        port map(clock => clk, data_in => logic_res, data_out => q(0));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_fix2float_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= real(to_integer(signed(a)));

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    q <= to_slv(to_float(pipelined_res));
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

architecture sim of fp_float2fix_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= to_real(to_float(a));

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(clock => clk, data_in => math_res, data_out => pipelined_res);

    -- Truncates toward zero via integer(); matches the Altera IP's rounding mode.
    q <= std_logic_vector(to_signed(integer(pipelined_res), 32));
end architecture;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use IEEE.FLOAT_PKG.ALL;

architecture sim of fp_scalar_product_0 is
    signal math_res, pipelined_res : real;
begin
    math_res <= (to_real(to_float(a0)) * to_real(to_float(b0))) +
                (to_real(to_float(a1)) * to_real(to_float(b1))) +
                (to_real(to_float(a2)) * to_real(to_float(b2))) +
                (to_real(to_float(a3)) * to_real(to_float(b3)));

    pipe_inst: entity work.Pipeline
        generic map(latency => latency)
        port map(
            clock    => clk,
            data_in  => math_res,
            data_out => pipelined_res
        );

    q <= to_slv(to_float(pipelined_res));
end architecture sim;
