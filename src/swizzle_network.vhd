library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity swizzle_network is
    port (
        -- Control
        is_logic_op : in  std_logic;

        -- Vector A (Used by FPU and Reduction)
        vec_a_in   : in  vector_t;
        prf_a_in   : in  std_logic_vector(3 downto 0);
        swiz_sel_a : in  swizzle_sel_t; 
        vec_a_out  : out vector_t;
        
        -- Vector B (Used by Reduction, and potentially FPU in the future)
        vec_b_in   : in  vector_t;
        prf_b_in   : in  std_logic_vector(3 downto 0);
        swiz_sel_b : in  swizzle_sel_t;
        vec_b_out  : out vector_t
    );
end entity;

architecture rtl of swizzle_network is
    signal mux_a       : vector_t;
    signal mux_b       : vector_t;
begin

    -- Purely combinational multiplexing and routing process
    process(vec_a_in, vec_b_in, prf_a_in, prf_b_in, is_logic_op, swiz_sel_a, swiz_sel_b, mux_a, mux_b)
    begin
        -- 1. Pre-Swizzle Multiplexer (Inject Predicates if Logic Op)
        for i in 0 to 3 loop
            if is_logic_op = '1' then
                -- Zero-pad the 1-bit predicate to a full 32-bit word
                mux_a(i) <= x"0000000" & "000" & prf_a_in(i);
                mux_b(i) <= x"0000000" & "000" & prf_b_in(i);
            else
                -- Pass standard math vectors through
                mux_a(i) <= vec_a_in(i);
                mux_b(i) <= vec_b_in(i);
            end if;
        end loop;

        -- 2. Swizzle Routing A
        case swiz_sel_a is
            when SWIZ_X =>
                vec_a_out <= (mux_a(0), mux_a(0), mux_a(0), mux_a(0));
            when SWIZ_Y =>
                vec_a_out <= (mux_a(1), mux_a(1), mux_a(1), mux_a(1));
            when SWIZ_Z =>
                vec_a_out <= (mux_a(2), mux_a(2), mux_a(2), mux_a(2));
            when SWIZ_W =>
                vec_a_out <= (mux_a(3), mux_a(3), mux_a(3), mux_a(3));
            when others => -- SWIZ_PASS
                vec_a_out <= mux_a;
        end case;

        -- 3. Swizzle Routing B
        case swiz_sel_b is
            when SWIZ_X =>
                vec_b_out <= (mux_b(0), mux_b(0), mux_b(0), mux_b(0));
            when SWIZ_Y =>
                vec_b_out <= (mux_b(1), mux_b(1), mux_b(1), mux_b(1));
            when SWIZ_Z =>
                vec_b_out <= (mux_b(2), mux_b(2), mux_b(2), mux_b(2));
            when SWIZ_W =>
                vec_b_out <= (mux_b(3), mux_b(3), mux_b(3), mux_b(3));
            when others => -- SWIZ_PASS
                vec_b_out <= mux_b;
        end case;
    end process;

end architecture rtl;
