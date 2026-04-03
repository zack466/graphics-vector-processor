library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- Testbench for the Register_File entity
entity Register_File_tb is
end entity Register_File_tb;

architecture tb of Register_File_tb is

    -- Constants for the DUT
    constant G_NUM_WARPS        : positive := 4;
    constant G_THREADS_PER_WARP : positive := 8;
    constant G_REGS_PER_THREAD  : positive := 32;
    constant G_DATA_WIDTH       : positive := 32;

    -- Clock constant
    constant C_CLK_PERIOD : time := 10 ns;

    -- Signals to connect to the DUT
    signal s_clk        : std_logic := '0'; -- Testbench clock
    signal s_rst        : std_logic;        -- Testbench reset

    -- Port A Interface signals
    signal s_we_a         : std_logic;
    signal s_re_a         : std_logic;
    signal s_warp_id_a    : natural range 0 to G_NUM_WARPS - 1;
    signal s_thread_id_a  : natural range 0 to G_THREADS_PER_WARP - 1;
    signal s_reg_id_a     : natural range 0 to G_REGS_PER_THREAD - 1;
    signal s_data_a_in    : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    signal s_data_a_out   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    -- Port B Interface signals
    signal s_we_b         : std_logic;
    signal s_re_b         : std_logic;
    signal s_warp_id_b    : natural range 0 to G_NUM_WARPS - 1;
    signal s_thread_id_b  : natural range 0 to G_THREADS_PER_WARP - 1;
    signal s_reg_id_b     : natural range 0 to G_REGS_PER_THREAD - 1;
    signal s_data_b_in    : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    signal s_data_b_out   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    -- Type definition for a single test case
    type t_test_case is record
        -- Port A inputs
        we_a        : std_logic;
        re_a        : std_logic;
        warp_id_a   : natural range 0 to G_NUM_WARPS - 1;
        thread_id_a : natural range 0 to G_THREADS_PER_WARP - 1;
        reg_id_a    : natural range 0 to G_REGS_PER_THREAD - 1;
        data_a_in   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- Port B inputs
        we_b        : std_logic;
        re_b        : std_logic;
        warp_id_b   : natural range 0 to G_NUM_WARPS - 1;
        thread_id_b : natural range 0 to G_THREADS_PER_WARP - 1;
        reg_id_b    : natural range 0 to G_REGS_PER_THREAD - 1;
        data_b_in   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- Verify outputs of test case
        check_a     : boolean;
        expected_a  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        check_b     : boolean;
        expected_b  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    end record t_test_case;

    -- Type definition for an array of test cases
    type t_test_vector is array (natural range <>) of t_test_case;

    -- Address mapping for these tests (Warp:2, Thread:3, Reg:5 bits):
    -- Linear 0x00A (10) -> (W=0, T=0, R=10)
    -- Linear 0x014 (20) -> (W=0, T=0, R=20)
    -- Linear 0x01E (30) -> (W=0, T=0, R=30)
    -- Linear 0x04A (74) -> (W=0, T=2, R=10)
    -- Linear 0x08A (138)-> (W=1, T=0, R=10)
    constant C_TEST_CASES : t_test_vector := (
        -- Test Group 1: Individual Port Access
        ( -- T1.1: Port A Write x"DEADBEEF" to (W=0, T=2, R=10)
            we_a => '1', re_a => '0', warp_id_a => 0, thread_id_a => 2, reg_id_a => 10, data_a_in => x"DEADBEEF",
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 0, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.2: Port A Initiate Read from (W=0, T=2, R=10)
            we_a => '0', re_a => '1', warp_id_a => 0, thread_id_a => 2, reg_id_a => 10, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 0, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.3: Port A Verify Read from (W=0, T=2, R=10)
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 2, reg_id_a => 10, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 0, data_b_in => (others => '0'),
            check_a => true, expected_a => x"DEADBEEF",
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.4: Port B Write x"CAFEF00D" to (W=1, T=0, R=10)
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '1', re_b => '0', warp_id_b => 1, thread_id_b => 0, reg_id_b => 10, data_b_in => x"CAFEF00D",
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.5: Port B Initiate Read from (W=1, T=0, R=10)
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '0', re_b => '1', warp_id_b => 1, thread_id_b => 0, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.6: Port B Verify Read from (W=1, T=0, R=10)
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 1, thread_id_b => 0, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"CAFEF00D"
        ),
        -- Test Group 2: Double Reads
        ( -- T2.1: Initiate Double Read from (W=0,T=2,R=10) and (W=1,T=0,R=10)
            we_a => '0', re_a => '1', warp_id_a => 0, thread_id_a => 2, reg_id_a => 10, data_a_in => (others => '0'),
            we_b => '0', re_b => '1', warp_id_b => 1, thread_id_b => 0, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T2.2: Verify Double Read
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 2, reg_id_a => 10, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 1, thread_id_b => 0, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => true, expected_a => x"DEADBEEF",
            check_b => true, expected_b => x"CAFEF00D"
        ),
        -- Test Group 3: Double Writes
        ( -- T3.1: Double Write to (W=0,T=0,R=30) and (W=0,T=2,R=10)
            we_a => '1', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 30, data_a_in => x"12345678",
            we_b => '1', re_b => '0', warp_id_b => 0, thread_id_b => 2, reg_id_b => 10, data_b_in => x"87654321",
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T3.2: Initiate read to verify Double Write
            we_a => '0', re_a => '1', warp_id_a => 0, thread_id_a => 0, reg_id_a => 30, data_a_in => (others => '0'),
            we_b => '0', re_b => '1', warp_id_b => 0, thread_id_b => 2, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T3.3: Verify Double Write
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 30, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 2, reg_id_b => 10, data_b_in => (others => '0'),
            check_a => true, expected_a => x"12345678",
            check_b => true, expected_b => x"87654321"
        ),
        -- Test Group 4: Read-While-Write Behavior (same address)
        ( -- T4.1: Setup: Write initial data to (W=0,T=0,R=20)
            we_a => '1', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 20, data_a_in => x"DEADBEEF",
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 0, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.2: Port B reads (W=0,T=0,R=20) while Port A writes new data to it
            we_a => '1', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 20, data_a_in => x"CAFEF00D",
            we_b => '0', re_b => '1', warp_id_b => 0, thread_id_b => 0, reg_id_b => 20, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.3: Verify R-while-W: Port B output should be OLD data
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 20, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"DEADBEEF"
        ),
        ( -- T4.4: Port B Initiate Read-After-Write: Read (W=0,T=0,R=20) again
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '0', re_b => '1', warp_id_b => 0, thread_id_b => 0, reg_id_b => 20, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.5: Verify R-A-W: Output should be NEW data
            we_a => '0', re_a => '0', warp_id_a => 0, thread_id_a => 0, reg_id_a => 0, data_a_in => (others => '0'),
            we_b => '0', re_b => '0', warp_id_b => 0, thread_id_b => 0, reg_id_b => 20, data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"CAFEF00D"
        )
    );

    -- Signal to stop the clock at the end of the test
    signal tb_finished : boolean := false;

begin

    -- Instantiate the Device Under Test (DUT)
    i_dut : entity work.Register_File
        generic map (
            G_NUM_WARPS        => G_NUM_WARPS,
            G_THREADS_PER_WARP => G_THREADS_PER_WARP,
            G_REGS_PER_THREAD  => G_REGS_PER_THREAD,
            G_DATA_WIDTH       => G_DATA_WIDTH
        )
        port map (
            i_clk         => s_clk,
            i_rst         => s_rst,
            i_we_a        => s_we_a,
            i_re_a        => s_re_a,
            i_warp_id_a   => s_warp_id_a,
            i_thread_id_a => s_thread_id_a,
            i_reg_id_a    => s_reg_id_a,
            i_data_a      => s_data_a_in,
            o_data_a      => s_data_a_out,
            i_we_b        => s_we_b,
            i_re_b        => s_re_b,
            i_warp_id_b   => s_warp_id_b,
            i_thread_id_b => s_thread_id_b,
            i_reg_id_b    => s_reg_id_b,
            i_data_b      => s_data_b_in,
            o_data_b      => s_data_b_out
        );

    -- Clock generation process
    p_clk_gen : process
    begin
        if not tb_finished then
            s_clk <= '0';
            wait for C_CLK_PERIOD / 2;
            s_clk <= '1';
            wait for C_CLK_PERIOD / 2;
        else
            wait;
        end if;
    end process p_clk_gen;

    -- Test stimulus and verification process
    p_stimulus : process
    begin
        -- Apply reset
        s_rst <= '1';
        wait for C_CLK_PERIOD * 2;
        s_rst <= '0';
        wait for C_CLK_PERIOD;

        report "Starting Register File test sequence...";

        -- Loop through all defined test cases
        for i in C_TEST_CASES'range loop
            -- Apply inputs from the current test case
            s_we_a        <= C_TEST_CASES(i).we_a;
            s_re_a        <= C_TEST_CASES(i).re_a;
            s_warp_id_a   <= C_TEST_CASES(i).warp_id_a;
            s_thread_id_a <= C_TEST_CASES(i).thread_id_a;
            s_reg_id_a    <= C_TEST_CASES(i).reg_id_a;
            s_data_a_in   <= C_TEST_CASES(i).data_a_in;

            s_we_b        <= C_TEST_CASES(i).we_b;
            s_re_b        <= C_TEST_CASES(i).re_b;
            s_warp_id_b   <= C_TEST_CASES(i).warp_id_b;
            s_thread_id_b <= C_TEST_CASES(i).thread_id_b;
            s_reg_id_b    <= C_TEST_CASES(i).reg_id_b;
            s_data_b_in   <= C_TEST_CASES(i).data_b_in;

            -- Wait for one clock cycle for the operation to complete and outputs to update
            wait until rising_edge(s_clk);

            -- Check Port A output if requested by the test case
            if C_TEST_CASES(i).check_a then
                assert s_data_a_out = C_TEST_CASES(i).expected_a
                    report "Assertion failed for test case " & integer'image(i) & "." & LF &
                           "  Port A output mismatch!" & LF &
                           "  Address (W,T,R): (" & integer'image(C_TEST_CASES(i).warp_id_a) & "," &
                                                    integer'image(C_TEST_CASES(i).thread_id_a) & "," &
                                                    integer'image(C_TEST_CASES(i).reg_id_a) & ")" & LF &
                           "  Expected: " & to_hstring(C_TEST_CASES(i).expected_a) & LF &
                           "  Actual:   " & to_hstring(s_data_a_out)
                    severity error;
            end if;

            -- Check Port B output if requested by the test case
            if C_TEST_CASES(i).check_b then
                assert s_data_b_out = C_TEST_CASES(i).expected_b
                    report "Assertion failed for test case " & integer'image(i) & "." & LF &
                           "  Port B output mismatch!" & LF &
                           "  Address (W,T,R): (" & integer'image(C_TEST_CASES(i).warp_id_b) & "," &
                                                    integer'image(C_TEST_CASES(i).thread_id_b) & "," &
                                                    integer'image(C_TEST_CASES(i).reg_id_b) & ")" & LF &
                           "  Expected: " & to_hstring(C_TEST_CASES(i).expected_b) & LF &
                           "  Actual:   " & to_hstring(s_data_b_out)
                    severity error;
            end if;
        end loop;

        -- End of tests
        report "All tests completed.";
        tb_finished <= true;
        wait; -- Stop simulation
    end process p_stimulus;

end architecture tb;
