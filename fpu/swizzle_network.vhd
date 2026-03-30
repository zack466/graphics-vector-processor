library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity swizzle_network is
    port (
        -- Vector A (Used by FPU and Reduction)
        vec_a_in   : in  vector_t;
        swiz_sel_a : in  swizzle_sel_t; 
        vec_a_out  : out vector_t;
        
        -- Vector B (Used by Reduction, and potentially FPU in the future)
        vec_b_in   : in  vector_t;
        swiz_sel_b : in  swizzle_sel_t;
        vec_b_out  : out vector_t
    );
end entity;

architecture rtl of swizzle_network is
begin

    -- Purely combinational process (sensitive to all inputs)
    process(vec_a_in, vec_b_in, swiz_sel_a, swiz_sel_b)
    begin
        for i in 0 to 3 loop
            -- Route vector A coordinates
            vec_a_out(i) <= vec_a_in(to_integer(unsigned(swiz_sel_a(i))));
            
            -- Route vector B coordinates simultaneously
            vec_b_out(i) <= vec_b_in(to_integer(unsigned(swiz_sel_b(i))));
        end loop;
    end process;

end architecture rtl;
