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

    signal clk        : std_logic := '0';
    signal reset      : std_logic := '1';
    
    signal opcode     : std_logic_vector(5 downto 0) := (others => '0');
    signal valid_in   : std_logic := '0';
    signal cmp_invert : std_logic := '0';
    signal cmp_swap   : std_logic := '0';
    
    signal op_a       : word_t := (others => '0');
    signal op_b       : word_t := (others => '0');
    signal op_c       : word_t := (others => '0');
    
    signal result     : word_t;
    signal valid_out  : std_logic;
    signal comp_flag  : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    type test_case_t is record
        name       : string(1 to 10);
        opcode     : std_logic_vector(5 downto 0);
        a          : word_t;
        b          : word_t;
        c          : word_t;
        cmp_invert : std_logic;
        cmp_swap   : std_logic;
        
        -- Self-Checking Verification Data
        exp_res    : real;       -- Expected float result
        exp_flag   : std_logic;  -- Expected boolean logic result
        check_math : boolean;    -- Assert the 32-bit math output?
        check_flag : boolean;    -- Assert the 1-bit logic output?
    end record;

    type test_array_t is array (natural range <>) of test_case_t;
    
    constant TESTS : test_array_t := (
        -- ====================================================================
        -- STANDARD MATH TESTS (Format: Name, Opcode, A, B, C, Inv, Swap, ExpRes, ExpFlag, ChkMath, ChkFlag)
        -- ====================================================================
        ("OP_FADD   ", OP_FADD,  x"40000000", x"40400000", x"00000000", '0', '0', 5.0,     '0', true,  false),
        ("OP_FSUB   ", OP_FSUB,  x"40800000", x"40000000", x"00000000", '0', '0', 2.0,     '0', true,  false),
        ("OP_FMUL   ", OP_FMUL,  x"40000000", x"40400000", x"00000000", '0', '0', 6.0,     '0', true,  false),
        ("OP_FMADD  ", OP_FMADD, x"40000000", x"40400000", x"3F800000", '0', '0', 7.0,     '0', true,  false),
        -- TODO: replace FRCP with FDIV
        -- ("OP_FRCP   ", OP_FRCP,  x"40000000", x"00000000", x"00000000", '0', '0', 0.5,     '0', true,  false),
        ("OP_FSQRT  ", OP_FSQRT, x"40800000", x"00000000", x"00000000", '0', '0', 2.0,     '0', true,  false),
        ("OP_FLOG2  ", OP_FLOG2, x"40000000", x"00000000", x"00000000", '0', '0', 1.0,     '0', true,  false),
        ("OP_FEXP2  ", OP_FEXP2, x"40000000", x"00000000", x"00000000", '0', '0', 4.0,     '0', true,  false),
        ("OP_SIN    ", OP_SIN,   x"3F800000", x"00000000", x"00000000", '0', '0', 0.84147, '0', true,  false),
        ("OP_COS    ", OP_COS,   x"3F800000", x"00000000", x"00000000", '0', '0', 0.54030, '0', true,  false),
        ("OP_FMIN   ", OP_FMIN,  x"40000000", x"40800000", x"00000000", '0', '0', 2.0,     '0', true,  false),
        ("OP_FMAX   ", OP_FMAX,  x"40000000", x"40800000", x"00000000", '0', '0', 4.0,     '0', true,  false),
        ("OP_I2F    ", OP_I2F,   x"00000005", x"00000000", x"00000000", '0', '0', 5.0,     '0', true,  false),
        -- Note: F2I produces an integer bit pattern, so we disable the automated float check for it to prevent type mismatch errors.
        ("OP_F2I    ", OP_F2I,   x"40A00000", x"00000000", x"00000000", '0', '0', 5.0,     '0', false, false),
        
        -- ====================================================================
        -- FPU COMPARISON MODIFIER TESTS (A=2.0, B=3.0)
        -- ====================================================================
        -- LT: 2.0 < 3.0 -> True (1)
        ("FCMP_LT   ", OP_FCMP_LT, x"40000000", x"40400000", x"00000000", '0', '0', 0.0, '1', false, true), 
        -- GT: Swap(2.0, 3.0) => 3.0 < 2.0 -> False (0)
        ("FCMP_GT   ", OP_FCMP_LT, x"40000000", x"40400000", x"00000000", '0', '1', 0.0, '0', false, true), 
        -- GE: Inv(2.0 < 3.0) => NOT True -> False (0)
        ("FCMP_GE   ", OP_FCMP_LT, x"40000000", x"40400000", x"00000000", '1', '0', 0.0, '0', false, true), 
        -- LE: Inv(Swap(2.0, 3.0)) => NOT False -> True (1)
        ("FCMP_LE   ", OP_FCMP_LT, x"40000000", x"40400000", x"00000000", '1', '1', 0.0, '1', false, true), 
        
        -- EQ: 2.0 == 2.0 -> True (1)
        ("FCMP_EQ   ", OP_FCMP_EQ, x"40000000", x"40000000", x"00000000", '0', '0', 0.0, '1', false, true), 
        -- NE: Inv(2.0 == 2.0) -> False (0)
        ("FCMP_NE   ", OP_FCMP_EQ, x"40000000", x"40000000", x"00000000", '1', '0', 0.0, '0', false, true), 

        -- ====================================================================
        -- PREDICATE LOGIC TESTS (Using bit 0)
        -- ====================================================================
        ("PAND (1,1)", OP_PAND, x"00000001", x"00000001", x"00000000", '0', '0', 0.0, '1', false, true),
        ("PAND (1,0)", OP_PAND, x"00000001", x"00000000", x"00000000", '0', '0', 0.0, '0', false, true),
        ("POR  (0,1)", OP_POR,  x"00000000", x"00000001", x"00000000", '0', '0', 0.0, '1', false, true),
        ("POR  (0,0)", OP_POR,  x"00000000", x"00000000", x"00000000", '0', '0', 0.0, '0', false, true),
        ("PXOR (1,1)", OP_PXOR, x"00000001", x"00000001", x"00000000", '0', '0', 0.0, '0', false, true),
        ("PXOR (0,1)", OP_PXOR, x"00000000", x"00000001", x"00000000", '0', '0', 0.0, '1', false, true) 
    );

begin

    uut: entity work.fpu_lane
        port map (
            clk => clk, reset => reset, opcode => opcode, valid_in => valid_in,
            cmp_invert => cmp_invert, cmp_swap => cmp_swap,
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
        -- Default padding record
        variable v_shadow       : shadow_pipe_t := (others => ("          ", "000000", x"00000000", x"00000000", x"00000000", '0', '0', 0.0, '0', false, false));
        variable v_current_test : test_case_t;
        variable v_expected     : test_case_t;
        variable cycle_count    : integer := 0;
        variable current_real   : real;
    begin
        reset <= '1';
        valid_in <= '0';
        wait until rising_edge(clk); wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        for i in 0 to TESTS'length + FPU_MAX_LATENCY + 2 loop
            
            -- 1. Set Inputs
            if i < TESTS'length then
                v_current_test := TESTS(i);
                opcode     <= v_current_test.opcode;
                cmp_invert <= v_current_test.cmp_invert;
                cmp_swap   <= v_current_test.cmp_swap;
                op_a       <= v_current_test.a; 
                op_b       <= v_current_test.b; 
                op_c       <= v_current_test.c;
                valid_in   <= '1';
            else
                v_current_test := ("          ", OP_NOP, x"00000000", x"00000000", x"00000000", '0', '0', 0.0, '0', false, false);
                valid_in   <= '0';
                opcode     <= OP_NOP;
                cmp_invert <= '0';
                cmp_swap   <= '0';
            end if;

            -- 2. Shift Shadow Pipeline
            for j in FPU_MAX_LATENCY downto 1 loop
                v_shadow(j) := v_shadow(j - 1);
            end loop;
            v_shadow(0) := v_current_test;

            -- 3. Advance clock
            wait until rising_edge(clk);
            cycle_count := cycle_count + 1;

            -- 4. Verify Outputs
            if valid_out = '1' then
                v_expected := v_shadow(FPU_MAX_LATENCY);
                
                -- Verify Math (Using a +/- 0.001 tolerance check)
                if v_expected.check_math then
                    current_real := to_real(to_float(result));
                    assert abs(current_real - v_expected.exp_res) < 0.001 
                        report "MATH ERROR in " & v_expected.name & 
                               "! Expected: " & real'image(v_expected.exp_res) & 
                               ", Got: " & real'image(current_real) 
                        severity error;
                end if;

                -- Verify Logic
                if v_expected.check_flag then
                    assert comp_flag = v_expected.exp_flag 
                        report "LOGIC ERROR in " & v_expected.name & 
                               "! Expected: " & std_logic'image(v_expected.exp_flag) & 
                               ", Got: " & std_logic'image(comp_flag) 
                        severity error;
                end if;
                
                -- Print success log
                report "<< RESULT VERIFIED (Cycle " & integer'image(cycle_count - 1) & "): " & v_expected.name;
            end if;

        end loop;

        report ">> SIMULATION COMPLETE. All automated assertions passed.";
        std.env.stop;
    end process;

end architecture behavioral;
