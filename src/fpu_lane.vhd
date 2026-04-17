-- =============================================================================
-- fpu_lane.vhd — Floating-Point Unit Lane (Multi-Core Parallel Pipeline)
-- =============================================================================
--
-- WHY THIS COMPONENT EXISTS:
--   Each thread lane in the SIMT processor needs the full set of IEEE 754
--   floating-point operations required by real shader workloads: basic
--   arithmetic (FADD, FSUB, FMUL, FMADD), reciprocal, square root, and the
--   transcendentals (LOG2, EXP2, SIN, COS) plus MIN/MAX, comparisons (LT, EQ),
--   and integer-float conversion (FIX2FLOAT, FLOAT2FIX). Each operation is
--   implemented as a separate IP core with its own fixed latency.
--
--   Rather than timesharing a single FPU core across operations (which would
--   require dynamic scheduling and stall logic), ALL IP cores run in parallel
--   every cycle. The opcode pipeline register tells the output MUX which IP's
--   result to inject into the shared pipeline at the correct cycle. This
--   trading of area for simplicity keeps the control logic minimal and ensures
--   that every instruction always takes exactly FPU_MAX_LATENCY cycles — the
--   same contract that alu_lane meets via its shift register.
--
-- HOW TO USE:
--   - Drive opcode, valid_in, op_a, op_b, op_c (and cmp_invert / cmp_swap for
--     comparison instructions) on the cycle the instruction is issued.
--   - result, comp_flag, valid_out appear FPU_MAX_LATENCY cycles later.
--   - For FADD, FSUB, FMUL: the FMADD unit is reused (see INPUT CONDITIONING).
--     op_c is unused for these three; the process below substitutes constants.
--   - For FCMP: set the opcode to OP_FCMP_LT or OP_FCMP_EQ.
--     cmp_invert='1' flips the result (LT becomes GE, EQ becomes NEQ) without
--     extra hardware. cmp_swap='1' swaps op_a and op_b (so GT/GE are reduced
--     to LT/LE with swapped inputs).
--   - For PAND/POR/PXOR: the swizzle network must pre-place the 1-bit boolean
--     predicate into bit 0 of op_a and op_b before issuing the instruction.
--     The result appears in comp_flag after FPU_MAX_LATENCY cycles.
--
-- PORT DESCRIPTIONS:
--   clk          : System clock. All IP cores and the shared pipeline are
--                  clocked on the rising edge.
--   reset        : Synchronous active-high reset.
--   opcode       : 6-bit instruction opcode, sampled on every rising edge into
--                  opcode_pipe(1). The pipeline carries it forward so the output
--                  MUX can inspect opcode_pipe(LAT) to decide which IP result
--                  to select at exactly the right cycle.
--   valid_in     : Asserted for one cycle when the lane is being issued a new
--                  instruction. Propagates through valid_pipe; valid_out fires
--                  FPU_MAX_LATENCY stages later (see note on valid_out below).
--   cmp_invert   : '1' flips the boolean sense of a floating-point comparison:
--                    LT (a<b)  -> GE (a>=b)
--                    EQ (a==b) -> NEQ (a!=b)
--                  Piped alongside the opcode so the inversion is applied at the
--                  cycle the raw IP result emerges, not at issue time.
--   cmp_swap     : '1' swaps op_a and op_b before feeding them to the CMP IPs.
--                  GT (a>b) is implemented as LT with swapped inputs; GE (a>=b)
--                  is implemented as LE = NOT LT with swap + invert. This avoids
--                  instantiating separate GT/GE IP cores.
--
--   op_a         : 32-bit IEEE 754 source operand A.
--   op_b         : 32-bit IEEE 754 source operand B.
--   op_c         : 32-bit IEEE 754 source operand C (addend for FMADD only;
--                  ignored for FADD/FSUB/FMUL which substitute a constant).
--
--   result       : 32-bit IEEE 754 result, valid FPU_MAX_LATENCY cycles after
--                  valid_in. Undefined for comparison instructions (use
--                  comp_flag instead).
--   comp_flag    : 1-bit comparison result for FCMP / predicate logic
--                  instructions. Undefined for non-comparison instructions.
--   valid_out    : High for one cycle when result and comp_flag are valid.
--                  NOTE: driven from valid_pipe(FPU_MAX_LATENCY), aligned with
--                  the output process which resolves result combinationally from
--                  stage FPU_MAX_LATENCY data. This keeps valid_out and result
--                  in phase.
--
-- TIMING / LATENCY:
--   Total input-to-output : FPU_MAX_LATENCY cycles for every opcode.
--   FPU_MAX_LATENCY       : defined in processor_constants_pkg; must be >=
--                           the longest individual IP latency constant (LAT_*).
--   valid_out             : appears FPU_MAX_LATENCY pipeline stages after
--                           valid_in, combinationally aligned with the final
--                           output MUX — see architecture body.
--   Reset recovery        : 1 cycle to clear valid_pipe; IP core drain time
--                           depends on the longest IP latency.
--
-- DESIGN NOTE — WHY ALL IPs RUN IN PARALLEL:
--   Alternative approaches include (a) a single reconfigurable FPU core that
--   changes function based on opcode, or (b) dynamic arbitration with stalls.
--   Both require the issue logic to know when an FPU is free. Parallel always-on
--   IPs remove that complexity entirely: the lane is always ready to accept a
--   new instruction every cycle (throughput = 1 instruction/cycle/lane), and the
--   only control structure needed is the opcode pipeline — a simple shift register.
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity fpu_lane is
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        
        -- Control
        opcode       : in  std_logic_vector(5 downto 0);
        valid_in     : in  std_logic;
        cmp_invert   : in  std_logic; -- '1' flips LT to GE, EQ to NEQ
        cmp_swap     : in  std_logic; -- '1' swaps A and B operands
        
        -- Data Inputs
        op_a         : in  word_t;
        op_b         : in  word_t;
        op_c         : in  word_t;
        
        -- Synchronized Outputs (Arrives exactly FPU_MAX_LATENCY cycles later)
        result       : out word_t;
        valid_out    : out std_logic;
        comp_flag    : out std_logic 
    );
end entity;

architecture rtl of fpu_lane is

    -- IEEE 754 single-precision constants used to synthesise FADD/FSUB/FMUL
    -- from the FMADD unit (see INPUT CONDITIONING section for explanation).
    constant FLOAT_ONE  : word_t := x"3F800000"; -- 1.0f in IEEE 754
    constant FLOAT_ZERO : word_t := x"00000000"; -- 0.0f (positive zero)

    -- Control pipelines: these carry the opcode and modifier flags alongside
    -- the data so that the injection MUX at each stage knows which IP's output
    -- to select. Indexed 1 to FPU_MAX_LATENCY so that opcode_pipe(k) holds
    -- the opcode of the instruction that was issued k cycles ago.
    type opcode_pipe_t is array (1 to FPU_MAX_LATENCY) of std_logic_vector(5 downto 0);
    signal opcode_pipe   : opcode_pipe_t := (others => (others => '0'));
    signal valid_pipe    : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');
    -- cmp_inv_pipe must travel alongside the opcode so the XOR inversion is
    -- applied at the exact cycle the raw comparison result exits its IP core,
    -- not one cycle early or late.
    signal cmp_inv_pipe  : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');

    -- FMADD input mux signals. The FMADD core is always running; these signals
    -- select what it actually computes based on the current opcode.
    signal madd_a_in, madd_b_in, madd_c_in : word_t;
    -- CMP input mux signals, selected by cmp_swap.
    signal cmp_a_in, cmp_b_in              : word_t;
    -- op_b with the IEEE 754 sign bit flipped = negation. Used by FSUB to feed
    -- -(b) into the FMADD addend without a separate negation IP core.
    signal op_b_neg                        : word_t;

    -- Raw outputs from each IP core. All IPs run every cycle; only the correct
    -- one's output is gated into the shared pipeline at the right stage.
    signal raw_madd, raw_div, raw_sqrt, raw_log2, raw_exp2 : word_t;
    signal raw_sin, raw_min, raw_max, raw_i2f, raw_f2i : word_t; -- fp_cos_0 removed to save ALMs
    signal raw_lt, raw_eq : std_logic;

    -- Combinational predicate logic results. These are zero-latency (pure gates
    -- on bit 0 of the operands) and injected at pipeline stage i=1.
    signal raw_pand, raw_por, raw_pxor : std_logic;

    -- The shared result pipeline. Every IP injects its result at the pipeline
    -- stage that corresponds to its own latency (stage = LAT_xxx). The pipeline
    -- shifts right each cycle so the result propagates to FPU_MAX_LATENCY.
    -- WHY a single shared pipeline rather than one per IP: with 13+ IP cores,
    -- having separate pipelines would require a wide output MUX at the tail end.
    -- The shared pipeline instead performs a narrow injection at each stage,
    -- which distributes the MUX logic evenly and fits better in pipelined FPGA
    -- routing.
    type shared_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal shared_res_pipe : shared_pipe_t := (others => (others => '0'));
    signal shared_cmp_pipe : std_logic_vector(1 to FPU_MAX_LATENCY) := (others => '0');

begin

    -- ========================================================================
    -- INPUT CONDITIONING
    -- ========================================================================
    -- WHY bitwise sign-flip instead of a FP negation IP: IEEE 754 negation is
    -- trivially the sign bit inverted with all other bits unchanged (assuming
    -- no NaN payload manipulation is needed, which is true for FSUB on
    -- well-formed shader values). This single-LUT operation avoids instantiating
    -- a dedicated negate core and its attendant latency / pipeline management.
    op_b_neg <= (not op_b(31)) & op_b(30 downto 0);

    -- WHY cmp_swap instead of separate GT/GE opcodes: the comparison IP cores
    -- implement LT and EQ. Implementing GT as LT(b, a) (swapped operands) and
    -- GE as NOT LT(a, b) (inversion) reuses the same two IP instances for four
    -- comparison operators. Adding separate GT/GE IPs would double the CMP
    -- hardware for no accuracy or throughput benefit.
    cmp_a_in <= op_b when cmp_swap = '1' else op_a;
    cmp_b_in <= op_a when cmp_swap = '1' else op_b;

    -- WHY bit 0 only for predicate logic: the swizzle network pre-loads the
    -- 1-bit predicate boolean into bit 0 of each operand word before the FPU
    -- lane is issued a PAND/POR/PXOR. Bits [31:1] are zero. Operating only on
    -- bit 0 is therefore correct and avoids a wider reduction. This also means
    -- PAND/POR/PXOR are purely combinational — no IP core, no latency, just
    -- three gates — which is why they are injected at stage i=1 below.
    raw_pand <= op_a(0) and op_b(0);
    raw_por  <= op_a(0)  or op_b(0);
    raw_pxor <= op_a(0) xor op_b(0);

    -- WHY reuse FMADD for FADD/FSUB/FMUL:
    --   FADD: result = a * 1.0 + b   (b_in = FLOAT_ONE, c_in = op_b)
    --   FSUB: result = a * 1.0 + (-b) (b_in = FLOAT_ONE, c_in = -op_b)
    --   FMUL: result = a * b + 0.0   (c_in = FLOAT_ZERO)
    -- All three collapse to FMADD with different constant inputs, saving the
    -- area of a standalone FADD and FMUL IP while sharing the same latency
    -- (LAT_FMADD), which simplifies the opcode pipeline decode.
    process(opcode, op_a, op_b, op_c, op_b_neg)
    begin
        -- Default: pass all three operands through as a true FMADD (a*b+c).
        madd_a_in <= op_a; madd_b_in <= op_b; madd_c_in <= op_c;
        case opcode is
            when OP_FADD => madd_b_in <= FLOAT_ONE;  madd_c_in <= op_b;
            when OP_FSUB => madd_b_in <= FLOAT_ONE;  madd_c_in <= op_b_neg;
            when OP_FMUL => madd_c_in <= FLOAT_ZERO;
            -- MOV: result = op_a * 1.0 + 0.0 = op_a. Routes MOV through the
            -- same FMADD pipeline so it has the same latency as all other FPU
            -- instructions and writeback happens at the correct cycle.
            when OP_MOV  => madd_b_in <= FLOAT_ONE;  madd_c_in <= FLOAT_ZERO;
            when others  => null;
        end case;
    end process;

    -- ========================================================================
    -- HARDWARE IP CORES (Using actual latencies)
    -- ========================================================================
    -- NOTE: must be modified for synthesis — the simulation IP stubs are
    -- parameterised on 'latency' to allow cycle-accurate simulation. Real
    -- synthesis targets (e.g. Xilinx FP IP, Intel DSP blocks) use fixed
    -- pipeline depths that must match the LAT_* constants in
    -- processor_constants_pkg.
    --
    -- WHY en=>'1' permanently: all IPs run continuously. Disabling an IP to
    -- save power when its opcode is not in flight would require tracking
    -- occupancy across the full pipeline depth — more hardware than the power
    -- savings are worth for a small warp processor.
    u_fp_madd : entity work.fp_multiply_add_0 generic map(latency=>LAT_FMADD)    port map(clk=>clk, areset=>reset, a=>madd_a_in, b=>madd_b_in, c=>madd_c_in, q=>raw_madd);
    u_fp_div  : entity work.fp_div_0          generic map(latency=>LAT_FDIV)     port map(clk=>clk, areset=>reset, a=>op_a, b=>op_b, q=>raw_div);
    u_fp_sqrt : entity work.fp_sqrt_0         generic map(latency=>LAT_FSQRT)    port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_sqrt);
    u_fp_log2 : entity work.fp_log2_0         generic map(latency=>LAT_FLOG2)    port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_log2);
    u_fp_exp2 : entity work.fp_exp2_0         generic map(latency=>LAT_FEXP2)    port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_exp2);
    u_fp_sin  : entity work.fp_sin_0          generic map(latency=>LAT_FSIN)     port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_sin);
    -- fp_cos_0 removed to save ~600-700 ALMs per FPU lane; use SIN with phase offset in shader
    u_fp_min  : entity work.fp_min_0          generic map(latency=>LAT_FMIN)     port map(clk=>clk, areset=>reset, a=>op_a, b=>op_b, q=>raw_min);
    u_fp_max  : entity work.fp_max_0          generic map(latency=>LAT_FMAX)     port map(clk=>clk, areset=>reset, a=>op_a, b=>op_b, q=>raw_max);
    u_fp_i2f  : entity work.fp_fix2float_0    generic map(latency=>LAT_I2F)      port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_i2f);
    u_fp_f2i  : entity work.fp_float2fix_0    generic map(latency=>LAT_F2I)      port map(clk=>clk, areset=>reset, a=>op_a, q=>raw_f2i);

    -- CMP cores receive the (possibly swapped) operands so that GT/GE work
    -- correctly without needing separate IP instances.
    u_fp_lt   : entity work.fp_lt_0           generic map(latency=>LAT_FCMP_LT)  port map(clk=>clk, areset=>reset, a=>cmp_a_in, b=>cmp_b_in, q(0)=>raw_lt);
    u_fp_eq   : entity work.fp_eq_0           generic map(latency=>LAT_FCMP_EQ)  port map(clk=>clk, areset=>reset, a=>cmp_a_in, b=>cmp_b_in, q(0)=>raw_eq);

    -- ========================================================================
    -- SEQUENTIAL PIPELINE SHIFT & MULTIPLEXED INJECTION
    -- ========================================================================
    -- This process does two things simultaneously each clock cycle:
    --   1. Advances the opcode/valid/cmp_inv control pipelines by one stage.
    --   2. For each pipeline stage i, checks whether any IP core has just
    --      completed its computation (i.e., LAT_xxx == i-1) AND whether the
    --      instruction in that pipeline slot called for that IP. If so, it
    --      injects the IP's raw output into shared_res_pipe or shared_cmp_pipe
    --      at stage i, overwriting the default shift-forward value.
    --
    -- WHY "LAT_xxx = i - 1" and not "LAT_xxx = i": the IP core produces its
    -- output combinationally after LAT_xxx registered pipeline stages. In the
    -- same clock cycle that the output appears on raw_xxx, the for-loop is
    -- registering it into shared_res_pipe(i). That register sits one stage
    -- ahead (i = LAT+1 in 1-based terms), hence the i-1 comparison.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_pipe <= (others => '0');
            else
                -- 1. Shift Control Signals
                -- Index 1 holds the opcode/valid issued THIS cycle;
                -- opcode_pipe(k) holds it k cycles from now when the
                -- corresponding IP result emerges.
                valid_pipe(1)   <= valid_in;
                opcode_pipe(1)  <= opcode;
                cmp_inv_pipe(1) <= cmp_invert;

                for i in 2 to FPU_MAX_LATENCY loop
                    valid_pipe(i)   <= valid_pipe(i - 1);
                    opcode_pipe(i)  <= opcode_pipe(i - 1);
                    cmp_inv_pipe(i) <= cmp_inv_pipe(i - 1);
                end loop;

                -- 2. Shift Data Pipeline & Inject IP Outputs
                for i in 1 to FPU_MAX_LATENCY loop

                    -- Default: propagate previous stage's value forward.
                    -- WHY initialise stage 1 to zero instead of propagating:
                    -- stage 0 does not exist in shared_res_pipe (it is 1-based);
                    -- zeroing stage 1 ensures no stale data leaks when no IP
                    -- fires at this stage. All subsequent stages overwrite via
                    -- the shift, and an injection overwrites again if needed.
                    if i = 1 then
                        shared_res_pipe(i) <= (others => '0');
                        shared_cmp_pipe(i) <= '0';
                    else
                        shared_res_pipe(i) <= shared_res_pipe(i-1);
                        shared_cmp_pipe(i) <= shared_cmp_pipe(i-1);
                    end if;

                    -- Floating Point Math Injections.
                    -- WHY all four opcodes share one injection block for FMADD:
                    -- FADD, FSUB, FMUL, and FMADD all feed the same IP core
                    -- (with different constant inputs, set up in INPUT
                    -- CONDITIONING). Their results emerge simultaneously and
                    -- must all be captured at the same pipeline stage.
                    if LAT_FMADD = i - 1 then
                        if opcode_pipe(LAT_FMADD) = OP_FADD or opcode_pipe(LAT_FMADD) = OP_FSUB or
                           opcode_pipe(LAT_FMADD) = OP_FMUL or opcode_pipe(LAT_FMADD) = OP_FMADD or
                           opcode_pipe(LAT_FMADD) = OP_MOV then
                            shared_res_pipe(i) <= raw_madd;
                        end if;
                    end if;

                    if LAT_FDIV = i - 1 then
                        if opcode_pipe(LAT_FDIV) = OP_FDIV then shared_res_pipe(i) <= raw_div; end if;
                    end if;
                    if LAT_FSQRT = i - 1 then
                        if opcode_pipe(LAT_FSQRT) = OP_FSQRT then shared_res_pipe(i) <= raw_sqrt; end if;
                    end if;
                    if LAT_FLOG2 = i - 1 then
                        if opcode_pipe(LAT_FLOG2) = OP_FLOG2 then shared_res_pipe(i) <= raw_log2; end if;
                    end if;
                    if LAT_FEXP2 = i - 1 then
                        if opcode_pipe(LAT_FEXP2) = OP_FEXP2 then shared_res_pipe(i) <= raw_exp2; end if;
                    end if;
                    if LAT_FSIN = i - 1 then
                        if opcode_pipe(LAT_FSIN) = OP_SIN then shared_res_pipe(i) <= raw_sin; end if;
                    end if;
                    if LAT_FMIN = i - 1 then
                        if opcode_pipe(LAT_FMIN) = OP_FMIN then shared_res_pipe(i) <= raw_min; end if;
                    end if;
                    if LAT_FMAX = i - 1 then
                        if opcode_pipe(LAT_FMAX) = OP_FMAX then shared_res_pipe(i) <= raw_max; end if;
                    end if;
                    if LAT_I2F = i - 1 then
                        if opcode_pipe(LAT_I2F) = OP_I2F then shared_res_pipe(i) <= raw_i2f; end if;
                    end if;
                    if LAT_F2I = i - 1 then
                        if opcode_pipe(LAT_F2I) = OP_F2I then shared_res_pipe(i) <= raw_f2i; end if;
                    end if;

                    -- Floating Point Comparisons.
                    -- WHY XOR with cmp_inv_pipe at injection time (not at the
                    -- output): applying the inversion as early as possible avoids
                    -- carrying an extra pipeline bit all the way to the output
                    -- MUX. The inversion is a single gate and adds no area to the
                    -- shared pipeline stages that follow.
                    if LAT_FCMP_LT = i - 1 then
                        if opcode_pipe(LAT_FCMP_LT) = OP_FCMP_LT then
                            shared_cmp_pipe(i) <= raw_lt xor cmp_inv_pipe(LAT_FCMP_LT);
                        end if;
                    end if;
                    if LAT_FCMP_EQ = i - 1 then
                        if opcode_pipe(LAT_FCMP_EQ) = OP_FCMP_EQ then
                            shared_cmp_pipe(i) <= raw_eq xor cmp_inv_pipe(LAT_FCMP_EQ);
                        end if;
                    end if;

                    -- =================================================================
                    -- Zero-Latency Predicate Logic (Injected at i=1)
                    -- Evaluates the UNREGISTERED 'opcode' input port so it aligns
                    -- perfectly with the combinational 'raw_pand/por/pxor' derived
                    -- from the current inputs.
                    --
                    -- WHY use the raw 'opcode' port rather than opcode_pipe(0):
                    -- PAND/POR/PXOR have zero real latency — raw_pxor etc. are pure
                    -- combinational outputs computed from the current op_a/op_b.
                    -- opcode_pipe(0) is only written at the NEXT rising edge (it is a
                    -- registered copy), so using it would introduce a one-cycle
                    -- misalignment between the combinational result and the opcode
                    -- that produced it. Reading the unregistered 'opcode' port here
                    -- (inside a clocked process) means "capture the opcode that is
                    -- present RIGHT NOW alongside the combinational result that is
                    -- also present RIGHT NOW", which is the correct zero-cycle match.
                    -- =================================================================
                    if 0 = i - 1 then
                        -- Zero-latency predicate logic. MOV is no longer here;
                        -- it now routes through the FMADD pipeline (see INPUT
                        -- CONDITIONING) so its writeback aligns with all other
                        -- FPU instructions at FPU_MAX_LATENCY cycles.
                        if opcode = OP_PAND then shared_cmp_pipe(i) <= raw_pand; end if;
                        if opcode = OP_POR  then shared_cmp_pipe(i) <= raw_por;  end if;
                        if opcode = OP_PXOR then shared_cmp_pipe(i) <= raw_pxor; end if;
                    end if;

                end loop;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- FINAL OUTPUT COMBINATIONAL ROUTING
    -- ========================================================================
    -- WHY this process exists at all (instead of just tapping shared_res_pipe
    -- at FPU_MAX_LATENCY): if any IP's latency equals FPU_MAX_LATENCY exactly,
    -- the injection into shared_res_pipe at stage FPU_MAX_LATENCY would only
    -- appear one cycle later (after an extra register stage). The combinational
    -- output process bypasses that extra register by reading raw_xxx directly
    -- when the latency condition is met, keeping the actual output aligned with
    -- FPU_MAX_LATENCY cycles regardless of which IP stage is deepest.
    --
    -- In practice, FPU_MAX_LATENCY is set to the longest IP latency, so these
    -- combinational override paths will fire for at least one IP (the slowest).
    process(shared_res_pipe, shared_cmp_pipe, opcode_pipe, cmp_inv_pipe, opcode, op_a,
            raw_madd, raw_div, raw_sqrt, raw_log2, raw_exp2, raw_sin,
            raw_min, raw_max, raw_i2f, raw_f2i, raw_lt, raw_eq, raw_pand, raw_por, raw_pxor)
    begin
        -- Default: take results from the end of the shared pipeline.
        result    <= shared_res_pipe(FPU_MAX_LATENCY);
        comp_flag <= shared_cmp_pipe(FPU_MAX_LATENCY);

        -- If any IP's latency equals FPU_MAX_LATENCY, bypass the final
        -- pipeline register and take the raw IP output directly. This
        -- eliminates one register of extra latency for the deepest IP.
        if LAT_FMADD = FPU_MAX_LATENCY then
            if opcode_pipe(FPU_MAX_LATENCY) = OP_FADD or opcode_pipe(FPU_MAX_LATENCY) = OP_FSUB or
               opcode_pipe(FPU_MAX_LATENCY) = OP_FMUL or opcode_pipe(FPU_MAX_LATENCY) = OP_FMADD or
               opcode_pipe(FPU_MAX_LATENCY) = OP_MOV then
                result <= raw_madd;
            end if;
        end if;
        if LAT_FDIV  = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FDIV  then result <= raw_div;  end if;
        if LAT_FSQRT = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FSQRT then result <= raw_sqrt; end if;
        if LAT_FLOG2 = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FLOG2 then result <= raw_log2; end if;
        if LAT_FEXP2 = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FEXP2 then result <= raw_exp2; end if;
        if LAT_FSIN  = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_SIN   then result <= raw_sin;  end if;
        if LAT_FMIN  = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FMIN  then result <= raw_min;  end if;
        if LAT_FMAX  = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FMAX  then result <= raw_max;  end if;
        if LAT_I2F   = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_I2F   then result <= raw_i2f;  end if;
        if LAT_F2I   = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_F2I   then result <= raw_f2i;  end if;

        -- Same bypass for comparisons: apply inversion combinationally at the
        -- output so that cmp_inv_pipe(FPU_MAX_LATENCY) is used, which holds
        -- the cmp_invert flag for the instruction currently being output.
        if LAT_FCMP_LT = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FCMP_LT then comp_flag <= raw_lt xor cmp_inv_pipe(FPU_MAX_LATENCY); end if;
        if LAT_FCMP_EQ = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY) = OP_FCMP_EQ then comp_flag <= raw_eq xor cmp_inv_pipe(FPU_MAX_LATENCY); end if;

        -- WHY this guard is "0 = FPU_MAX_LATENCY": PXOR/PAND/POR are zero
        -- real-latency ops. If FPU_MAX_LATENCY were somehow 0 (impossible in
        -- practice, but the code handles it defensively), they would bypass
        -- the pipeline entirely and read the unregistered opcode. In the
        -- realistic case FPU_MAX_LATENCY > 0, this branch is dead code that
        -- synthesis eliminates, adding zero area.
        if 0 = FPU_MAX_LATENCY then
            -- MOV removed: it now uses the FMADD pipeline path.
            if opcode = OP_PAND then comp_flag <= raw_pand; end if;
            if opcode = OP_POR  then comp_flag <= raw_por;  end if;
            if opcode = OP_PXOR then comp_flag <= raw_pxor; end if;
        end if;

    end process;

    -- WHY valid_pipe(FPU_MAX_LATENCY) and not a later stage:
    -- The output process above resolves result and comp_flag COMBINATIONALLY
    -- from data registered at stage FPU_MAX_LATENCY (opcode_pipe, shared pipes)
    -- or from raw IP outputs that become valid at that same cycle.
    -- valid_out pulses on the same clock cycle the combinational output is stable.
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
