-- =============================================================================
-- FILE: swizzle_network.vhd
-- COMPONENT: Swizzle Network
-- =============================================================================
--
-- This combinational block is responsible for routing and broadcasting vector
-- components for standard operations. To reduce routing pressure on the FPGA,
-- it only supports identity passthrough (.xyzw) or single-component broadcast 
-- (splatting) across the entire vector (e.g., .xxxx, .yyyy).
--
-- Inputs:
--   is_logic_op : When '1', zeroes out the standard vectors and uses 'prf_in'.
--   vec_a_in    : 128-bit vector input A (from Vector Register File)
--   prf_a_in    : 4-bit predicate input A (from Predicate Register File)
--   swiz_sel_a  : 3-bit control signal (SWIZ_PASS, SWIZ_X, SWIZ_Y, etc.)
--
-- Outputs:
--   vec_a_out   : 128-bit routed vector ready for the execution pipelines.
-- 
--------------------------------------------------------------------------------

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
    -- Every output is defined for every input combination, ensuring no latches.
    process(is_logic_op, prf_a_in, prf_b_in, vec_a_in, vec_b_in, swiz_sel_a, swiz_sel_b, mux_a, mux_b)
    begin
        -- ====================================================================
        -- 1. Pre-Swizzle Multiplexer (Inject Predicates if Logic Op)
        -- Determines the base data that will be fed into the swizzle crossbar.
        -- ====================================================================
        for i in 0 to 3 loop
            if is_logic_op = '1' then
                -- Zero-pad the 1-bit predicate to a full 32-bit word.
                -- This allows the standard 32-bit bitwise ALU to operate on PRFs.
                mux_a(i) <= x"0000000" & "000" & prf_a_in(i);
                mux_b(i) <= x"0000000" & "000" & prf_b_in(i);
            else
                -- Standard operation: Pass standard math vectors through directly.
                mux_a(i) <= vec_a_in(i);
                mux_b(i) <= vec_b_in(i);
            end if;
        end loop;

        -- ====================================================================
        -- 2. Swizzle Routing Channel A
        -- Routes `mux_a` based on the 3-bit selection mode.
        -- ====================================================================
        case swiz_sel_a is
            when SWIZ_X =>
                vec_a_out <= (mux_a(0), mux_a(0), mux_a(0), mux_a(0)); -- Broadcast X
            when SWIZ_Y =>
                vec_a_out <= (mux_a(1), mux_a(1), mux_a(1), mux_a(1)); -- Broadcast Y
            when SWIZ_Z =>
                vec_a_out <= (mux_a(2), mux_a(2), mux_a(2), mux_a(2)); -- Broadcast Z
            when SWIZ_W =>
                vec_a_out <= (mux_a(3), mux_a(3), mux_a(3), mux_a(3)); -- Broadcast W
            when others => 
                vec_a_out <= mux_a; -- SWIZ_PASS: Direct 1-to-1 passthrough
        end case;

        -- ====================================================================
        -- 3. Swizzle Routing Channel B
        -- Routes `mux_b` based on the 3-bit selection mode.
        -- ====================================================================
        case swiz_sel_b is
            when SWIZ_X =>
                vec_b_out <= (mux_b(0), mux_b(0), mux_b(0), mux_b(0)); -- Broadcast X
            when SWIZ_Y =>
                vec_b_out <= (mux_b(1), mux_b(1), mux_b(1), mux_b(1)); -- Broadcast Y
            when SWIZ_Z =>
                vec_b_out <= (mux_b(2), mux_b(2), mux_b(2), mux_b(2)); -- Broadcast Z
            when SWIZ_W =>
                vec_b_out <= (mux_b(3), mux_b(3), mux_b(3), mux_b(3)); -- Broadcast W
            when others => 
                vec_b_out <= mux_b; -- SWIZ_PASS: Direct 1-to-1 passthrough
        end case;
    end process;

end architecture rtl;
