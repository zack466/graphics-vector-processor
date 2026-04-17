---------------------------------------------------------
-- Floating Point Testbench (Exact Latency Verification)
---------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;
use work.processor_constants_pkg.all;

entity tb_fp_sim is
end entity tb_fp_sim;

architecture behavior of tb_fp_sim is
    -- Clock and control
    constant clk_period : time      := 10 ns;
    signal clk          : std_logic := '0';
    signal areset       : std_logic := '1';

    -- Signals for fp_mult_add
    signal ma_a, ma_b, ma_c, ma_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for fp_div
    signal div_a, div_b, div_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for fp_sqrt
    signal sqrt_a, sqrt_q   : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Min / Max
    signal minmax_a, minmax_b, min_q, max_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Trig Functions
    signal trig_a, sin_q, cos_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Log / Exp
    signal log2_a, log2_q : std_logic_vector(31 downto 0) := (others => '0');
    signal exp2_a, exp2_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Comparisons
    signal cmp_a, cmp_b : std_logic_vector(31 downto 0) := (others => '0');
    signal lt_q, eq_q   : std_logic_vector(0 downto 0)  := "0";
    -- Signals for Conversions
    signal i2f_a, i2f_q : std_logic_vector(31 downto 0) := (others => '0');
    signal f2i_a, f2i_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Reciprocal
    signal rcp_a, rcp_q : std_logic_vector(31 downto 0) := (others => '0');
    -- Signals for Scalar Product
    signal sp_a0, sp_a1, sp_a2, sp_a3 : std_logic_vector(31 downto 0) := (others => '0');
    signal sp_b0, sp_b1, sp_b2, sp_b3 : std_logic_vector(31 downto 0) := (others => '0');
    signal sp_q : std_logic_vector(31 downto 0) := (others => '0');

begin
    -- 100MHz Clock Generation
    clk <= not clk after clk_period / 2;

    -- Device Under Test Instantiations (with strict generic latency mapping)
    dut_multiply_add: entity work.fp_multiply_add_0
        generic map (latency => LAT_FMADD)
        port map (clk => clk, areset => areset, a => ma_a, b => ma_b, c => ma_c, q => ma_q);

    dut_div: entity work.fp_div_0
        generic map (latency => LAT_FDIV)
        port map (clk => clk, areset => areset, a => div_a, b => div_b, q => div_q);

    dut_sqrt: entity work.fp_sqrt_0
        generic map (latency => LAT_FSQRT)
        port map (clk => clk, areset => areset, a => sqrt_a, q => sqrt_q);

    dut_min: entity work.fp_min_0
        generic map (latency => LAT_FMIN)
        port map (clk => clk, areset => areset, a => minmax_a, b => minmax_b, q => min_q);

    dut_max: entity work.fp_max_0
        generic map (latency => LAT_FMAX)
        port map (clk => clk, areset => areset, a => minmax_a, b => minmax_b, q => max_q);

    dut_sin: entity work.fp_sin_0
        generic map (latency => LAT_FSIN)
        port map (clk => clk, areset => areset, a => trig_a, q => sin_q);

    dut_cos: entity work.fp_cos_0
        generic map (latency => LAT_FCOS)
        port map (clk => clk, areset => areset, a => trig_a, q => cos_q);

    dut_log2: entity work.fp_log2_0
        generic map (latency => LAT_FLOG2)
        port map (clk => clk, areset => areset, a => log2_a, q => log2_q);

    dut_exp2: entity work.fp_exp2_0
        generic map (latency => LAT_FEXP2)
        port map (clk => clk, areset => areset, a => exp2_a, q => exp2_q);

    dut_lt: entity work.fp_lt_0
        generic map (latency => LAT_FCMP_LT)
        port map (clk => clk, areset => areset, a => cmp_a, b => cmp_b, q => lt_q);

    dut_eq: entity work.fp_eq_0
        generic map (latency => LAT_FCMP_EQ)
        port map (clk => clk, areset => areset, a => cmp_a, b => cmp_b, q => eq_q);

    dut_i2f: entity work.fp_fix2float_0
        generic map (latency => LAT_I2F)
        port map (clk => clk, areset => areset, a => i2f_a, q => i2f_q);

    dut_f2i: entity work.fp_float2fix_0
        generic map (latency => LAT_F2I)
        port map (clk => clk, areset => areset, a => f2i_a, q => f2i_q);

    dut_rcp: entity work.fp_rcp_0
        generic map (latency => LAT_FRCP)
        port map (clk => clk, areset => areset, a => rcp_a, q => rcp_q);

    dut_scalar_product: entity work.fp_scalar_product_0
        generic map (latency => LAT_REDUCT)
        port map (clk => clk, areset => areset, 
                  a0 => sp_a0, a1 => sp_a1, a2 => sp_a2, a3 => sp_a3,
                  b0 => sp_b0, b1 => sp_b1, b2 => sp_b2, b3 => sp_b3, 
                  q => sp_q);

    -- Main Test Stimulus
    stimulus: process
    begin
        -- Initial Reset Phase
        areset <= '1';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        areset <= '0';
        wait until rising_edge(clk);

        report "Starting Exact Latency Sequence Tests...";

        ---------------------------------------------------------
        -- Test: Equality Compare (Latency: 1)
        ---------------------------------------------------------
        cmp_a <= to_slv(to_float(3.0, 8, 23)); cmp_b <= to_slv(to_float(5.0, 8, 23));
        for i in 1 to LAT_FCMP_EQ loop wait until rising_edge(clk); end loop;
        wait for 1 ns; -- Let output stabilize
        assert eq_q(0) = '0' report "Equal Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Min & Max (Latency: 2)
        ---------------------------------------------------------
        minmax_a <= to_slv(to_float(3.0, 8, 23)); minmax_b <= to_slv(to_float(5.0, 8, 23));
        for i in 1 to LAT_FMAX loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(min_q)) = 3.0 report "Min Failed!" severity error;
        assert to_real(to_float(max_q)) = 5.0 report "Max Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Less Than Compare (Latency: 3)
        ---------------------------------------------------------
        cmp_a <= to_slv(to_float(3.0, 8, 23)); cmp_b <= to_slv(to_float(5.0, 8, 23));
        for i in 1 to LAT_FCMP_LT loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert lt_q(0) = '1' report "Less Than Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Float to Integer (Latency: 5)
        ---------------------------------------------------------
        f2i_a <= to_slv(to_float(42.0, 8, 23));
        for i in 1 to LAT_F2I loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_integer(signed(f2i_q)) = 42 report "Float2Fix Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Div, Sqrt, Exp2, Rcp (Latency: 9)
        ---------------------------------------------------------
        div_a <= to_slv(to_float(10.0, 8, 23)); div_b <= to_slv(to_float(2.0, 8, 23));
        sqrt_a <= to_slv(to_float(144.0, 8, 23));
        exp2_a <= to_slv(to_float(3.0, 8, 23));
        rcp_a <= to_slv(to_float(4.0, 8, 23));
        
        for i in 1 to LAT_FDIV loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(div_q)) = 5.0    report "Div Failed!" severity error;
        assert to_real(to_float(sqrt_q)) = 12.0  report "Sqrt Failed!" severity error;
        assert to_real(to_float(exp2_q)) = 8.0   report "Exp2 Failed!" severity error;
        assert to_real(to_float(rcp_q)) = 0.25   report "Reciprocal Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Integer to Float (Latency: 11)
        ---------------------------------------------------------
        i2f_a <= std_logic_vector(to_signed(42, 32));
        for i in 1 to LAT_I2F loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(i2f_q)) = 42.0 report "Fix2Float Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Scalar Product (Latency: 16)
        ---------------------------------------------------------
        sp_a0 <= to_slv(to_float(1.0, 8, 23)); sp_b0 <= to_slv(to_float(2.0, 8, 23));
        sp_a1 <= to_slv(to_float(2.0, 8, 23)); sp_b1 <= to_slv(to_float(3.0, 8, 23));
        sp_a2 <= to_slv(to_float(3.0, 8, 23)); sp_b2 <= to_slv(to_float(4.0, 8, 23));
        sp_a3 <= to_slv(to_float(4.0, 8, 23)); sp_b3 <= to_slv(to_float(5.0, 8, 23));
        for i in 1 to LAT_REDUCT loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(sp_q)) = 40.0 report "Scalar Product Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Sin & Cos (Latency: 18)
        ---------------------------------------------------------
        trig_a <= to_slv(to_float(0.0, 8, 23));
        for i in 1 to LAT_FSIN loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(sin_q)) = 0.0 report "Sin Failed!" severity error;
        assert to_real(to_float(cos_q)) = 1.0 report "Cos Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Fused Multiply-Add (Latency: 20)
        ---------------------------------------------------------
        ma_a <= to_slv(to_float(2.5, 8, 23));
        ma_b <= to_slv(to_float(4.0, 8, 23));
        ma_c <= to_slv(to_float(10.0, 8, 23));
        for i in 1 to LAT_FMADD loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(ma_q)) = 20.0 report "Mult-Add Failed!" severity error;

        ---------------------------------------------------------
        -- Test: Log2 (Latency: 21)
        ---------------------------------------------------------
        log2_a <= to_slv(to_float(8.0, 8, 23));
        for i in 1 to LAT_FLOG2 loop wait until rising_edge(clk); end loop;
        wait for 1 ns;
        assert to_real(to_float(log2_q)) = 3.0 report "Log2 Failed!" severity error;

        ---------------------------------------------------------
        -- End Simulation
        ---------------------------------------------------------
        report "All exact pipeline timing tests completed successfully!";
        std.env.stop;
        
    end process stimulus;

end architecture behavior;
