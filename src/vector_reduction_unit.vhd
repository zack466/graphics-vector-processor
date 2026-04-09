-- ============================================================================
-- vector_reduction_unit.vhd — 4-Component Floating-Point Reduction Unit
-- ============================================================================
--
-- WHY THIS COMPONENT EXISTS
-- -------------------------
-- Standard vector instructions operate component-wise (x op x, y op y, …),
-- producing a 4-wide result.  Certain operations in 3D graphics and physics
-- require collapsing a 4-component vector into a single scalar: dot products,
-- magnitudes, and L1-norms all involve this "horizontal" reduction.  Rather
-- than serialising the reduction over multiple instructions (4 multiplies +
-- 3 adds = 7 dependent ops), this unit exposes a single instruction that
-- computes the entire sum-of-products in hardware in one FPU_MAX_LATENCY pass.
--
-- All four modes are implemented by conditioning the inputs to a single shared
-- fp_scalar_product IP core: four pairwise multiplications followed by a
-- balanced adder tree.  This reuse keeps the synthesis area small — one IP
-- instance serves all modes through combinational input steering.
--
-- The result is a scalar float that is broadcast: all four components of the
-- destination VRF entry are written with the same value.  Downstream shader
-- code can then swizzle the scalar to any component position it needs.
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
-- HOW TO USE
-- ----------
-- 1. Drive vec_a, vec_b, reduce_mask, and red_mode combinationally from the
--    read stage of the pipeline (they feed a purely combinational conditioning
--    process before reaching the IP core).
-- 2. Assert valid_in='1' for the first cycle of each new operation.
-- 3. After FPU_MAX_LATENCY cycles, valid_out='1' and result contains the
--    scalar float.  Connect result to all four lanes of the destination VRF
--    write data bus to achieve the broadcast.
--
-- PORT DESCRIPTIONS
-- -----------------
-- clk         : System clock.  All registers are rising-edge triggered.
-- reset       : Synchronous active-high reset.  Flushes the valid shift
--               register; data pipelines settle to zero from initialisation.
-- valid_in    : Asserted for one cycle when a new reduction is presented on
--               vec_a/vec_b.  Enters the valid shift register at index 0.
-- vec_a       : First 4-component input vector (array of four 32-bit floats).
-- vec_b       : Second 4-component input vector.  Ignored for SQ_MAG, SUM,
--               and ABS_SUM modes (cond_b is overwritten by mode steering).
-- reduce_mask : 4-bit component enable mask.  Bit i='0' forces component i
--               to 0.0f, excluding it from the sum.
-- red_mode    : 2-bit mode selector.  See SUPPORTED MODES above.
-- result      : Scalar float output.  Valid FPU_MAX_LATENCY cycles after
--               valid_in.  Should be broadcast to all four VRF write lanes.
-- valid_out   : '1' exactly FPU_MAX_LATENCY cycles after valid_in, aligned
--               with result.  Used by the writeback controller to gate writes.
--
-- TIMING / LATENCY
-- ----------------
-- Combinational input conditioning  :   0 cycles  (same cycle as vec_a/b)
-- fp_scalar_product IP core         :   LAT_REDUCT cycles
-- Result capture + padding pipeline :   FPU_MAX_LATENCY - LAT_REDUCT cycles
-- Total input-to-output latency     :   FPU_MAX_LATENCY cycles
--
-- WHY PAD TO FPU_MAX_LATENCY?
-- The writeback controller uses a single FPU_MAX_LATENCY-deep shift register
-- for rd_addr and WE.  All execution units must present their results at the
-- same pipeline depth so the single controller works uniformly.  The padding
-- pipeline (res_pipe) bridges the gap when LAT_REDUCT < FPU_MAX_LATENCY.
-- ============================================================================

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
    -- in flight.  valid_pipe(0) is loaded from valid_in each cycle;
    -- valid_pipe(FPU_MAX_LATENCY) is the output valid_out.
    signal valid_pipe : std_logic_vector(FPU_MAX_LATENCY downto 0) := (others => '0');

    -- res_pipe bridges the gap between LAT_REDUCT (when raw_result appears from
    -- the IP core) and FPU_MAX_LATENCY (when the writeback controller expects
    -- the result).  If LAT_REDUCT == FPU_MAX_LATENCY this pipeline is 1 stage
    -- deep and simply registers raw_result once before output.
    type res_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal res_pipe : res_pipe_t := (others => (others => '0'));

    -- raw_result is the unregistered output of the fp_scalar_product IP core.
    -- It becomes valid LAT_REDUCT cycles after cond_a/cond_b are presented.
    signal raw_result : word_t;

    -- fp_scalar_product: Altera/Intel FPGA floating-point IP.
    -- Computes q = a0*b0 + a1*b1 + a2*b2 + a3*b3 with configurable latency.
    -- WHY this IP? It implements the full 4-wide sum-of-products in a single
    -- deeply-pipelined unit, far more efficiently than chaining individual FMA
    -- operations which would require 4x the adder logic and careful scheduling.
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
    -- WHY combinational (not registered)?  The inputs vec_a/vec_b come
    -- directly from the VRF read ports which are already registered by the
    -- VRF itself.  Adding another register stage here would increase the
    -- effective latency by one cycle, requiring FPU_MAX_LATENCY to be bumped
    -- accordingly.  Keeping this stage combinational holds the latency budget.
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
            -- WHY zero both A and B (not just one)?  Setting a(i)=0 alone would
            -- compute 0*b(i)=0 in IEEE 754, which is correct — but if b(i) is
            -- NaN or Inf, the result could be NaN.  Zeroing both operands
            -- guarantees the IP core sees a clean 0*0=0 for masked components,
            -- regardless of what is in the register file for that lane.
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
    -- NOTE: must be modified for synthesis (IP core name/generics may differ
    -- between Quartus versions and device families).
    -- en is tied to '1': the IP core runs every cycle.  The barrel scheduler
    -- feeds new data every cycle (one thread per cycle), so there is no reason
    -- to gate the IP core — doing so would add control complexity for no gain.
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
                valid_pipe(0) <= valid_in;
                for i in 1 to FPU_MAX_LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                end loop;

                -- Shift the result padding pipeline.
                -- WHY this two-part logic?  The IP core produces raw_result at
                -- stage LAT_REDUCT.  If LAT_REDUCT < FPU_MAX_LATENCY (i.e., the
                -- reduction unit is faster than the FPU lanes), the result must
                -- wait in res_pipe until the writeback controller's tap at
                -- FPU_MAX_LATENCY aligns with it.
                --
                -- The loop handles this by:
                --  (a) Defaulting each stage to shift from the previous stage.
                --  (b) Overriding stage (LAT_REDUCT+1) with raw_result when
                --      i-1 == LAT_REDUCT — this is the "injection point" where
                --      the IP output enters the padding pipeline.
                -- Stages 2..LAT_REDUCT are never reached if LAT_REDUCT=0, but
                -- the loop still works correctly because the if-condition fires
                -- at i=1 (0 = i-1 = 1-1).
                for i in 1 to FPU_MAX_LATENCY loop
                    if i = 1 then
                        -- Stage 1 default: fill with zeros until the IP result
                        -- arrives.  This avoids carrying stale data forward.
                        res_pipe(i) <= (others => '0');
                    else
                        res_pipe(i) <= res_pipe(i-1);
                    end if;

                    -- Inject the IP core output at the correct stage.
                    -- This if statement will fire exactly once per loop iteration
                    -- when i-1 == LAT_REDUCT, capturing raw_result into the
                    -- pipeline at the cycle it becomes valid.
                    if LAT_REDUCT = i - 1 then
                        res_pipe(i) <= raw_result;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- The scalar result is broadcast: the caller should replicate this value
    -- to all four component lanes of the destination VRF entry.
    result    <= res_pipe(FPU_MAX_LATENCY);

    -- valid_out is in phase with result — both are FPU_MAX_LATENCY cycles
    -- behind valid_in, providing a uniform timing interface to the writeback
    -- controller regardless of which reduction mode was selected.
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
