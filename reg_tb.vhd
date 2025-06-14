----------------------------------------------------------------------------
--
--  Register Array testbench
--
-- TODO
--
--  Revision History:
--     14 Jun 25  Zack Huang        initial revision
--
----------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity reg_tb is
end reg_tb;

architecture behavioral of reg_tb is
    -- Constants
    constant WORDSIZE : integer := 32;
    constant REGCNT   : integer := 64;

    -- Stimulus signals for unit under test
    signal RegIn      : std_logic_vector(WORDSIZE - 1 downto 0);      -- single register input
    signal RegInSel   : integer range REGCNT - 1 downto 0;            -- which register to write
    signal RegStore   : std_logic;                                     -- write enable for single register
    signal RegASel    : integer range REGCNT - 1 downto 0;            -- register to read on bus A
    signal RegBSel    : integer range REGCNT - 1 downto 0;            -- register to read on bus B
    signal RegQIn     : std_logic_vector(4 * WORDSIZE - 1 downto 0);  -- quad register input
    signal RegQInSel  : integer range REGCNT/4 - 1 downto 0;          -- which quad register to write
    signal RegQStore  : std_logic;                                     -- write enable for quad register
    signal RegQSel    : integer range REGCNT/4 - 1 downto 0;          -- quad register to read on bus Q
    signal clock      : std_logic;                                     -- system clock
    signal reset      : std_logic;                                     -- system reset (async, active low)

    -- Outputs from unit under test
    signal RegA       : std_logic_vector(WORDSIZE - 1 downto 0);      -- register bus A output
    signal RegB       : std_logic_vector(WORDSIZE - 1 downto 0);      -- register bus B output
    signal RegQ       : std_logic_vector(4 * WORDSIZE - 1 downto 0);  -- quad register bus Q output

begin
    -- Instantiate UUT
    UUT: entity work.RegArray
    generic map(
        regcnt   => REGCNT,
        wordsize => WORDSIZE
    )
    port map(
        RegIn      => RegIn,
        RegInSel   => RegInSel,
        RegStore   => RegStore,
        RegASel    => RegASel,
        RegBSel    => RegBSel,
        RegQIn     => RegQIn,
        RegQInSel  => RegQInSel,
        RegQStore  => RegQStore,
        RegQSel    => RegQSel,
        clock      => clock,
        reset      => reset,
        RegA       => RegA,
        RegB       => RegB,
        RegQ       => RegQ
    );

    -- Main test process
    test_proc: process
        -- Clock tick procedure
        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;

        -- Read single registers
        procedure ReadSingle(
            rn : integer range REGCNT - 1 downto 0;
            rm : integer range REGCNT - 1 downto 0
        ) is
        begin
            RegASel <= rn;
            RegBSel <= rm;
            wait for 5 ns;  -- propagation delay
        end procedure;

        -- Write single register
        procedure WriteSingle(
            r    : integer range REGCNT - 1 downto 0;
            data : std_logic_vector(WORDSIZE - 1 downto 0)
        ) is
        begin
            RegInSel <= r;
            RegIn <= data;
            RegStore <= '1';
            Tick;
            RegStore <= '0';
        end procedure;

        -- Read quad register
        procedure ReadQuad(
            q : integer range REGCNT/4 - 1 downto 0
        ) is
        begin
            RegQSel <= q;
            wait for 5 ns;  -- propagation delay
        end procedure;

        -- Write quad register
        procedure WriteQuad(
            q    : integer range REGCNT/4 - 1 downto 0;
            data : std_logic_vector(4 * WORDSIZE - 1 downto 0)
        ) is
        begin
            RegQInSel <= q;
            RegQIn <= data;
            RegQStore <= '1';
            Tick;
            RegQStore <= '0';
        end procedure;

        -- Variables for testing
        variable test_data  : std_logic_vector(WORDSIZE - 1 downto 0);
        variable quad_data  : std_logic_vector(4 * WORDSIZE - 1 downto 0);
        variable expected   : std_logic_vector(WORDSIZE - 1 downto 0);
        variable modified   : std_logic_vector(WORDSIZE - 1 downto 0);

    begin
        -- Initialize control signals
        RegStore <= '0';
        RegQStore <= '0';
        clock <= '0';

        -- Test reset functionality
        reset <= '0';
        Tick;
        reset <= '1';

        -- Verify all registers are zero after reset
        for i in 0 to REGCNT - 1 loop
            ReadSingle(i, 0);
            assert unsigned(RegA) = to_unsigned(0, RegA'length)
                report "Register " & to_string(i) & " not zero after reset"
                severity error;
        end loop;

        -- Test single register writes and reads
        for i in 0 to 15 loop  -- test first 16 registers
            test_data := std_logic_vector(to_unsigned(i * 100 + 55, WORDSIZE));
            WriteSingle(i, test_data);
        end loop;

        -- Verify writes through RegA
        for i in 0 to 15 loop
            expected := std_logic_vector(to_unsigned(i * 100 + 55, WORDSIZE));
            ReadSingle(i, 0);
            assert RegA = expected
                report "Register " & to_string(i) & " read through RegA failed"
                severity error;
        end loop;

        -- Verify writes through RegB
        for i in 0 to 15 loop
            expected := std_logic_vector(to_unsigned(i * 100 + 55, WORDSIZE));
            ReadSingle(0, i);
            assert RegB = expected
                report "Register " & to_string(i) & " read through RegB failed"
                severity error;
        end loop;

        -- Test quad register writes and reads
        for i in 0 to 3 loop  -- test first 4 quad registers (V0-V3)
            quad_data := std_logic_vector(to_unsigned(i * 1000 + 300, WORDSIZE)) &
                        std_logic_vector(to_unsigned(i * 1000 + 200, WORDSIZE)) &
                        std_logic_vector(to_unsigned(i * 1000 + 100, WORDSIZE)) &
                        std_logic_vector(to_unsigned(i * 1000 + 0, WORDSIZE));
            WriteQuad(i, quad_data);
        end loop;

        -- Verify quad writes by reading individual registers
        for i in 0 to 3 loop
            for j in 0 to 3 loop
                expected := std_logic_vector(to_unsigned(i * 1000 + j * 100, WORDSIZE));
                ReadSingle(i * 4 + j, 0);
                assert RegA = expected
                    report "Quad register V" & to_string(i) & " component " & to_string(j) & " failed"
                    severity error;
            end loop;
        end loop;

        -- Verify quad reads
        for i in 0 to 3 loop
            ReadQuad(i);
            expected := std_logic_vector(to_unsigned(i * 1000 + 300, WORDSIZE));
            assert RegQ(4 * WORDSIZE - 1 downto 3 * WORDSIZE) = expected
                report "Quad register V" & to_string(i) & " high word failed"
                severity error;
            expected := std_logic_vector(to_unsigned(i * 1000 + 200, WORDSIZE));
            assert RegQ(3 * WORDSIZE - 1 downto 2 * WORDSIZE) = expected
                report "Quad register V" & to_string(i) & " mid-high word failed"
                severity error;
            expected := std_logic_vector(to_unsigned(i * 1000 + 100, WORDSIZE));
            assert RegQ(2 * WORDSIZE - 1 downto WORDSIZE) = expected
                report "Quad register V" & to_string(i) & " mid-low word failed"
                severity error;
            expected := std_logic_vector(to_unsigned(i * 1000 + 0, WORDSIZE));
            assert RegQ(WORDSIZE - 1 downto 0) = expected
                report "Quad register V" & to_string(i) & " low word failed"
                severity error;
        end loop;

        -- Test 4: Read-modify-write in single clock

        -- Initialize R20 with a known value
        WriteSingle(20, x"00001234");

        -- Read R20, add 1, and write back in single clock
        RegASel <= 20;                                          -- setup read
        wait for 5 ns;                                          -- propagation delay
        modified := std_logic_vector(unsigned(RegA) + 1);      -- modify value
        RegInSel <= 20;                                         -- setup write
        RegIn <= modified;
        RegStore <= '1';
        Tick;                                                   -- single clock performs write
        RegStore <= '0';

        -- Verify the modification
        ReadSingle(20, 0);
        assert RegA = x"00001235"
            report "Read-modify-write failed: expected 0x00001235, got " & to_hstring(RegA)
            severity error;

        -- Test read-modify-write with two register operands
        -- Initialize R30 and R31
        WriteSingle(30, x"00000100");
        WriteSingle(31, x"00000055");

        -- Read R30 and R31, add them, write result to R32 in single clock
        RegASel <= 30;                                          -- setup read A
        RegBSel <= 31;                                          -- setup read B
        wait for 5 ns;                                          -- propagation delay
        modified := std_logic_vector(unsigned(RegA) + unsigned(RegB));  -- add values
        RegInSel <= 32;                                         -- setup write
        RegIn <= modified;
        RegStore <= '1';
        Tick;                                                   -- single clock performs write
        RegStore <= '0';

        -- Verify the result
        ReadSingle(32, 0);
        assert RegA = x"00000155"
            report "Two-operand read-modify-write failed: expected 0x00000155, got " & to_hstring(RegA)
            severity error;

        report "All tests completed successfully!";
        wait;
    end process;

end behavioral;
