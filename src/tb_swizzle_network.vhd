library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_swizzle_network is
end entity tb_swizzle_network;

architecture sim of tb_swizzle_network is

    -- Signals
    signal is_logic_op   : std_logic := '0';

    signal vec_a_in   : vector_t := (others => (others => '0'));
    signal prf_a_in   : std_logic_vector(3 downto 0) := "0000";
    signal swiz_sel_a : swizzle_sel_t := (others => "00");
    signal vec_a_out  : vector_t;

    signal vec_b_in   : vector_t := (others => (others => '0'));
    signal prf_b_in   : std_logic_vector(3 downto 0) := "0000";
    signal swiz_sel_b : swizzle_sel_t := (others => "00");
    signal vec_b_out  : vector_t;

begin

    -- Instantiate the Unit Under Test (UUT)
    uut: entity work.swizzle_network
        port map (
            is_logic_op=> is_logic_op,
            vec_a_in   => vec_a_in,
            prf_a_in   => prf_a_in,
            swiz_sel_a => swiz_sel_a,
            vec_a_out  => vec_a_out,
            
            vec_b_in   => vec_b_in,
            prf_b_in   => prf_b_in,
            swiz_sel_b => swiz_sel_b,
            vec_b_out  => vec_b_out
        );

    -- Stimulus process
    stim_proc: process
    begin
        -- Initialize input vector A (1, 2, 3, 4 format)
        vec_a_in(0) <= x"11111111"; -- X
        vec_a_in(1) <= x"22222222"; -- Y
        vec_a_in(2) <= x"33333333"; -- Z
        vec_a_in(3) <= x"44444444"; -- A
        
        -- Initialize input vector B (A, B, C, D format)
        vec_b_in(0) <= x"AAAAAAAA"; -- X
        vec_b_in(1) <= x"BBBBBBBB"; -- Y
        vec_b_in(2) <= x"CCCCCCCC"; -- Z
        vec_b_in(3) <= x"DDDDDDDD"; -- A
        
        -- Initialize PRF Vectors
        prf_a_in <= "1001"; -- A=1, Z=0, Y=0, X=1
        prf_b_in <= "1100"; -- A=1, Z=1, Y=0, X=0

        is_logic_op <= '0'; -- Default to standard math mode
        wait for 10 ns;

        -- ====================================================================
        -- Test 1: Vector A Pass-through, Vector B Reverse (MATH MODE)
        -- Vector A Expected: X, Y, Z, A
        -- Vector B Expected: A, Z, Y, X
        -- ====================================================================
        swiz_sel_a(0) <= "00"; swiz_sel_a(1) <= "01"; swiz_sel_a(2) <= "10"; swiz_sel_a(3) <= "11";
        swiz_sel_b(0) <= "11"; swiz_sel_b(1) <= "10"; swiz_sel_b(2) <= "01"; swiz_sel_b(3) <= "00";
        wait for 10 ns;
        
        assert vec_a_out(0) = x"11111111" report "T1 A(0) Failed" severity error;
        assert vec_a_out(1) = x"22222222" report "T1 A(1) Failed" severity error;
        assert vec_a_out(2) = x"33333333" report "T1 A(2) Failed" severity error;
        assert vec_a_out(3) = x"44444444" report "T1 A(3) Failed" severity error;
        
        assert vec_b_out(0) = x"DDDDDDDD" report "T1 B(0) Failed" severity error;
        assert vec_b_out(1) = x"CCCCCCCC" report "T1 B(1) Failed" severity error;
        assert vec_b_out(2) = x"BBBBBBBB" report "T1 B(2) Failed" severity error;
        assert vec_b_out(3) = x"AAAAAAAA" report "T1 B(3) Failed" severity error;

        -- ====================================================================
        -- Test 2: Vector A Broadcast X, Vector B Broadcast Y (MATH MODE)
        -- Vector A Expected: X, X, X, X
        -- Vector B Expected: Y, Y, Y, Y
        -- ====================================================================
        swiz_sel_a(0) <= "00"; swiz_sel_a(1) <= "00"; swiz_sel_a(2) <= "00"; swiz_sel_a(3) <= "00";
        swiz_sel_b(0) <= "01"; swiz_sel_b(1) <= "01"; swiz_sel_b(2) <= "01"; swiz_sel_b(3) <= "01";
        wait for 10 ns;
        
        assert vec_a_out(0) = x"11111111" report "T2 A(0) Failed" severity error;
        assert vec_a_out(1) = x"11111111" report "T2 A(1) Failed" severity error;
        assert vec_a_out(2) = x"11111111" report "T2 A(2) Failed" severity error;
        assert vec_a_out(3) = x"11111111" report "T2 A(3) Failed" severity error;

        assert vec_b_out(0) = x"BBBBBBBB" report "T2 B(0) Failed" severity error;
        assert vec_b_out(1) = x"BBBBBBBB" report "T2 B(1) Failed" severity error;
        assert vec_b_out(2) = x"BBBBBBBB" report "T2 B(2) Failed" severity error;
        assert vec_b_out(3) = x"BBBBBBBB" report "T2 B(3) Failed" severity error;

        -- ====================================================================
        -- Test 3: Custom Shuffles (MATH MODE)
        -- Vector A Expected: Y, Y, A, X
        -- Vector B Expected: Z, X, X, A
        -- ====================================================================
        swiz_sel_a(0) <= "01"; swiz_sel_a(1) <= "01"; swiz_sel_a(2) <= "11"; swiz_sel_a(3) <= "00";
        swiz_sel_b(0) <= "10"; swiz_sel_b(1) <= "00"; swiz_sel_b(2) <= "00"; swiz_sel_b(3) <= "11";
        wait for 10 ns;
        
        assert vec_a_out(0) = x"22222222" report "T3 A(0) Failed" severity error;
        assert vec_a_out(1) = x"22222222" report "T3 A(1) Failed" severity error;
        assert vec_a_out(2) = x"44444444" report "T3 A(2) Failed" severity error;
        assert vec_a_out(3) = x"11111111" report "T3 A(3) Failed" severity error;
        
        assert vec_b_out(0) = x"CCCCCCCC" report "T3 B(0) Failed" severity error;
        assert vec_b_out(1) = x"AAAAAAAA" report "T3 B(1) Failed" severity error;
        assert vec_b_out(2) = x"AAAAAAAA" report "T3 B(2) Failed" severity error;
        assert vec_b_out(3) = x"DDDDDDDD" report "T3 B(3) Failed" severity error;

        -- ====================================================================
        -- Test 4: Logic Mode Activation (Pass-through PRF)
        -- PRF A: "1001" -> X=1, Y=0, Z=0, A=1
        -- PRF B: "1100" -> X=0, Y=0, Z=1, A=1
        -- ====================================================================
        is_logic_op <= '1'; -- Switches Mux to PRF mode
        swiz_sel_a(0) <= "00"; swiz_sel_a(1) <= "01"; swiz_sel_a(2) <= "10"; swiz_sel_a(3) <= "11";
        swiz_sel_b(0) <= "00"; swiz_sel_b(1) <= "01"; swiz_sel_b(2) <= "10"; swiz_sel_b(3) <= "11";
        wait for 10 ns;

        -- Verify vector A is overwritten by zero-padded PRF A
        assert vec_a_out(0) = x"00000001" report "T4 A(0) Failed - PRF Injection Error" severity error;
        assert vec_a_out(1) = x"00000000" report "T4 A(1) Failed - PRF Injection Error" severity error;
        assert vec_a_out(2) = x"00000000" report "T4 A(2) Failed - PRF Injection Error" severity error;
        assert vec_a_out(3) = x"00000001" report "T4 A(3) Failed - PRF Injection Error" severity error;

        -- Verify vector B is overwritten by zero-padded PRF B
        assert vec_b_out(0) = x"00000000" report "T4 B(0) Failed - PRF Injection Error" severity error;
        assert vec_b_out(1) = x"00000000" report "T4 B(1) Failed - PRF Injection Error" severity error;
        assert vec_b_out(2) = x"00000001" report "T4 B(2) Failed - PRF Injection Error" severity error;
        assert vec_b_out(3) = x"00000001" report "T4 B(3) Failed - PRF Injection Error" severity error;

        -- ====================================================================
        -- Test 5: Logic Mode with Custom Swizzle
        -- Broadcast PRF A.x (1) to all. 
        -- Broadcast PRF B.y (0) to all.
        -- ====================================================================
        swiz_sel_a(0) <= "00"; swiz_sel_a(1) <= "00"; swiz_sel_a(2) <= "00"; swiz_sel_a(3) <= "00";
        swiz_sel_b(0) <= "01"; swiz_sel_b(1) <= "01"; swiz_sel_b(2) <= "01"; swiz_sel_b(3) <= "01";
        wait for 10 ns;

        -- Verify PRF Swizzling applied correctly
        assert vec_a_out(0) = x"00000001" report "T5 A(0) Failed - PRF Swizzle Error" severity error;
        assert vec_a_out(1) = x"00000001" report "T5 A(1) Failed - PRF Swizzle Error" severity error;
        assert vec_a_out(2) = x"00000001" report "T5 A(2) Failed - PRF Swizzle Error" severity error;
        assert vec_a_out(3) = x"00000001" report "T5 A(3) Failed - PRF Swizzle Error" severity error;

        assert vec_b_out(0) = x"00000000" report "T5 B(0) Failed - PRF Swizzle Error" severity error;
        assert vec_b_out(1) = x"00000000" report "T5 B(1) Failed - PRF Swizzle Error" severity error;
        assert vec_b_out(2) = x"00000000" report "T5 B(2) Failed - PRF Swizzle Error" severity error;
        assert vec_b_out(3) = x"00000000" report "T5 B(3) Failed - PRF Swizzle Error" severity error;

        -- End Simulation
        report ">> SIMULATION COMPLETE: All Exhaustive Swizzle & Predicate Logic tests passed!";
        std.env.stop;
    end process;

end architecture sim;
