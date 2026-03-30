library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Assuming this is compiled into the work library
use work.vector_types_pkg.all;

entity swizzle_network is
    port (
        vec_in       : in  vector_t;
        swizzle_sel  : in  swizzle_sel_t; 
        vec_out      : out vector_t
    );
end entity;

architecture rtl of swizzle_network is
begin

    -- Purely combinational process (sensitive to all inputs)
    process(vec_in, swizzle_sel)
    begin
        for i in 0 to 3 loop
            -- The 2-bit swizzle selector determines which input coordinate 
            -- (0=x, 1=y, 2=z, 3=a) is routed to output coordinate 'i'
            vec_out(i) <= vec_in(to_integer(unsigned(swizzle_sel(i))));
        end loop;
    end process;

end architecture rtl;
