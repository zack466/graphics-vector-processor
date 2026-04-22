-- ============================================================================
-- FILE: vector_reduction_unit.vhd
-- COMPONENT: 4-Component Floating-Point Reduction Unit
-- ============================================================================
--
-- Standard vector instructions operate component-wise (x op x, y op y, …),
-- producing a 4-wide result. Certain operations in 3D graphics and physics
-- require collapsing a 4-component vector into a single scalar: dot products,
-- magnitudes, and L1-norms all involve this "horizontal" reduction.  Rather
-- than serialising the reduction over multiple instructions (4 multiplies +
-- 3 adds = 7 dependent ops), this unit exposes a single instruction that
-- computes the entire sum-of-products in hardware in one FPU_MAX_LATENCY pass.
--
-- SUPPORTED MODES (red_mode encoding from processor_constants_pkg)
-- ---------------------------------------------------------------
-- RED_MODE_DOT     : a . b  =  a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w
--                   Full 4D dot product of two independent input vectors.
--
-- RED_MODE_SQ_MAG  : |a|^2  =  a.x^2 + a.y^2 + a.z^2 + a.w^2
--                   Squared magnitude of a.  Implemented by routing a into
--                   both A and B ports of the IP core — no extra multipliers.
--
-- RED_MODE_SUM     : a.x + a.y + a.z + a.w
--                   Component sum of a.  Implemented by setting b = 1.0f so
--                   the multiply is an identity and only the adder tree acts.
--
-- RED_MODE_ABS_SUM : |a.x| + |a.y| + |a.z| + |a.w|
--                   L1 norm of a.  Absolute value is free in IEEE 754: strip
--                   the sign bit (bit 31) before feeding into the SUM path.
--
-- PARTIAL REDUCTION VIA reduce_mask
-- ----------------------------------
-- reduce_mask is a 4-bit per-component gate (XYZW order, bit 0 = X).
-- When a bit is '0', both cond_a(i) and cond_b(i) are set to 0.0f, which
-- contributes exactly zero to the sum regardless of mode.  This lets the
-- programmer compute, e.g., a 3D dot product by masking the W component:
--   reduce_mask = "0111" (X,Y,Z active, W masked out).
--
--
-- Inputs:
--  - clk         : System clock.  All registers are rising-edge triggered.
--  - reset       : Synchronous active-high reset.  Flushes the valid shift
--                  register.
--  - valid_in    : Asserted for one cycle when a new reduction is presented on
--                  vec_a/vec_b.  Enters the valid shift register at index 0.
--  - vec_a       : First 4-component input vector (array of four 32-bit floats).
--  - vec_b       : Second 4-component input vector.  Ignored for SQ_MAG, SUM,
--                  and ABS_SUM modes (cond_b is overwritten by mode steering).
--  - reduce_mask : 4-bit component enable mask.  Bit i='0' forces component i
--                  to 0.0f, excluding it from the sum.
--  - red_mode    : 2-bit mode selector.  See SUPPORTED MODES above.
--
-- Outputs:
--  - result      : Scalar float output.  Valid FPU_MAX_LATENCY cycles after
--                  valid_in.  Should be broadcast to all four VRF write lanes.
--  - valid_out   : '1' exactly FPU_MAX_LATENCY cycles after valid_in, aligned
--                  with result.  Used by the writeback controller to gate writes.
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity vector_reduction_unit is
    port (
        clk         : in  std_logic;    -- system clock
        reset       : in  std_logic;    -- system reset
        
        -- Data Inputs
        valid_in    : in  std_logic;
        vec_a       : in  vector_t;
        vec_b       : in  vector_t;
        
        -- Reduction Modifiers
        reduce_mask : in  std_logic_vector(3 downto 0); -- Mask directly from instruction
        red_mode    : in  std_logic_vector(1 downto 0); -- Mode directly from instruction
        
        -- Output
        result      : out word_t; 
        valid_out   : out std_logic
    );
end entity;

architecture rtl of vector_reduction_unit is

    -- IEEE 754 single-precision constants used for mode steering.
    -- These are injected as literal bit patterns rather than using ieee.math_real
    -- so the values are synthesis-safe and do not require a simulation library.
    constant FLOAT_ZERO : word_t := x"00000000"; -- +0.0f  (sign=0, exp=0, mant=0)
    constant FLOAT_ONE  : word_t := x"3F800000"; -- +1.0f  (sign=0, exp=127, mant=0)

    -- cond_a / cond_b are the mode-steered and mask-gated inputs that feed
    -- directly into the IP core.  They are combinational signals (driven by
    -- the process below, no registers).
    signal cond_a : vector_t;
    signal cond_b : vector_t;

    -- valid_pipe is a one-hot shift register that tracks when an operation is
    -- in flight.  valid_pipe(1) is loaded from valid_in each cycle;
    -- valid_pipe(FPU_MAX_LATENCY) is the output valid_out.
    signal valid_pipe : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');

    -- PAD_STAGES: cycles the res_pipe shift register adds after raw_result appears.
    -- WHY derived rather than literal: if LAT_REDUCT ever changes (e.g. a faster
    -- IP core is substituted), the padding automatically adjusts so the total
    -- latency remains FPU_MAX_LATENCY.  No manual update needed.
    constant PAD_STAGES : integer := FPU_MAX_LATENCY - LAT_REDUCT;

    -- res_pipe bridges the gap between LAT_REDUCT (when raw_result appears from
    -- the IP core) and FPU_MAX_LATENCY (when the writeback controller expects
    -- the result).  It is PAD_STAGES deep; if LAT_REDUCT == FPU_MAX_LATENCY
    -- PAD_STAGES = 0 and res_pipe degenerates to a 1-stage register.
    type res_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal res_pipe : res_pipe_t := (others => (others => '0'));

    -- raw_result is the unregistered output of the fp_scalar_product IP core.
    -- It becomes valid LAT_REDUCT cycles after cond_a/cond_b are presented.
    signal raw_result : word_t;

begin

    -- ========================================================================
    -- 1. COMBINATIONAL INPUT CONDITIONING
    -- ========================================================================
    process(vec_a, vec_b, reduce_mask, red_mode)
        variable temp_a, temp_b : word_t;
    begin
        for i in 0 to 3 loop

            -- Evaluate behavior based on the specific reduction mode.
            -- All four modes are expressed as variations of the dot-product
            -- operation: the key insight is that a*1 = a and a*a = a^2,
            -- so every mode maps onto the same a.b IP core with different inputs.
            case red_mode is
                when RED_MODE_DOT =>
                    -- Standard inner product: each component multiplied pairwise.
                    temp_a := vec_a(i);
                    temp_b := vec_b(i);

                when RED_MODE_SQ_MAG =>
                    -- Squared magnitude: route A into both ports so each term
                    -- becomes a(i)^2.  No separate squaring hardware needed.
                    temp_a := vec_a(i);
                    temp_b := vec_a(i); -- Route A into B for squaring

                when RED_MODE_SUM =>
                    -- Component sum: multiply each a(i) by 1.0, making the
                    -- multiply a no-op and leaving the adder tree to sum a.
                    temp_a := vec_a(i);
                    temp_b := FLOAT_ONE; -- Multiply by 1.0

                when RED_MODE_ABS_SUM =>
                    -- L1 norm: IEEE 754 absolute value is just clearing bit 31
                    -- (the sign bit), with no rounding or exponent adjustment.
                    -- Then multiply by 1.0 to use the sum path.
                    temp_a := '0' & vec_a(i)(30 downto 0); -- Strip sign bit
                    temp_b := FLOAT_ONE;

                when others =>
                    -- Undefined modes fall back to DOT behaviour.
                    temp_a := vec_a(i);
                    temp_b := vec_b(i);
            end case;

            -- Apply Component Masking.
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
    u_scalar_product : entity work.fp_scalar_product_0
        generic map (latency => LAT_REDUCT)
        port map (
            clk    => clk,
            areset => reset,
            a0     => cond_a(0), b0 => cond_b(0),
            a1     => cond_a(1), b1 => cond_b(1),
            a2     => cond_a(2), b2 => cond_b(2),
            a3     => cond_a(3), b3 => cond_b(3),
            q      => raw_result
        );

    -- ========================================================================
    -- 3. VALID SIGNAL & DATA PIPELINE
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Flush in-flight valid tokens so no spurious writeback occurs
                -- after a pipeline flush.  Data registers need not be reset
                -- because they are gated by valid_out at the writeback stage.
                valid_pipe <= (others => '0');
            else
                -- Shift the valid token through FPU_MAX_LATENCY stages so that
                -- valid_out aligns exactly with the padded result output.
                valid_pipe(1) <= valid_in;
                for i in 2 to FPU_MAX_LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                end loop;

                -- Shift the result padding pipeline.
                for i in 1 to FPU_MAX_LATENCY loop
                    if i = 1 then
                        -- Stage 1 default: fill with zeros until the IP result
                        -- arrives.  This avoids carrying stale data forward.
                        res_pipe(i) <= (others => '0');
                    else
                        res_pipe(i) <= res_pipe(i-1);
                    end if;

                    -- Inject the IP core output at the correct stage.
                    if LAT_REDUCT = i - 1 then
                        res_pipe(i) <= raw_result;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- 4. COMBINATIONAL OUTPUT ROUTING
    -- ========================================================================
    -- If LAT_REDUCT == FPU_MAX_LATENCY, the pipeline shift logic would 
    -- require an extra cycle (because i-1 = FPU_MAX_LATENCY is out of bounds).
    -- The combinational bypass extracts raw_result directly in this case.
    process(res_pipe, raw_result)
    begin
        if LAT_REDUCT = FPU_MAX_LATENCY then
            result <= raw_result;
        else
            result <= res_pipe(FPU_MAX_LATENCY);
        end if;
    end process;

    -- valid_out pulses on the same clock cycle the combinational output is stable.
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
