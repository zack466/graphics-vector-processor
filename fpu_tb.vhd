
------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 Jun 02      Initial revision
--     2025 Jun 13      Testing full pipelined FPU
--
------------------------------------------------------------------------------

-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity FloatAddSub_tb is
end FloatAddSub_tb;

architecture behavioral of FloatAddSub_tb is

    -- Stimulus signals for unit under test
    signal clock        : std_logic;
    signal data_a       : real;
    signal data_b       : real;
    signal add_sub      : std_logic;

    -- Outputs from unit under test
    signal is_nan       : std_logic;
    signal is_overflow  : std_logic;
    signal is_underflow : std_logic;
    signal is_zero      : std_logic;
    signal result       : real;

    -- Test parameters
    constant T : integer := 100;    -- number of test iterations
    constant L : integer := 11;     -- UUT latency

begin

    -- Instantiate UUT
    UUT: entity work.FloatAddSub
    generic map(
        latency => L
    )
    port map(
        clock => clock,
        data_a => data_a,
        data_b => data_b,
        add_sub => add_sub,
        is_nan => is_nan,
        is_overflow => is_overflow,
        is_underflow => is_underflow,
        is_zero => is_zero,
        result => result
    );

    process
        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;

        variable inputs_a : real_vector(0 to T);
        variable inputs_b : real_vector(0 to T);
        variable inputs_add_sub : std_logic_vector(0 to T);

        variable random : rng;

        variable expected_result : real;

    begin
        for i in 0 to T loop
            inputs_a(i) := random.rand_real(-100.0, 100.0);
            inputs_b(i) := random.rand_real(-100.0, 100.0);
            inputs_add_sub(i) := random.rand_sl;
            -- generate a random input
            data_a <= inputs_a(i);
            data_b <= inputs_b(i);
            add_sub <= inputs_add_sub(i);

            Tick; -- Clock in the input and get an output

            -- Check if output matches up with an input that has been clocked L times (which is L-1 indices ago)
            if i >= L then
                if inputs_add_sub(i - L + 1) = '1' then
                    -- Addition
                    expected_result := inputs_a(i - L + 1) + inputs_b(i - L + 1);
                else
                    -- Subtraction
                    expected_result := inputs_a(i - L + 1) - inputs_b(i - L + 1);
                end if;

                assert relatively_equal(result, expected_result, 0.00001)
                report "Expected " & to_string(expected_result) & ", got " & to_string(result)
                severity error;

            end if;
        end loop;

        wait;

    end process;

end behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity FloatMul_tb is
end FloatMul_tb;

architecture behavioral of FloatMul_tb is

    -- Stimulus signals for unit under test
    signal clock        : std_logic;
    signal data_a       : real;
    signal data_b       : real;

    -- Outputs from unit under test
    signal is_nan       : std_logic;
    signal is_overflow  : std_logic;
    signal is_underflow : std_logic;
    signal is_zero      : std_logic;
    signal result       : real;

    -- Test parameters
    constant T : integer := 100;    -- number of test iterations
    constant L : integer := 11;     -- UUT latency

begin

    -- Instantiate UUT
    UUT: entity work.FloatMul
    generic map(
        latency => L
    )
    port map(
        clock => clock,
        data_a => data_a,
        data_b => data_b,
        is_nan => is_nan,
        is_overflow => is_overflow,
        is_underflow => is_underflow,
        is_zero => is_zero,
        result => result
    );

    process
        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;

        variable inputs_a : real_vector(0 to T);
        variable inputs_b : real_vector(0 to T);

        variable random : rng;

        variable expected_result : real;

    begin
        for i in 0 to T loop
            inputs_a(i) := random.rand_real(-100.0, 100.0);
            inputs_b(i) := random.rand_real(-100.0, 100.0);

            -- generate a random input
            data_a <= inputs_a(i);
            data_b <= inputs_b(i);

            Tick; -- Clock in the input and get an output

            -- Check if output matches up with an input that has been clocked L times (which is L-1 indices ago)
            if i >= L then
                expected_result := inputs_a(i - L + 1) * inputs_b(i - L + 1);
                assert relatively_equal(result, expected_result, 0.00001)
                report "Expected " & to_string(expected_result) & ", got " & to_string(result)
                severity error;

            end if;
        end loop;

        wait;

    end process;

end behavioral;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;
use work.fpu_constants.all;

entity FPU_tb is
end FPU_tb;

architecture behavioral of FPU_tb is

    -- Stimulus signals for unit under test
    signal clock        : std_logic;
    signal data_a       : real;
    signal data_b       : real;
    signal operation    : std_logic_vector(3 downto 0);
    signal tag          : std_logic_vector(3 downto 0);

    -- Outputs from unit under test
    signal is_nan       : std_logic;
    signal is_overflow  : std_logic;
    signal is_underflow : std_logic;
    signal is_zero      : std_logic;
    signal is_div_by_zero : std_logic;
    signal result       : real;
    signal tag_out      : std_logic_vector(3 downto 0);

    -- Test parameters
    constant T : integer := 100;    -- number of test iterations per operation

begin

    -- Instantiate UUT
    UUT: entity work.FPU
    port map(
        clock => clock,
        data_a => data_a,
        data_b => data_b,
        operation => operation,
        tag => tag,
        is_nan => is_nan,
        is_overflow => is_overflow,
        is_underflow => is_underflow,
        is_zero => is_zero,
        is_div_by_zero => is_div_by_zero,
        result => result,
        tag_out => tag_out
    );

    process
        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;

        type operation_pipeline_type is array (natural range <>) of std_logic_vector(3 downto 0);

        -- Arrays to store inputs for verification
        variable inputs_a : real_vector(0 to T + MAX_LATENCY);
        variable inputs_b : real_vector(0 to T + MAX_LATENCY);
        variable inputs_op : operation_pipeline_type(0 to T + MAX_LATENCY);
        variable inputs_tag : operation_pipeline_type(0 to T + MAX_LATENCY);

        variable random : rng;
        variable expected_result : real;
        variable current_latency : integer;

        -- Helper function to get latency for an operation
        function get_latency(op : std_logic_vector(3 downto 0)) return integer is
        begin
            case op is
                when OP_ADD | OP_SUB => return LATENCY_ADDSUB;
                when OP_MUL => return LATENCY_MUL;
                when OP_DIV => return LATENCY_DIV;
                when OP_SQRT => return LATENCY_SQRT;
                when OP_EXP => return LATENCY_EXP;
                when OP_INV => return LATENCY_INV;
                when OP_INVSQRT => return LATENCY_INVSQRT;
                when OP_LOG => return LATENCY_LOG;
                when OP_ABS => return LATENCY_ABS;
                when others => return 1;
            end case;
        end function;

        -- Helper function to compute expected result
        function compute_expected(op : std_logic_vector(3 downto 0); a : real; b : real) return real is
        begin
            case op is
                when OP_ADD => return a + b;
                when OP_SUB => return a - b;
                when OP_MUL => return a * b;
                when OP_DIV => return a / b;
                when OP_SQRT => return sqrt(a);
                when OP_EXP => return exp(a);
                when OP_INV => return 1.0 / a;
                when OP_INVSQRT => return 1.0 / sqrt(a);
                when OP_LOG => return log(a);
                when OP_ABS => return abs(a);
                when others => return 0.0;
            end case;
        end function;

        variable op_bits : std_logic_vector(3 downto 0);

    begin

        -- Test each operation type
        for op_type in 0 to 9 loop
            op_bits := std_logic_vector(to_unsigned(op_type, 4));

            -- Convert integer to operation code
            operation <= op_bits;
            current_latency := get_latency(op_bits);

            report "Testing operation " & op_to_string(op_bits) & " with latency " & to_string(current_latency);

            -- Run T iterations for this operation
            for i in 0 to T - 1 loop

                -- Generate appropriate test data based on operation
                inputs_a(i) := random.rand_real(-100.0, 100.0);
                inputs_b(i) := random.rand_real(-100.0, 100.0);

                -- Avoid negative values for these operations
                if op_bits = OP_SQRT or op_bits = OP_INVSQRT or op_bits = OP_LOG then
                    if inputs_a(i) < 0.0 then
                        inputs_a(i) := -inputs_a(i);
                    end if;
                end if;

                -- Avoid division by zero
                if op_bits = OP_INVSQRT or op_bits = OP_INV then
                    if relatively_equal(inputs_a(i), 0.0, 0.00001) then
                        inputs_a(i) := inputs_a(i) + 0.1;
                    end if;
                end if;

                -- Avoid division by zero
                if op_bits = OP_DIV then
                    if relatively_equal(inputs_b(i), 0.0, 0.00001) then
                        inputs_b(i) := inputs_b(i) + 0.1;
                    end if;
                end if;

                inputs_op(i) := op_bits;
                inputs_tag(i) := std_logic_vector(to_unsigned(i mod 16, 4));

                data_a <= inputs_a(i);
                data_b <= inputs_b(i);
                tag <= inputs_tag(i);

                Tick;   -- Clock in inputs

                -- Check if output matches up with an input that has been
                -- clocked L times (which is L-1 indices ago), where L is the
                -- latency of the current operation being tested
                if i >= current_latency then
                    expected_result := compute_expected(
                        inputs_op(i - current_latency + 1),
                        inputs_a(i - current_latency + 1),
                        inputs_b(i - current_latency + 1)
                    );

                    assert relatively_equal(result, expected_result, 0.00001)
                    report "Operation " & op_to_string(op_bits) & 
                           ": Expected " & to_string(expected_result) & 
                           ", got " & to_string(result)
                    severity error;

                    assert tag_out = inputs_tag(i - current_latency + 1)
                    report "Tag mismatch: Expected " & 
                           to_string(inputs_tag(i - current_latency + 1)) &
                           ", got " & to_string(tag_out)
                    severity error;
                end if;

            end loop;
        end loop;

        report "All tests completed successfully!";
        wait;

    end process;

end behavioral;

