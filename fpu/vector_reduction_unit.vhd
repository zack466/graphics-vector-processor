library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity vector_reduction_unit is
    generic (
        -- Matches the Altera fp_scalar_product IP latency
        LATENCY : integer := 37 
    );
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;
        
        -- Data Inputs
        valid_in    : in  std_logic;
        vec_a       : in  vector_t;
        vec_b       : in  vector_t;
        
        -- Reduction Modifiers
        reduce_mask : in  std_logic_vector(3 downto 0); -- 1=Keep, 0=Force to 0.0
        sq_mode     : in  std_logic; -- If 1: vec_b becomes vec_a (Magnitude Squared)
        sum_mode    : in  std_logic; -- If 1: vec_b becomes 1.0   (Component Sum)
        abs_mode    : in  std_logic; -- If 1: Force vec_a positive (Absolute Sum)
        
        -- Output
        result      : out word_t; 
        valid_out   : out std_logic
    );
end entity;

architecture rtl of vector_reduction_unit is

    constant FLOAT_ZERO : word_t := x"00000000"; -- 0.0f
    constant FLOAT_ONE  : word_t := x"3F800000"; -- 1.0f

    -- Conditioned inputs that will actually be fed to the IP
    signal cond_a : vector_t;
    signal cond_b : vector_t;

    -- Shift register to track instruction validity through the 37-cycle pipeline
    signal valid_pipe : std_logic_vector(LATENCY downto 0) := (others => '0');

    -- Declare the Altera IP Component
    component fp_scalar_product is
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
    process(vec_a, vec_b, reduce_mask, sq_mode, sum_mode, abs_mode)
        variable temp_a, temp_b : word_t;
    begin
        for i in 0 to 3 loop
            
            -- Step 1A: Absolute Value Modifier for A
            if abs_mode = '1' then
                temp_a := '0' & vec_a(i)(30 downto 0); -- Strip sign bit
            else
                temp_a := vec_a(i);
            end if;

            -- Step 1B: Input B Muxing (Standard vs. Square vs. Sum)
            if sum_mode = '1' then
                temp_b := FLOAT_ONE;
            elsif sq_mode = '1' then
                temp_b := vec_a(i); -- Use unmodified A for squaring
            else
                temp_b := vec_b(i);
            end if;

            -- Step 2: Component Masking (Zero out if mask bit is 0)
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
        port map (
            clk    => clk,
            areset => reset,
            en     => '1',            -- Tie to 1 for continuous pipeline flow
            a0     => cond_a(0),
            b0     => cond_b(0),
            a1     => cond_a(1),
            b1     => cond_b(1),
            a2     => cond_a(2),
            b2     => cond_b(2),
            a3     => cond_a(3),
            b3     => cond_b(3),
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
                for i in 1 to LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    valid_out <= valid_pipe(LATENCY);

end architecture rtl;
