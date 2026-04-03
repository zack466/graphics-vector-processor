library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use IEEE.FLOAT_PKG.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_vector_reduction_unit is
end entity tb_vector_reduction_unit;

architecture sim of tb_vector_reduction_unit is

    constant CLK_PERIOD : time := 10 ns;

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';
    
    signal valid_in    : std_logic := '0';
    signal vec_a       : vector_t  := (others => (others => '0'));
    signal vec_b       : vector_t  := (others => (others => '0'));
    
    signal reduce_mask : std_logic_vector(3 downto 0) := "0000";
    signal red_mode    : std_logic_vector(1 downto 0) := "00";
    
    signal result      : word_t;
    signal valid_out   : std_logic;

    function pack_vec(x, y, z, w : real) return vector_t is
    begin
        return (to_slv(to_float(x)), to_slv(to_float(y)), to_slv(to_float(z)), to_slv(to_float(w)));
    end function;

begin

    clk_process: process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    uut: entity work.vector_reduction_unit
        port map (
            clk         => clk,
            reset       => reset,
            valid_in    => valid_in,
            vec_a       => vec_a,
            vec_b       => vec_b,
            reduce_mask => reduce_mask,
            red_mode    => red_mode,
            result      => result,
            valid_out   => valid_out
        );

    stim_proc: process
        procedure wait_for_result(expected_val : real; test_name : string) is
        begin
            wait until rising_edge(clk);
            valid_in <= '0'; 
            
            for i in 1 to LAT_REDUCT loop
                wait until rising_edge(clk);
            end loop;
            
            wait until falling_edge(clk);
            
            assert valid_out = '1' report test_name & ": valid_out failed to assert!" severity error;
            assert to_real(to_float(result)) = expected_val 
                report test_name & " failed! Expected " & real'image(expected_val) & 
                       " but got " & real'image(to_real(to_float(result))) severity error;
                       
            report ">> " & test_name & " Passed.";
        end procedure;

    begin
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- MODE 0: STANDARD DOT PRODUCT (RED_MODE_DOT)
        -- ====================================================================
        red_mode <= RED_MODE_DOT;
        
        vec_a <= pack_vec(1.0, 2.0, 3.0, 4.0);
        vec_b <= pack_vec(2.0, 3.0, 4.0, 5.0);
        reduce_mask <= "1111";
        valid_in <= '1';
        wait_for_result(40.0, "Test 1A: Dot Product 4D");

        vec_a <= pack_vec(1.0, 2.0, 3.0, 4.0);
        vec_b <= pack_vec(2.0, 3.0, 4.0, 5.0);
        reduce_mask <= "0111"; -- W=0
        valid_in <= '1';
        wait_for_result(20.0, "Test 1B: Dot Product 3D (Masked)");

        -- ====================================================================
        -- MODE 1: SQUARED MAGNITUDE (RED_MODE_SQ_MAG)
        -- ====================================================================
        red_mode <= RED_MODE_SQ_MAG;
        
        vec_a <= pack_vec(1.0, -2.0, 3.0, -4.0);
        reduce_mask <= "1111";
        valid_in <= '1';
        wait_for_result(30.0, "Test 2A: Squared Magnitude Full");

        vec_a <= pack_vec(3.0, 4.0, 10.0, 20.0);
        reduce_mask <= "0011"; -- Z, W = 0
        valid_in <= '1';
        wait_for_result(25.0, "Test 2B: Squared Magnitude 2D (Masked)");

        -- ====================================================================
        -- MODE 2: COMPONENT SUM (RED_MODE_SUM)
        -- ====================================================================
        red_mode <= RED_MODE_SUM;

        vec_a <= pack_vec(1.5, -2.5, 3.0, 4.0);
        reduce_mask <= "1111";
        valid_in <= '1';
        wait_for_result(6.0, "Test 3A: Component Sum Full");

        vec_a <= pack_vec(10.0, 20.0, 30.0, -5.0);
        reduce_mask <= "1001"; -- Y, Z = 0
        valid_in <= '1';
        wait_for_result(5.0, "Test 3B: Component Sum (Masked X,W)");

        -- ====================================================================
        -- MODE 3: ABSOLUTE SUM (RED_MODE_ABS_SUM)
        -- ====================================================================
        red_mode <= RED_MODE_ABS_SUM;

        vec_a <= pack_vec(-1.0, -2.0, 3.0, -4.0);
        reduce_mask <= "1111";
        valid_in <= '1';
        wait_for_result(10.0, "Test 4A: Absolute Sum Full");

        vec_a <= pack_vec(100.0, -5.5, -4.5, 10.0);
        reduce_mask <= "1110"; -- X = 0
        valid_in <= '1';
        wait_for_result(20.0, "Test 4B: Absolute Sum (Masked Y,Z,W)");


        report ">> SIMULATION COMPLETE: All Reduction Unit tests passed!";
        std.env.stop;
    end process;

end architecture sim;
