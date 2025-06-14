------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 Jun 02      Initial revision
--     2025 Jun 13      Added all float operations, general purpose FPU
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package fpu_constants is
    -- Operation constants
    constant OP_ADD     : std_logic_vector(3 downto 0) := "0000";
    constant OP_SUB     : std_logic_vector(3 downto 0) := "0001";
    constant OP_MUL     : std_logic_vector(3 downto 0) := "0010";
    constant OP_DIV     : std_logic_vector(3 downto 0) := "0011";
    constant OP_SQRT    : std_logic_vector(3 downto 0) := "0100";
    constant OP_EXP     : std_logic_vector(3 downto 0) := "0101";
    constant OP_INV     : std_logic_vector(3 downto 0) := "0110";
    constant OP_INVSQRT : std_logic_vector(3 downto 0) := "0111";
    constant OP_LOG     : std_logic_vector(3 downto 0) := "1000";
    constant OP_ABS     : std_logic_vector(3 downto 0) := "1001";
    
    function op_to_string(op : std_logic_vector) return string;

    -- Latency constants for each operation
    constant LATENCY_ADDSUB  : integer := 11;
    constant LATENCY_MUL     : integer := 5;
    constant LATENCY_DIV     : integer := 33;
    constant LATENCY_SQRT    : integer := 28;
    constant LATENCY_EXP     : integer := 17;
    constant LATENCY_INV     : integer := 20;
    constant LATENCY_INVSQRT : integer := 26;
    constant LATENCY_LOG     : integer := 21;
    constant LATENCY_ABS     : integer := 1;

    -- Maximum latency for pipeline depth
    constant MAX_LATENCY : integer := 33;
end package fpu_constants;

package body fpu_constants is
    function op_to_string(op : std_logic_vector) return string is
    begin
        case op is
            when OP_ADD => return "ADD";
            when OP_SUB => return "SUB";
            when OP_MUL => return "MUL";
            when OP_DIV => return "DIV";
            when OP_SQRT => return "SQRT";
            when OP_EXP => return "EXP";
            when OP_INV => return "INV";
            when OP_INVSQRT => return "INVSQRT";
            when OP_LOG => return "LOG";
            when OP_ABS => return "ABS";
            when others => return "UNKNOWN";
        end case;
    end function;
end package body;


library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

-- A generic pipeline entity that will delay a signal for a certain number of
-- clocks. This is used to simulate Altera floating-point IPs that take
-- multiple clocks to produce a result. As an example, suppose the latency is
-- set to 3 clocks. If data_in is set to 0.1 during the rising edge of clock 0,
-- then it will be ready as output after the rising edge of clock 2, which is
-- three total clocks.
entity Pipeline is
    generic (
        latency : integer := 1
    );
    port(
        clock   : in std_logic;
        data_in : in real;
        data_out: out real
    );
end Pipeline;


architecture dataflow of Pipeline is

    signal pipe : real_vector(0 to latency - 1);
    
begin
    -- latch in input data
    pipeline_input: process(clock)
    begin
        if rising_edge(clock) then
            pipe(0) <= data_in;
        end if;
    end process;
    
    -- Move each item forward in the pipeline on a clock
    pipeline_iter: for i in 1 to latency - 1 generate
        process(clock)
        begin
            if rising_edge(clock) then
                pipe(i) <= pipe(i - 1);
            end if;
        end process ;
    end generate pipeline_iter;

    -- Output result in pipeline after latency clocks
    data_out <= pipe(latency - 1);
    
end architecture dataflow;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of addition/subtraction.
-- Takes a generic latency parameter.
entity FloatAddSub is
    generic (
        latency : integer range 7 to 14 := 11             -- allowed values: 7 through 14
    );
    port(
        -- Inputs
        data_a          : in real;          -- First operand
        data_b          : in real;          -- Second operand
        add_sub         : in std_logic;     -- whether to do addition or subtraction
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        result          : out real          -- result of addition/subtraction
    );
end FloatAddSub;

architecture behavioral of FloatAddSub is

    signal sum : real;
    
begin

    compute: process(clock)
    begin
        if rising_edge(clock) then
            if add_sub = '1' then
                sum <= data_a + data_b;
            else
                sum <= data_a - data_b;
            end if;
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => sum, data_out => result);
    
end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of multiplication.
-- Takes a generic latency parameter.
entity FloatMul is
    generic (
        latency : integer range 5 to 11 := 5            -- allowed values: 5, 6, 10, 11
    );
    port(
        -- Inputs
        data_a          : in real;          -- First operand
        data_b          : in real;          -- Second operand
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        result          : out real          -- result of multiplication
    );
end FloatMul;

architecture behavioral of FloatMul is

    signal prod : real;
    
begin

    process(clock)
    begin
        if rising_edge(clock) then
            prod <= data_a * data_b;
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => prod, data_out => result);
    
end architecture behavioral;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of division.
-- Takes a generic latency parameter.
entity FloatDiv is
    generic (
        latency : integer := 33                          -- allowed values: 6, 14, 33 (single precision)
    );
    port(
        -- Inputs
        data_a          : in real;          -- Numerator
        data_b          : in real;          -- Denominator
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        is_div_by_zero  : out std_logic;    -- division by zero
        result          : out real          -- result of division
    );
end FloatDiv;

architecture behavioral of FloatDiv is

    signal quotient : real;

begin

    -- Compute and register the quotient
    compute: process(clock)
    begin
        if rising_edge(clock) then
            quotient <= data_a / data_b;
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => quotient, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of square root.
-- Takes a generic latency parameter.
entity FloatSqrt is
    generic (
        latency : integer := 28                          -- allowed values: 16, 28 (single precision)
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_zero         : out std_logic;    -- result is zero
        result          : out real          -- square root result
    );
end FloatSqrt;

architecture behavioral of FloatSqrt is

    signal sqrt_val : real;

begin

    -- Compute and register the square root
    compute: process(clock)
    begin
        if rising_edge(clock) then
            sqrt_val <= sqrt(data);
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => sqrt_val, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of exponential.
-- Takes a generic latency parameter.
entity FloatExp is
    generic (
        latency : integer := 17                          -- fixed at 17 for single precision
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        result          : out real          -- exponential result
    );
end FloatExp;

architecture behavioral of FloatExp is

    signal exp_val : real;

begin

    -- Compute and register the exponential
    compute: process(clock)
    begin
        if rising_edge(clock) then
            exp_val <= exp(data);
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => exp_val, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of inverse (1/x).
-- Takes a generic latency parameter.
entity FloatInv is
    generic (
        latency : integer := 20                          -- fixed at 20 for single precision
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        is_div_by_zero  : out std_logic;    -- division by zero
        result          : out real          -- inverse result
    );
end FloatInv;

architecture behavioral of FloatInv is

    signal inv_val : real;

begin

    -- Compute and register the inverse
    compute: process(clock)
    begin
        if rising_edge(clock) then
            -- Ignore div by 0 errors for now
            if data /= 0.0 then
                inv_val <= 1.0 / data;
            else
                inv_val <= 0.0;
            end if;
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => inv_val, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of inverse square root.
-- Takes a generic latency parameter.
entity FloatInvSqrt is
    generic (
        latency : integer := 26                          -- fixed at 26 for single precision
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_zero         : out std_logic;    -- result is zero
        is_div_by_zero  : out std_logic;    -- division by zero
        result          : out real          -- inverse square root result
    );
end FloatInvSqrt;

architecture behavioral of FloatInvSqrt is

    signal inv_sqrt_val : real;

begin

    -- Compute and register the inverse square root
    compute: process(clock)
    begin
        if rising_edge(clock) then
            -- Ignore div by 0 errors for now
            if data > 0.0 then
                inv_sqrt_val <= 1.0 / sqrt(data);
            else
                inv_sqrt_val <= 0.0;
            end if;
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => inv_sqrt_val, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of natural logarithm.
-- Takes a generic latency parameter.
entity FloatLog is
    generic (
        latency : integer := 21                          -- fixed at 21 for single precision
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_zero         : out std_logic;    -- result is zero
        result          : out real          -- natural logarithm result
    );
end FloatLog;

architecture behavioral of FloatLog is

    signal log_val : real;

begin

    -- Compute and register the natural logarithm
    compute: process(clock)
    begin
        if rising_edge(clock) then
            log_val <= log(data);
        end if;
    end process;

    -- Pipeline the result
    pipeline_inst: entity work.Pipeline
    generic map(latency => latency - 1)
    port map(clock => clock, data_in => log_val, data_out => result);

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of absolute value.
-- Takes a generic latency parameter.
entity FloatAbs is
    generic (
        latency : integer range 0 to 1 := 1              -- allowed values: 0, 1
    );
    port(
        -- Inputs
        data            : in real;          -- Input value
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        is_div_by_zero  : out std_logic;    -- division by zero (pass-through)
        result          : out real          -- absolute value result
    );
end FloatAbs;

architecture behavioral of FloatAbs is

    signal abs_val : real;

begin

    -- Generate architecture based on latency
    gen_latency: if latency = 0 generate
        -- Combinatorial output
        result <= abs(data);
    else generate
        -- Registered output
        compute: process(clock)
        begin
            if rising_edge(clock) then
                abs_val <= abs(data);
            end if;
        end process;

        result <= abs_val;
    end generate gen_latency;

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- Simulates the Altera Floating Point IP implementation of comparison.
-- Takes a generic latency parameter.
entity FloatCompare is
    generic (
        latency : integer range 1 to 3 := 3              -- allowed values: 1, 2, 3
    );
    port(
        -- Inputs
        data_a          : in real;          -- First operand
        data_b          : in real;          -- Second operand
        clock           : in std_logic;     -- system clock

        -- Outputs
        aeb             : out std_logic;    -- A equals B
        aneb            : out std_logic;    -- A not equals B
        agb             : out std_logic;    -- A greater than B
        ageb            : out std_logic;    -- A greater than or equal to B
        alb             : out std_logic;    -- A less than B
        aleb            : out std_logic;    -- A less than or equal to B
        unordered       : out std_logic     -- One or both inputs are NaN
    );
end FloatCompare;

architecture behavioral of FloatCompare is

    type compare_record is record
        aeb  : std_logic;
        aneb : std_logic;
        agb  : std_logic;
        ageb : std_logic;
        alb  : std_logic;
        aleb : std_logic;
    end record;

    signal compare_result : compare_record;
    signal pipe : compare_record;

begin

    -- Compute comparisons
    compute: process(clock)
    begin
        if rising_edge(clock) then
            if data_a = data_b then
                compare_result.aeb <= '1';
            else
                compare_result.aeb <= '0';
            end if;

            if data_a /= data_b then
                compare_result.aneb <= '1';
            else
                compare_result.aneb <= '0';
            end if;

            if data_a > data_b then
                compare_result.agb <= '1';
            else
                compare_result.agb <= '0';
            end if;

            if data_a >= data_b then
                compare_result.ageb <= '1';
            else
                compare_result.ageb <= '0';
            end if;

            if data_a < data_b then
                compare_result.alb <= '1';
            else
                compare_result.alb <= '0';
            end if;

            if data_a <= data_b then
                compare_result.aleb <= '1';
            else
                compare_result.aleb <= '0';
            end if;
        end if;
    end process;

    -- Pipeline stages
    gen_pipeline: if latency > 1 generate
        pipeline_regs: process(clock)
        begin
            if rising_edge(clock) then
                pipe <= compare_result;
            end if;
        end process;
    end generate;

    -- Output assignment based on latency
    gen_output_1: if latency = 1 generate
        aeb  <= compare_result.aeb;
        aneb <= compare_result.aneb;
        agb  <= compare_result.agb;
        ageb <= compare_result.ageb;
        alb  <= compare_result.alb;
        aleb <= compare_result.aleb;
    end generate;

    gen_output_2_3: if latency > 1 generate
        aeb  <= pipe.aeb;
        aneb <= pipe.aneb;
        agb  <= pipe.agb;
        ageb <= pipe.ageb;
        alb  <= pipe.alb;
        aleb <= pipe.aleb;
    end generate;

    -- For simulation, we'll set unordered to '0' (no NaN handling with real type)
    unordered <= '0';

end architecture behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;
use work.fpu_constants.all;

entity FPU is
    port(
        -- Inputs
        data_a          : in real;          -- First operand (used for single-operand instructions)
        data_b          : in real;          -- Second operand
        operation       : in std_logic_vector(3 downto 0);      -- which operation to perform
        tag             : in std_logic_vector(3 downto 0);      -- metadata associated with the operation
        clock           : in std_logic;     -- system clock

        -- Outputs
        is_nan          : out std_logic;    -- result is NaN
        is_overflow     : out std_logic;    -- result overflowed
        is_underflow    : out std_logic;    -- result underflowed
        is_zero         : out std_logic;    -- result is zero
        is_div_by_zero  : out std_logic;    -- division by zero error
        result          : out real;         -- result of performing the operation
        tag_out         : out std_logic_vector(3 downto 0)      -- metadata associated with the instruction that just finished executing
    );

end FPU;

architecture behavioral of FPU is

    -- Pipeline for operation and tag bits
    type operation_pipeline_type is array (0 to MAX_LATENCY - 1) of std_logic_vector(3 downto 0);
    signal operation_pipe : operation_pipeline_type;
    signal tag_pipe : operation_pipeline_type;

    -- Signals for add/sub control
    signal add_sub_control : std_logic;

    -- Results from each floating point unit
    signal result_addsub  : real;
    signal result_mul     : real;
    signal result_div     : real;
    signal result_sqrt    : real;
    signal result_exp     : real;
    signal result_inv     : real;
    signal result_invsqrt : real;
    signal result_log     : real;
    signal result_abs     : real;

begin

    -- Decode add/sub control signal
    add_sub_control <= '1' when operation = OP_ADD else '0';

    -- Instantiate floating point units
    addsub_inst: entity work.FloatAddSub
    generic map(latency => LATENCY_ADDSUB)
    port map(
        data_a => data_a,
        data_b => data_b,
        add_sub => add_sub_control,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_underflow => open,
        is_zero => open,
        result => result_addsub
    );

    mul_inst: entity work.FloatMul
    generic map(latency => LATENCY_MUL)
    port map(
        data_a => data_a,
        data_b => data_b,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_underflow => open,
        is_zero => open,
        result => result_mul
    );

    div_inst: entity work.FloatDiv
    generic map(latency => LATENCY_DIV)
    port map(
        data_a => data_a,
        data_b => data_b,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_underflow => open,
        is_zero => open,
        is_div_by_zero => open,
        result => result_div
    );

    sqrt_inst: entity work.FloatSqrt
    generic map(latency => LATENCY_SQRT)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_zero => open,
        result => result_sqrt
    );

    exp_inst: entity work.FloatExp
    generic map(latency => LATENCY_EXP)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_underflow => open,
        is_zero => open,
        result => result_exp
    );

    inv_inst: entity work.FloatInv
    generic map(latency => LATENCY_INV)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_underflow => open,
        is_zero => open,
        is_div_by_zero => open,
        result => result_inv
    );

    invsqrt_inst: entity work.FloatInvSqrt
    generic map(latency => LATENCY_INVSQRT)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_zero => open,
        is_div_by_zero => open,
        result => result_invsqrt
    );

    log_inst: entity work.FloatLog
    generic map(latency => LATENCY_LOG)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_zero => open,
        result => result_log
    );

    abs_inst: entity work.FloatAbs
    generic map(latency => LATENCY_ABS)
    port map(
        data => data_a,
        clock => clock,
        is_nan => open,
        is_overflow => open,
        is_underflow => open,
        is_zero => open,
        is_div_by_zero => open,
        result => result_abs
    );

    -- Pipeline for operation and tag bits
    pipeline_control: process(clock)
    begin
        if rising_edge(clock) then
            -- Shift pipeline towards index 0
            for i in 0 to MAX_LATENCY - 2 loop
                operation_pipe(i) <= operation_pipe(i + 1);
                tag_pipe(i) <= tag_pipe(i + 1);
            end loop;

            -- Clear the last stage (will be overwritten if needed)
            operation_pipe(MAX_LATENCY - 1) <= (others => '0');
            tag_pipe(MAX_LATENCY - 1) <= (others => '0');

            -- Insert new operation at the appropriate pipeline stage based on latency
            case operation is
                when OP_ADD | OP_SUB =>
                    operation_pipe(LATENCY_ADDSUB - 1) <= operation;
                    tag_pipe(LATENCY_ADDSUB - 1) <= tag;
                when OP_MUL =>
                    operation_pipe(LATENCY_MUL - 1) <= operation;
                    tag_pipe(LATENCY_MUL - 1) <= tag;
                when OP_DIV =>
                    operation_pipe(LATENCY_DIV - 1) <= operation;
                    tag_pipe(LATENCY_DIV - 1) <= tag;
                when OP_SQRT =>
                    operation_pipe(LATENCY_SQRT - 1) <= operation;
                    tag_pipe(LATENCY_SQRT - 1) <= tag;
                when OP_EXP =>
                    operation_pipe(LATENCY_EXP - 1) <= operation;
                    tag_pipe(LATENCY_EXP - 1) <= tag;
                when OP_INV =>
                    operation_pipe(LATENCY_INV - 1) <= operation;
                    tag_pipe(LATENCY_INV - 1) <= tag;
                when OP_INVSQRT =>
                    operation_pipe(LATENCY_INVSQRT - 1) <= operation;
                    tag_pipe(LATENCY_INVSQRT - 1) <= tag;
                when OP_LOG =>
                    operation_pipe(LATENCY_LOG - 1) <= operation;
                    tag_pipe(LATENCY_LOG - 1) <= tag;
                when OP_ABS =>
                    operation_pipe(LATENCY_ABS - 1) <= operation;
                    tag_pipe(LATENCY_ABS - 1) <= tag;
                when others =>
                    null;
            end case;
        end if;
    end process;

    -- Output multiplexer
    output_mux: process(operation_pipe, result_addsub, result_mul, 
                       result_div, result_sqrt, result_exp, result_inv, 
                       result_invsqrt, result_log, result_abs)
    begin
        case operation_pipe(0) is
            when OP_ADD | OP_SUB =>
                result <= result_addsub;
            when OP_MUL =>
                result <= result_mul;
            when OP_DIV =>
                result <= result_div;
            when OP_SQRT =>
                result <= result_sqrt;
            when OP_EXP =>
                result <= result_exp;
            when OP_INV =>
                result <= result_inv;
            when OP_INVSQRT =>
                result <= result_invsqrt;
            when OP_LOG =>
                result <= result_log;
            when OP_ABS =>
                result <= result_abs;
            when others =>
                result <= 0.0;
        end case;
    end process;

    -- Output tag from pipeline
    tag_out <= tag_pipe(0);

    -- For now, set status flags to '0' (would need proper implementation)
    is_nan <= '0';
    is_overflow <= '0';
    is_underflow <= '0';
    is_zero <= '0';
    is_div_by_zero <= '0';

end architecture behavioral;

