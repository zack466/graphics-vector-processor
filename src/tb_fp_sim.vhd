library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

entity tb_fp_sim is
end entity tb_fp_sim;

architecture behavior of tb_fp_sim is
    -- Clock and control
    constant clk_period : time      := 10 ns;
    signal clk          : std_logic := '0';
    signal en           : std_logic := '1';

    -- Signals for fp_mult_add (Latency 14)
    signal ma_a, ma_b, ma_c, ma_q : std_logic_vector(31 downto 0) := (others => '0');

    -- Signals for fp_addsub (Latency 14)
    signal as_q, as_s : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Signals for fp_sqrt (Latency 28)
    signal sqrt_a, sqrt_q : std_logic_vector(31 downto 0) := (others => '0');

begin
    -- 100MHz Clock Generation
    clk <= not clk after clk_period / 2;

    -- Device Under Test: Add/Sub
    dut_addsub: entity work.fp_addsub
        generic map (latency => 11)
        port map (clk => clk, en => en, a => ma_a, b => ma_b, q => as_q, s => as_s);

    -- Device Under Test: Multiply Add
    dut_mult_add: entity work.fp_mult_add
        generic map (latency => 14)
        port map (clk => clk, en => en, a => ma_a, b => ma_b, c => ma_c, q => ma_q);

    -- Device Under Test: Square Root
    dut_sqrt: entity work.fp_sqrt
        generic map (latency => 28)
        port map (clk => clk, en => en, a => sqrt_a, q => sqrt_q);

    -- Main Test Stimulus
    stimulus: process
    begin
        -- Wait for initial stabilization
        wait for clk_period * 2;

        ---------------------------------------------------------
        -- Test 1: Multiply Add ( 2.5 * 4.0 + 10.0 = 20.0 )
        ---------------------------------------------------------
        report "Starting Multiply-Add Test (Latency 14)...";
        
        -- Feed inputs using float_pkg conversion
        ma_a <= to_slv(to_float(2.5, 8, 23));
        ma_b <= to_slv(to_float(4.0, 8, 23));
        ma_c <= to_slv(to_float(10.0, 8, 23));

        -- Wait exactly 12 clock cycles for the pipeline. We do 1 + 11,
        -- since the first clock will clock the inputs into the pipeline, and
        -- the 11th clock after that is when the results are available.
        for i in 1 to 12 loop
            wait until rising_edge(clk);
        end loop;

        -- Verify the result
        assert to_real(to_float(as_q)) = 6.5
            report "Add Test Failed! Expected 6.5, Got: " & real'image(to_real(to_float(as_q)))
            severity error;

        assert to_real(to_float(as_s)) = -1.5
            report "Add Test Failed! Expected -1.5, Got: " & real'image(to_real(to_float(as_s)))
            severity error;

        -- Wait another 3 clock cycles to reach 14 from 11
        for i in 13 to 15 loop
            wait until rising_edge(clk);
        end loop;
        
        -- Verify the result
        assert to_real(to_float(ma_q)) = 20.0
            report "Multiply Add Test Failed! Expected 20.0, Got: " & real'image(to_real(to_float(ma_q)))
            severity error;
        
        report "Multiply-Add Test Passed.";

        ---------------------------------------------------------
        -- Test 2: Square Root ( sqrt(144.0) = 12.0 )
        ---------------------------------------------------------
        report "Starting Square Root Test (Latency 28)...";
        
        -- Feed input
        sqrt_a <= to_slv(to_float(144.0, 8, 23));

        -- Wait 1 + 28 clock cycles for the pipeline
        for i in 1 to 29 loop
            wait until rising_edge(clk);
        end loop;

        -- Verify the result
        assert to_real(to_float(sqrt_q)) = 12.0
            report "Square Root Test Failed! Expected 12.0, Got: " & real'image(to_real(to_float(sqrt_q)))
            severity error;
            
        report "Square Root Test Passed.";

        ---------------------------------------------------------
        -- End Simulation
        ---------------------------------------------------------
        report "All pipeline timing tests completed successfully!";
        std.env.stop;
        
    end process stimulus;

end architecture behavior;
