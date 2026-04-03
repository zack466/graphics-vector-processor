library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity vector_reduction_unit is
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;
        
        -- Data Inputs
        valid_in    : in  std_logic;
        vec_a       : in  vector_t;
        vec_b       : in  vector_t;
        
        -- Reduction Modifiers
        reduce_mask : in  std_logic_vector(3 downto 0); 
        red_mode    : in  std_logic_vector(1 downto 0); -- Mode directly from instruction
        
        -- Output
        result      : out word_t; 
        valid_out   : out std_logic
    );
end entity;

architecture rtl of vector_reduction_unit is

    constant FLOAT_ZERO : word_t := x"00000000"; -- 0.0f
    constant FLOAT_ONE  : word_t := x"3F800000"; -- 1.0f

    signal cond_a : vector_t;
    signal cond_b : vector_t;

    signal valid_pipe : std_logic_vector(LAT_REDUCT downto 0) := (others => '0');

    component fp_scalar_product is
        generic( latency : integer := 37 );
        port (
            clk    : in  std_logic;
            areset : in  std_logic;
            en     : in  std_logic;
            a0     : in  std_logic_vector(31 downto 0);
            b0     : in  std_logic_vector(31 downto 0);
            a1     : in  std_logic_vector(31 downto 0);
            b1     : in  std_logic_vector(31 downto 0);
            a2     : in  std_logic_vector(31 downto 0);
            b2     : in  std_logic_vector(31 downto 0);
            a3     : in  std_logic_vector(31 downto 0);
            b3     : in  std_logic_vector(31 downto 0);
            q      : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    -- ========================================================================
    -- 1. COMBINATIONAL INPUT CONDITIONING
    -- ========================================================================
    process(vec_a, vec_b, reduce_mask, red_mode)
        variable temp_a, temp_b : word_t;
    begin
        for i in 0 to 3 loop
            
            -- Evaluate behavior based on the specific reduction mode
            case red_mode is
                when RED_MODE_DOT =>
                    temp_a := vec_a(i);
                    temp_b := vec_b(i);
                    
                when RED_MODE_SQ_MAG =>
                    temp_a := vec_a(i);
                    temp_b := vec_a(i); -- Route A into B for squaring
                    
                when RED_MODE_SUM =>
                    temp_a := vec_a(i);
                    temp_b := FLOAT_ONE; -- Multiply by 1.0
                    
                when RED_MODE_ABS_SUM =>
                    temp_a := '0' & vec_a(i)(30 downto 0); -- Strip sign bit
                    temp_b := FLOAT_ONE;
                    
                when others =>
                    temp_a := vec_a(i);
                    temp_b := vec_b(i);
            end case;

            -- Apply Component Masking
            if reduce_mask(i) = '1' then
                cond_a(i) <= temp_a;
                cond_b(i) <= temp_b;
            else
                cond_a(i) <= FLOAT_ZERO;
                cond_b(i) <= FLOAT_ZERO;
            end if;
            
        end loop;
    end process;

    -- ========================================================================
    -- 2. HARDWARE IP INSTANTIATION
    -- ========================================================================
    u_scalar_product : fp_scalar_product
        generic map (latency => LAT_REDUCT)
        port map (
            clk    => clk,
            areset => reset,
            en     => '1', 
            a0     => cond_a(0), b0 => cond_b(0),
            a1     => cond_a(1), b1 => cond_b(1),
            a2     => cond_a(2), b2 => cond_b(2),
            a3     => cond_a(3), b3 => cond_b(3),
            q      => result
        );

    -- ========================================================================
    -- 3. VALID SIGNAL PIPELINE
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_pipe <= (others => '0');
            else
                valid_pipe(0) <= valid_in;
                for i in 1 to LAT_REDUCT loop
                    valid_pipe(i) <= valid_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    valid_out <= valid_pipe(LAT_REDUCT);

end architecture rtl;
