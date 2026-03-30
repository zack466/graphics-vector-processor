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
        
        -- Data Inputs (Scalar words specifically sliced for this lane)
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

    use work.processor_constants_pkg.all;

    -- ========================================================================
    -- IEEE-754 Hardware Constants
    -- ========================================================================
    constant FLOAT_ONE  : word_t := x"3F800000";
    constant FLOAT_ZERO : word_t := x"00000000";

    -- ========================================================================
    -- Internal Signals
    -- ========================================================================
    -- Control pipelines (Note: 0 to MAX-1 gives exactly MAX cycles of delay)
    type opcode_pipe_t is array (0 to FPU_MAX_LATENCY - 1) of std_logic_vector(5 downto 0);
    signal opcode_pipe : opcode_pipe_t := (others => (others => '0'));
    signal valid_pipe  : std_logic_vector(FPU_MAX_LATENCY - 1 downto 0) := (others => '0');

    -- MADD Input Multiplexing
    signal madd_a_in, madd_b_in, madd_c_in : word_t;
    signal op_b_neg : word_t;

    -- Raw IP outputs
    signal raw_madd, raw_rcp, raw_sqrt, raw_log2, raw_exp2 : word_t;
    signal raw_sin, raw_cos, raw_min, raw_max, raw_i2f, raw_f2i : word_t;
    signal raw_lt, raw_eq : std_logic;

    -- ========================================================================
    -- THE SHARED PIPELINE
    -- ========================================================================
    type shared_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal shared_res_pipe : shared_pipe_t := (others => (others => '0'));
    signal shared_cmp_pipe : std_logic_vector(1 to FPU_MAX_LATENCY) := (others => '0');

begin

    -- ========================================================================
    -- INPUT CONDITIONING
    -- ========================================================================
    op_b_neg <= (not op_b(31)) & op_b(30 downto 0);

    process(opcode, op_a, op_b, op_c, op_b_neg)
    begin
        madd_a_in <= op_a; madd_b_in <= op_b; madd_c_in <= op_c;
        case opcode is
            when OP_FADD => madd_b_in <= FLOAT_ONE; madd_c_in <= op_b;
            when OP_FSUB => madd_b_in <= FLOAT_ONE; madd_c_in <= op_b_neg;
            when OP_FMUL => madd_c_in <= FLOAT_ZERO;
            when others  => null;
        end case;
    end process;

    -- ========================================================================
    -- HARDWARE IP CORES (Using actual latencies)
    -- ========================================================================
    u_fp_madd : entity work.fp_mult_add generic map(latency=>LAT_FMADD) port map(clk=>clk, en=>'1', a=>madd_a_in, b=>madd_b_in, c=>madd_c_in, q=>raw_madd);
    u_fp_rcp  : entity work.fp_rcp      generic map(latency=>LAT_FRCP)  port map(clk=>clk, en=>'1', a=>op_a, q=>raw_rcp);
    u_fp_sqrt : entity work.fp_sqrt     generic map(latency=>LAT_FSQRT) port map(clk=>clk, en=>'1', a=>op_a, q=>raw_sqrt);
    u_fp_log2 : entity work.fp_log2     generic map(latency=>LAT_FLOG2) port map(clk=>clk, en=>'1', a=>op_a, q=>raw_log2);
    u_fp_exp2 : entity work.fp_exp2     generic map(latency=>LAT_FEXP2) port map(clk=>clk, en=>'1', a=>op_a, q=>raw_exp2);
    u_fp_sin  : entity work.fp_sin      generic map(latency=>LAT_FSIN)  port map(clk=>clk, en=>'1', a=>op_a, q=>raw_sin);
    u_fp_cos  : entity work.fp_cos      generic map(latency=>LAT_FCOS)  port map(clk=>clk, en=>'1', a=>op_a, q=>raw_cos);
    u_fp_min  : entity work.fp_min      generic map(latency=>LAT_FMIN)  port map(clk=>clk, en=>'1', a=>op_a, b=>op_b, q=>raw_min);
    u_fp_max  : entity work.fp_max      generic map(latency=>LAT_FMAX)  port map(clk=>clk, en=>'1', a=>op_a, b=>op_b, q=>raw_max);
    u_fp_i2f  : entity work.fp_fix2float generic map(latency=>LAT_I2F)   port map(clk=>clk, en=>'1', a=>op_a, q=>raw_i2f);
    u_fp_f2i  : entity work.fp_float2fix generic map(latency=>LAT_F2I)   port map(clk=>clk, en=>'1', a=>op_a, q=>raw_f2i);
    u_fp_lt   : entity work.fp_less_than generic map(latency=>LAT_FCMP_LT) port map(clk=>clk, en=>'1', a=>op_a, b=>op_b, q=>raw_lt);
    u_fp_eq   : entity work.fp_equal     generic map(latency=>LAT_FCMP_EQ) port map(clk=>clk, en=>'1', a=>op_a, b=>op_b, q=>raw_eq);


    -- ========================================================================
    -- SEQUENTIAL PIPELINE SHIFT & MULTIPLEXED INJECTION
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_pipe <= (others => '0');
                -- We only strictly need to reset valid_pipe. The math pipes will carry
                -- garbage data during invalid cycles, but they will be ignored at writeback.
            else
                -- 1. Shift Control Signals
                valid_pipe(0)  <= valid_in;
                opcode_pipe(0) <= opcode;
                for i in 1 to FPU_MAX_LATENCY - 1 loop
                    valid_pipe(i)  <= valid_pipe(i - 1);
                    opcode_pipe(i) <= opcode_pipe(i - 1);
                end loop;

                -- 2. Shift Data Pipeline & Inject IP Outputs
                for i in 1 to FPU_MAX_LATENCY loop
                    
                    -- Default: Shift from previous stage
                    if i = 1 then
                        shared_res_pipe(i) <= (others => '0');
                        shared_cmp_pipe(i) <= '0';
                    else
                        shared_res_pipe(i) <= shared_res_pipe(i-1);
                        shared_cmp_pipe(i) <= shared_cmp_pipe(i-1);
                    end if;

                    -- Overrides: Inject results precisely when they finish.
                    -- If Latency = L, output is stable during Cycle L. 
                    -- It is sampled into pipeline stage (L+1) using the opcode from Cycle L (index L-1).
                    
                    if LAT_FMADD = i - 1 then
                        if opcode_pipe(LAT_FMADD - 1) = OP_FADD or opcode_pipe(LAT_FMADD - 1) = OP_FSUB or 
                           opcode_pipe(LAT_FMADD - 1) = OP_FMUL or opcode_pipe(LAT_FMADD - 1) = OP_FMADD then
                            shared_res_pipe(i) <= raw_madd;
                        end if;
                    end if;

                    if LAT_FRCP = i - 1 then
                        if opcode_pipe(LAT_FRCP - 1) = OP_FRCP then shared_res_pipe(i) <= raw_rcp; end if;
                    end if;

                    if LAT_FSQRT = i - 1 then
                        if opcode_pipe(LAT_FSQRT - 1) = OP_FSQRT then shared_res_pipe(i) <= raw_sqrt; end if;
                    end if;

                    if LAT_FLOG2 = i - 1 then
                        if opcode_pipe(LAT_FLOG2 - 1) = OP_FLOG2 then shared_res_pipe(i) <= raw_log2; end if;
                    end if;

                    if LAT_FEXP2 = i - 1 then
                        if opcode_pipe(LAT_FEXP2 - 1) = OP_FEXP2 then shared_res_pipe(i) <= raw_exp2; end if;
                    end if;

                    if LAT_FSIN = i - 1 then
                        if opcode_pipe(LAT_FSIN - 1) = OP_SIN then shared_res_pipe(i) <= raw_sin; end if;
                    end if;

                    if LAT_FCOS = i - 1 then
                        if opcode_pipe(LAT_FCOS - 1) = OP_COS then shared_res_pipe(i) <= raw_cos; end if;
                    end if;

                    if LAT_FMIN = i - 1 then
                        if opcode_pipe(LAT_FMIN - 1) = OP_FMIN then shared_res_pipe(i) <= raw_min; end if;
                    end if;

                    if LAT_FMAX = i - 1 then
                        if opcode_pipe(LAT_FMAX - 1) = OP_FMAX then shared_res_pipe(i) <= raw_max; end if;
                    end if;

                    if LAT_I2F = i - 1 then
                        if opcode_pipe(LAT_I2F - 1) = OP_I2F then shared_res_pipe(i) <= raw_i2f; end if;
                    end if;

                    if LAT_F2I = i - 1 then
                        if opcode_pipe(LAT_F2I - 1) = OP_F2I then shared_res_pipe(i) <= raw_f2i; end if;
                    end if;

                    if LAT_FCMP_LT = i - 1 then
                        if opcode_pipe(LAT_FCMP_LT - 1) = OP_FCMP_LT then shared_cmp_pipe(i) <= raw_lt; end if;
                    end if;

                    if LAT_FCMP_EQ = i - 1 then
                        if opcode_pipe(LAT_FCMP_EQ - 1) = OP_FCMP_EQ then shared_cmp_pipe(i) <= raw_eq; end if;
                    end if;

                end loop;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- FINAL OUTPUT COMBINATIONAL ROUTING
    -- ========================================================================
    process(shared_res_pipe, shared_cmp_pipe, opcode_pipe, 
            raw_madd, raw_rcp, raw_sqrt, raw_log2, raw_exp2, raw_sin, raw_cos, 
            raw_min, raw_max, raw_i2f, raw_f2i, raw_lt, raw_eq)
    begin
        -- 1. Default: Pull from the final stage of the shared pipeline
        result    <= shared_res_pipe(FPU_MAX_LATENCY);
        comp_flag <= shared_cmp_pipe(FPU_MAX_LATENCY);

        -- 2. Boundary Safety Override:
        -- If any IP core's latency perfectly equals FPU_MAX_LATENCY, it bypasses the 
        -- pipeline array entirely to prevent a 1-cycle bug, outputting combinationally.
        -- (The synthesizer will safely optimize away any checks here that evaluate to False).
        
        if LAT_FMADD = FPU_MAX_LATENCY then
            if opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FADD or opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FSUB or 
               opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FMUL or opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FMADD then
                result <= raw_madd;
            end if;
        end if;
        if LAT_FRCP = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FRCP then result <= raw_rcp; end if;
        if LAT_FSQRT = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FSQRT then result <= raw_sqrt; end if;
        if LAT_FLOG2 = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FLOG2 then result <= raw_log2; end if;
        if LAT_FEXP2 = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FEXP2 then result <= raw_exp2; end if;
        if LAT_FSIN = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_SIN then result <= raw_sin; end if;
        if LAT_FCOS = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_COS then result <= raw_cos; end if;
        if LAT_FMIN = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FMIN then result <= raw_min; end if;
        if LAT_FMAX = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FMAX then result <= raw_max; end if;
        if LAT_I2F = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_I2F then result <= raw_i2f; end if;
        if LAT_F2I = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_F2I then result <= raw_f2i; end if;
        if LAT_FCMP_LT = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FCMP_LT then comp_flag <= raw_lt; end if;
        if LAT_FCMP_EQ = FPU_MAX_LATENCY and opcode_pipe(FPU_MAX_LATENCY - 1) = OP_FCMP_EQ then comp_flag <= raw_eq; end if;

    end process;

    -- Align valid_out perfectly with the output result
    valid_out <= valid_pipe(FPU_MAX_LATENCY - 1);

end architecture rtl;
