------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     25 May 14    Zack Huang      Initial Revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.types.all;
use work.util.all;

entity core_tb is
end core_tb;

architecture behavioral of core_tb is

    -- Constants for testbench configuration
    constant ADDR_WIDTH     : integer := 32;
    constant DATA_WIDTH     : integer := 32;
    constant MEM_ADDR_WIDTH : integer := 8; -- Must match agent's generic
    constant CLK_PERIOD     : time    := 10 ns;

    -- Signals to connect to the UUT (Core)
    signal clock_s       : std_logic := '0';
    signal reset_s       : std_logic;
    signal trigger_s     : std_logic;
    signal instruction_out_s : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- Signals for the Avalon Host user interface (from Core)
    signal usr_request_valid_s    : std_logic;
    signal usr_request_ready_s    : std_logic;
    signal usr_request_is_write_s : std_logic;
    signal usr_request_address_s  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal usr_writedata_s        : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_byteenable_s       : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
    signal usr_readdata_s         : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_readdata_valid_s   : std_logic;

    -- Signals for the Avalon Master interface (from Host)
    signal avm_address_s        : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal avm_read_s           : std_logic;
    signal avm_write_s          : std_logic;
    signal avm_writedata_s      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avm_byteenable_s     : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);

    -- Signals for the Avalon Slave interface (to Agent)
    signal avs_address_s        : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal avs_read_s           : std_logic;
    signal avs_write_s          : std_logic;
    signal avs_writedata_s      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avs_readdata_s       : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avs_readdata_valid_s : std_logic;
    signal avs_waitrequest_s    : std_logic;

    -- Control signal to select bus master (TB or CPU Host)
    signal tb_is_writing_mem_s : std_logic := '0';

    -- Signals for TB to drive the bus during memory init
    signal tb_avs_address_s  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal tb_avs_writedata_s: std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal tb_avs_write_s    : std_logic;

    -- Signal to stop the clock at the end of the test
    signal tb_finished : boolean := false;

begin

    -- Instantiate UUT (Core)
    UUT: entity work.Core
    generic map (
        ADDR_WIDTH => ADDR_WIDTH,
        DATA_WIDTH => DATA_WIDTH
    )
    port map (
        clock                => clock_s,
        reset                => reset_s,
        trigger              => trigger_s,
        usr_request_valid    => usr_request_valid_s,
        usr_request_ready    => usr_request_ready_s,
        usr_request_is_write => usr_request_is_write_s,
        usr_request_address  => usr_request_address_s,
        usr_writedata        => usr_writedata_s,
        usr_byteenable       => usr_byteenable_s,
        usr_readdata         => usr_readdata_s,
        usr_readdata_valid   => usr_readdata_valid_s,
        instruction_out      => instruction_out_s
    );

    -- Instantiate Avalon Host (Memory Controller)
    HOST: entity work.sdram_avalon_host
    generic map (
        DATA_WIDTH => DATA_WIDTH,
        ADDR_WIDTH => ADDR_WIDTH
    )
    port map (
        clk                  => clock_s,
        reset                => reset_s,
        usr_request_valid    => usr_request_valid_s,
        usr_request_ready    => usr_request_ready_s,
        usr_request_is_write => usr_request_is_write_s,
        usr_request_address  => usr_request_address_s,
        usr_writedata        => usr_writedata_s,
        usr_byteenable       => usr_byteenable_s,
        usr_readdata         => usr_readdata_s,
        usr_readdata_valid   => usr_readdata_valid_s,
        avm_address          => avm_address_s,
        avm_read             => avm_read_s,
        avm_write            => avm_write_s,
        avm_waitrequest      => avs_waitrequest_s, -- Connect directly to slave's waitrequest
        avm_writedata        => avm_writedata_s,
        avm_byteenable       => avm_byteenable_s,
        avm_readdata         => avs_readdata_s,    -- Connect directly to slave's readdata
        avm_readdata_valid   => avs_readdata_valid_s -- Connect directly to slave's readdata_valid
    );

    -- Bus MUX: Select between Testbench and CPU Host to drive the memory agent
    avs_address_s   <= tb_avs_address_s  when tb_is_writing_mem_s = '1' else avm_address_s;
    avs_writedata_s <= tb_avs_writedata_s when tb_is_writing_mem_s = '1' else avm_writedata_s;
    avs_write_s     <= tb_avs_write_s    when tb_is_writing_mem_s = '1' else avm_write_s;
    avs_read_s      <= '0'              when tb_is_writing_mem_s = '1' else avm_read_s;

    -- Instantiate Avalon Agent (Simulated Memory)
    AGENT: entity work.sdram_avalon_agent
    generic map (
        DATA_WIDTH     => DATA_WIDTH,
        ADDR_WIDTH     => ADDR_WIDTH,
        MEM_ADDR_WIDTH => MEM_ADDR_WIDTH
    )
    port map (
        clk                => clock_s,
        reset              => reset_s,
        avs_address        => avs_address_s,
        avs_read           => avs_read_s,
        avs_write          => avs_write_s,
        avs_writedata      => avs_writedata_s,
        avs_readdata       => avs_readdata_s,
        avs_readdata_valid => avs_readdata_valid_s,
        avs_waitrequest    => avs_waitrequest_s
    );

    -- Clock generation process
    clock_proc: process
    begin
        if not tb_finished then
            clock_s <= '0';
            wait for CLK_PERIOD / 2;
            clock_s <= '1';
            wait for CLK_PERIOD / 2;
        else
            wait;
        end if;
    end process clock_proc;

    -- Main stimulus and verification process
    stimulus_proc: process
        -- Define a set of instructions to test with
        type instruction_array_t is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
        constant TEST_INSTRUCTIONS : instruction_array_t := (
            x"DEADBEEF",
            x"CAFEF00D",
            x"12345678",
            x"ABCDEF01"
        );

        variable expected_addr : unsigned(ADDR_WIDTH - 1 downto 0);
    begin
        report "--- Starting Core Testbench ---";

        -- 1. Apply reset
        trigger_s <= '0';
        reset_s   <= '1';
        wait for CLK_PERIOD * 2;
        reset_s <= '0';
        wait for CLK_PERIOD;

        -- 2. Write test instructions to the simulated SDRAM via Avalon bus
        report "--- Initializing Memory via Avalon Bus ---";
        tb_is_writing_mem_s <= '1'; -- Take control of the bus
        tb_avs_write_s      <= '0';
        wait for CLK_PERIOD;

        for i in TEST_INSTRUCTIONS'range loop
            -- Drive address and data
            tb_avs_address_s   <= std_logic_vector(to_unsigned(i * (DATA_WIDTH / 8), ADDR_WIDTH));
            tb_avs_writedata_s <= TEST_INSTRUCTIONS(i);
            tb_avs_write_s     <= '1';
            wait for CLK_PERIOD;

            -- Wait for agent to accept the write (waitrequest goes low)
            wait until avs_waitrequest_s = '0';
            wait for CLK_PERIOD;

            -- De-assert write signal
            tb_avs_write_s <= '0';
            report "Wrote " & to_hstring(TEST_INSTRUCTIONS(i)) & " to address " & integer'image(i * 4);
        end loop;

        tb_is_writing_mem_s <= '0'; -- Release control of the bus
        wait for CLK_PERIOD;

        -- 3. Trigger the CPU to start fetching instructions
        report "--- Triggering CPU ---";
        trigger_s <= '1';
        wait for CLK_PERIOD;
        trigger_s <= '0';

        -- 4. Verify that the CPU fetches and outputs the correct instructions
        report "--- Verifying Instruction Fetch ---";
        for i in TEST_INSTRUCTIONS'range loop
            -- Wait for the CPU to request the next instruction
            wait until rising_edge(clock_s) and usr_request_valid_s = '1';

            -- Check that the requested address is correct
            expected_addr := to_unsigned(i * (DATA_WIDTH / 8), ADDR_WIDTH);

            assert usr_request_address_s = std_logic_vector(expected_addr)
                report "Address mismatch! Expected: " & to_hstring(std_logic_vector(expected_addr)) &
                       ", Got: " & to_hstring(usr_request_address_s)
                severity error;

            -- Wait for the memory read to complete and the instruction to appear on the output
            wait until rising_edge(clock_s) and usr_readdata_valid_s = '1';
            wait for CLK_PERIOD; -- Wait one cycle for the data to be latched into instruction_register

            -- Now in the EXECUTE state, check the output
            assert instruction_out_s = TEST_INSTRUCTIONS(i)
                report "Instruction mismatch for address " & integer'image(i * 4) & LF &
                       "  Expected: " & to_hstring(TEST_INSTRUCTIONS(i)) & LF &
                       "  Actual:   " & to_hstring(instruction_out_s)
                severity error;

            report "OK: Fetched " & to_hstring(instruction_out_s) & " from address " & integer'image(i * 4);
        end loop;

        report "--- Testbench finished. ---";
        tb_finished <= true;
        wait;
    end process stimulus_proc;

end behavioral;
