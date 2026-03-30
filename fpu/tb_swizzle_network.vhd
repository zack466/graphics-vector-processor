library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_swizzle_network is
-- Testbench entity is empty
end entity tb_swizzle_network;

architecture sim of tb_swizzle_network is

    -- Component Declaration
    component swizzle_network
        port (
            vec_in       : in  vector_t;
            swizzle_sel  : in  swizzle_sel_t;
            vec_out      : out vector_t
        );
    end component;

    -- Signals
    signal vec_in      : vector_t := (others => (others => '0'));
    signal swizzle_sel : swizzle_sel_t := (others => "00");
    signal vec_out     : vector_t;

begin

    -- Instantiate the Unit Under Test (UUT)
    uut: swizzle_network
        port map (
            vec_in      => vec_in,
            swizzle_sel => swizzle_sel,
            vec_out     => vec_out
        );

    -- Stimulus process
    stim_proc: process
    begin
        -- Initialize input vector with recognizable dummy data
        vec_in(0) <= x"11111111"; -- X coordinate (Index 0)
        vec_in(1) <= x"22222222"; -- Y coordinate (Index 1)
        vec_in(2) <= x"33333333"; -- Z coordinate (Index 2)
        vec_in(3) <= x"44444444"; -- A coordinate (Index 3)
        
        wait for 10 ns;

        -- Test 1: Pass-through (X, Y, Z, A)
        swizzle_sel(0) <= "00"; -- Out(0) gets In(0)
        swizzle_sel(1) <= "01"; -- Out(1) gets In(1)
        swizzle_sel(2) <= "10"; -- Out(2) gets In(2)
        swizzle_sel(3) <= "11"; -- Out(3) gets In(3)
        wait for 10 ns;
        
        assert vec_out(0) = x"11111111" report "T1 Failed: Expected X" severity error;
        assert vec_out(1) = x"22222222" report "T1 Failed: Expected Y" severity error;
        assert vec_out(2) = x"33333333" report "T1 Failed: Expected Z" severity error;
        assert vec_out(3) = x"44444444" report "T1 Failed: Expected A" severity error;

        -- Test 2: Broadcast X (X, X, X, X)
        swizzle_sel(0) <= "00"; 
        swizzle_sel(1) <= "00"; 
        swizzle_sel(2) <= "00"; 
        swizzle_sel(3) <= "00"; 
        wait for 10 ns;
        
        assert vec_out(0) = x"11111111" report "T2 Failed" severity error;
        assert vec_out(1) = x"11111111" report "T2 Failed" severity error;
        assert vec_out(2) = x"11111111" report "T2 Failed" severity error;
        assert vec_out(3) = x"11111111" report "T2 Failed" severity error;

        -- Test 3: Reverse (A, Z, Y, X)
        swizzle_sel(0) <= "11"; -- Out(0) gets In(3)
        swizzle_sel(1) <= "10"; -- Out(1) gets In(2)
        swizzle_sel(2) <= "01"; -- Out(2) gets In(1)
        swizzle_sel(3) <= "00"; -- Out(3) gets In(0)
        wait for 10 ns;
        
        assert vec_out(0) = x"44444444" report "T3 Failed" severity error;
        assert vec_out(1) = x"33333333" report "T3 Failed" severity error;
        assert vec_out(2) = x"22222222" report "T3 Failed" severity error;
        assert vec_out(3) = x"11111111" report "T3 Failed" severity error;

        -- Test 4: Custom Shuffle (Y, Y, A, X)
        swizzle_sel(0) <= "01"; 
        swizzle_sel(1) <= "01"; 
        swizzle_sel(2) <= "11"; 
        swizzle_sel(3) <= "00"; 
        wait for 10 ns;
        
        assert vec_out(0) = x"22222222" report "T4 Failed" severity error;
        assert vec_out(1) = x"22222222" report "T4 Failed" severity error;
        assert vec_out(2) = x"44444444" report "T4 Failed" severity error;
        assert vec_out(3) = x"11111111" report "T4 Failed" severity error;

        -- End Simulation
        report "Simulation Finished";
        wait;
    end process;

end architecture sim;
