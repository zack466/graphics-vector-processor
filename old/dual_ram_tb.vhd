------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 Sep 24      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- Testbench for the Ram_Dual_Port entity
entity Ram_Dual_Port_tb is
end entity Ram_Dual_Port_tb;

architecture tb of Ram_Dual_Port_tb is

    -- Constants for the DUT
    constant G_DATA_WIDTH : natural := 32;
    constant G_ADDR_WIDTH : natural := 10;

    -- Clock constant
    constant C_CLK_PERIOD : time := 10 ns;

    -- Signals to connect to the DUT
    signal s_clk        : std_logic := '0';                                 -- Testbench clock
    signal s_rst        : std_logic;                                        -- Testbench reset

    -- Port A Interface signals
    signal s_we_a       : std_logic;                                        -- Write enable for Port A
    signal s_re_a       : std_logic;                                        -- Read enable for Port A
    signal s_addr_a     : std_logic_vector(G_ADDR_WIDTH - 1 downto 0);      -- Address for Port A
    signal s_data_a_in  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);      -- Data input for Port A
    signal s_data_a_out : std_logic_vector(G_DATA_WIDTH - 1 downto 0);      -- Data output from Port A

    -- Port B Interface signals
    signal s_we_b       : std_logic;                                        -- Write enable for Port B
    signal s_re_b       : std_logic;                                        -- Read enable for Port B
    signal s_addr_b     : std_logic_vector(G_ADDR_WIDTH - 1 downto 0);      -- Address for Port B
    signal s_data_b_in  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);      -- Data input for Port B
    signal s_data_b_out : std_logic_vector(G_DATA_WIDTH - 1 downto 0);      -- Data output from Port B

    -- Type definition for a single test case
    type t_test_case is record
        -- Port A inputs
        we_a        : std_logic;
        re_a        : std_logic;
        addr_a      : std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
        data_a_in   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- Port B inputs
        we_b        : std_logic;
        re_b        : std_logic;
        addr_b      : std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
        data_b_in   : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        -- Verify outputs of test case
        check_a     : boolean;
        expected_a  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
        check_b     : boolean;
        expected_b  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    end record t_test_case;

    -- Type definition for an array of test cases
    type t_test_vector is array (natural range <>) of t_test_case;

    -- Array of test cases
    constant C_TEST_CASES : t_test_vector := (
        -- Test Group 1: Individual Port Access
        ( -- T1.1: Port A Write x"DEADBEEF" to address 0xA
            we_a => '1', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => x"DEADBEEF",
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.2: Port A Initiate Read from address 0xA
            we_a => '0', re_a => '1', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.3: Port A Verify Read from address 0xA (data is now at output)
            we_a => '0', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => true, expected_a => x"DEADBEEF",
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.4: Port B Write x"CAFEF00D" to address 0x14
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '1', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_b_in => x"CAFEF00D",
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.5: Port B Initiate Read from address 0x14
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '0', re_b => '1', addr_b => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T1.6: Port B Verify Read from address 0x14
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"CAFEF00D"
        ),
        -- Test Group 2: Double Reads
        ( -- T2.1: Initiate Double Read from 0xA (Port A) and 0x14 (Port B)
            we_a => '0', re_a => '1', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '1', addr_b => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T2.2: Verify Double Read
            we_a => '0', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => true, expected_a => x"DEADBEEF",
            check_b => true, expected_b => x"CAFEF00D"
        ),
        -- Test Group 3: Double Writes
        ( -- T3.1: Double Write to 0x1E (Port A) and 0xA (Port B)
            we_a => '1', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#01E#, G_ADDR_WIDTH)), data_a_in => x"12345678",
            we_b => '1', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => x"87654321",
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T3.2: Initiate read to verify Double Write
            we_a => '0', re_a => '1', addr_a => std_logic_vector(to_unsigned(16#01E#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '1', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T3.3: Verify Double Write
            we_a => '0', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#01E#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => true, expected_a => x"12345678",
            check_b => true, expected_b => x"87654321"
        ),
        -- Test Group 4: Read-Before-Write Behavior
        ( -- T4.1: Setup for Port A R-B-W: Write initial data to 0x14
            we_a => '1', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_a_in => x"DEADBEEF",
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.2: Port A Read-Before-Write: Read 0x14 while writing new data
            we_a => '1', re_a => '1', addr_a => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_a_in => x"CAFEF00D",
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.3: Verify Port A R-B-W: Output should be OLD data
            we_a => '0', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => true, expected_a => x"DEADBEEF",
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.4: Port A Initiate Read-After-Write: Read 0x14 again
            we_a => '0', re_a => '1', addr_a => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.5: Verify Port A R-A-W: Output should be NEW data
            we_a => '0', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#014#, G_ADDR_WIDTH)), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => true, expected_a => x"CAFEF00D",
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.6: Setup for A->B R-while-W: Write initial data to 0xA
            we_a => '1', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => x"12345678",
            we_b => '0', re_b => '0', addr_b => (others => '0'), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.7: Port B reads 0xA while Port A writes new data to it
            we_a => '1', re_a => '0', addr_a => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_a_in => x"87654321",
            we_b => '0', re_b => '1', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.8: Verify A->B R-while-W: Port B output should be OLD data
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"12345678"
        ),
        ( -- T4.9: Port B Initiate Read-After-Write: Read 0xA again
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '0', re_b => '1', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => false, expected_b => (others => '0')
        ),
        ( -- T4.10: Verify Port B R-A-W: Output should be NEW data
            we_a => '0', re_a => '0', addr_a => (others => '0'), data_a_in => (others => '0'),
            we_b => '0', re_b => '0', addr_b => std_logic_vector(to_unsigned(16#00A#, G_ADDR_WIDTH)), data_b_in => (others => '0'),
            check_a => false, expected_a => (others => '0'),
            check_b => true, expected_b => x"87654321"
        )
    );

    -- Signal to stop the clock at the end of the test
    signal tb_finished : boolean := false;

begin

    -- Instantiate the Device Under Test (DUT)
    i_dut : entity work.Ram_Dual_Port
        generic map (
            G_DATA_WIDTH => G_DATA_WIDTH,
            G_ADDR_WIDTH => G_ADDR_WIDTH
        )
        port map (
            i_clk    => s_clk,
            i_rst    => s_rst,
            i_we_a   => s_we_a,
            i_re_a   => s_re_a,
            i_addr_a => s_addr_a,
            i_data_a => s_data_a_in,
            o_data_a => s_data_a_out,
            i_we_b   => s_we_b,
            i_re_b   => s_re_b,
            i_addr_b => s_addr_b,
            i_data_b => s_data_b_in,
            o_data_b => s_data_b_out
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

        report "Starting test sequence...";

        -- Loop through all defined test cases
        for i in C_TEST_CASES'range loop
            -- Apply inputs from the current test case
            s_we_a      <= C_TEST_CASES(i).we_a;
            s_re_a      <= C_TEST_CASES(i).re_a;
            s_addr_a    <= C_TEST_CASES(i).addr_a;
            s_data_a_in <= C_TEST_CASES(i).data_a_in;
            s_we_b      <= C_TEST_CASES(i).we_b;
            s_re_b      <= C_TEST_CASES(i).re_b;
            s_addr_b    <= C_TEST_CASES(i).addr_b;
            s_data_b_in <= C_TEST_CASES(i).data_b_in;

            -- Wait for one clock cycle for the operation to complete and outputs to update
            wait until rising_edge(s_clk);

            -- Check Port A output if requested by the test case
            if C_TEST_CASES(i).check_a then
                assert s_data_a_out = C_TEST_CASES(i).expected_a
                    report "Assertion failed for test case " & integer'image(i) & "." & LF &
                           "  Port A output mismatch!" & LF &
                           "  Expected: " & to_hstring(C_TEST_CASES(i).expected_a) & LF &
                           "  Actual:   " & to_hstring(s_data_a_out)
                    severity error;
            end if;

            -- Check Port B output if requested by the test case
            if C_TEST_CASES(i).check_b then
                assert s_data_b_out = C_TEST_CASES(i).expected_b
                    report "Assertion failed for test case " & integer'image(i) & "." & LF &
                           "  Port B output mismatch!" & LF &
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
