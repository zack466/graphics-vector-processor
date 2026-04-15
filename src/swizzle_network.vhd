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

    -- no swizzling just to test place/route
	 vec_a_out <= vec_a_in;
	 vec_b_out <= vec_b_in;

end architecture rtl;
