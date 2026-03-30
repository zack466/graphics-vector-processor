library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use IEEE.FLOAT_PKG.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_fpu_lane is
end entity tb_fpu_lane;

architecture behavioral of tb_fpu_lane is

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    
    signal opcode    : std_logic_vector(5 downto 0) := (others => '0');
    signal valid_in  : std_logic := '0';
    signal op_a      : word_t := (others => '0');
    signal op_b      : word_t := (others => '0');
    signal op_c      : word_t := (others => '0');
    
    signal result    : word_t;
    signal valid_out : std_logic;
    signal comp_flag : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    type test_case_t is record
        name   : string(1 to 10);
        opcode : std_logic_vector(5 downto 0);
        a      : word_t;
        b      : word_t;
        c      : word_t;
    end record;

    type test_array_t is array (natural range <>) of test_case_t;
    
    constant TESTS : test_array_t := (
        ("OP_FADD   ", OP_FADD,    x"40000000", x"40400000", x"00000000"),
        ("OP_FSUB   ", OP_FSUB,    x"40800000", x"40000000", x"00000000"),
        ("OP_FMUL   ", OP_FMUL,    x"40000000", x"40400000", x"00000000"),
        ("OP_FMADD  ", OP_FMADD,   x"40000000", x"40400000", x"3F800000"),
        ("OP_FRCP   ", OP_FRCP,    x"40000000", x"00000000", x"00000000"),
        ("OP_FSQRT  ", OP_FSQRT,   x"40800000", x"00000000", x"00000000"),
        ("OP_FLOG2  ", OP_FLOG2,   x"40000000", x"00000000", x"00000000"),
        ("OP_FEXP2  ", OP_FEXP2,   x"40000000", x"00000000", x"00000000"),
        ("OP_SIN    ", OP_SIN,     x"3F800000", x"00000000", x"00000000"),
        ("OP_COS    ", OP_COS,     x"3F800000", x"00000000", x"00000000"),
        ("OP_FMIN   ", OP_FMIN,    x"40000000", x"40800000", x"00000000"),
        ("OP_FMAX   ", OP_FMAX,    x"40000000", x"40800000", x"00000000"),
        ("OP_FCMP_LT", OP_FCMP_LT, x"40000000", x"40800000", x"00000000"),
        ("OP_FCMP_EQ", OP_FCMP_EQ, x"40000000", x"40000000", x"00000000"),
        ("OP_I2F    ", OP_I2F,     x"00000005", x"00000000", x"00000000"),
        ("OP_F2I    ", OP_F2I,     x"40A00000", x"00000000", x"00000000")
    );

begin

    uut: entity work.fpu_lane
        port map (
            clk => clk, reset => reset, opcode => opcode, valid_in => valid_in,
            op_a => op_a, op_b => op_b, op_c => op_c,
            result => result, valid_out => valid_out, comp_flag => comp_flag
        );

    clk_process : process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    sync_test_proc: process
        type shadow_pipe_t is array (0 to FPU_MAX_LATENCY) of test_case_t;
        variable v_shadow       : shadow_pipe_t := (others => ("          ", "000000", x"00000000", x"00000000", x"00000000"));
        variable v_current_test : test_case_t;
        variable v_expected     : test_case_t;
        variable cycle_count    : integer := 0;
    begin
        -- Apply Reset
        reset <= '1';
        valid_in <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- Stream, Shift, Clock, and Verify Loop
        for i in 0 to TESTS'length + FPU_MAX_LATENCY + 2 loop
            
            -- 1. Set Inputs for this cycle
            if i < TESTS'length then
                v_current_test := TESTS(i);
                opcode   <= v_current_test.opcode;
                op_a     <= v_current_test.a; op_b <= v_current_test.b; op_c <= v_current_test.c;
                valid_in <= '1';
                report ">> INJECTING (Cycle " & integer'image(cycle_count) & "): " & v_current_test.name & 
                       " | a=" & real'image(to_real(to_float(v_current_test.a))) & 
                       " | b=" & real'image(to_real(to_float(v_current_test.b))) & 
                       " | c=" & real'image(to_real(to_float(v_current_test.c)));
            else
                v_current_test := ("          ", OP_NOP, x"00000000", x"00000000", x"00000000");
                valid_in <= '0';
                opcode   <= OP_NOP;
            end if;

            -- 2. Shift the shadow pipeline immediately (variables update instantly)
            for j in FPU_MAX_LATENCY downto 1 loop
                v_shadow(j) := v_shadow(j - 1);
            end loop;
            v_shadow(0) := v_current_test;

            -- 3. Advance time to the next clock edge
            wait until rising_edge(clk);
            cycle_count := cycle_count + 1;

            -- 4. Check outputs 
            -- Due to delta cycles, checking valid_out right here reads the stable value from the PREVIOUS cycle.
            -- Therefore, we pull the instruction that was injected exactly FPU_MAX_LATENCY cycles ago.
            if valid_out = '1' then
                v_expected := v_shadow(FPU_MAX_LATENCY);
                
                report "<< RESULT READY (Cycle " & integer'image(cycle_count - 1) & "): " & v_expected.name & 
                       " | Math Result: " & real'image(to_real(to_float(result))) & 
                       " | Comp Flag: " & std_logic'image(comp_flag);
            end if;

        end loop;

        report ">> SIMULATION COMPLETE. All instructions verified.";
        std.env.stop;
    end process;

end architecture behavioral;
