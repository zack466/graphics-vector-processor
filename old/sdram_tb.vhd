----------------------------------------------------------------------------
--
--  TODO
-- 
--  Revision History:
--     20 May 25    Zack Huang      initial revision
--
----------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity sdram_host_tb is
end entity sdram_host_tb;

architecture test of sdram_host_tb is

    -- Testbench Configuration
    constant DATA_WIDTH            : integer := 128;
    constant ADDR_WIDTH            : integer := 32;
    constant AVM_BURST_COUNT_WIDTH : integer := 10;
    constant CLK_PERIOD            : time    := 10 ns; -- 100 MHz clock

    -- UUT Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic;

    -- User-Side Interface
    signal usr_request_valid    : std_logic;
    signal usr_request_ready    : std_logic;
    signal usr_request_is_write : std_logic;
    signal usr_request_address  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal usr_writedata        : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_byteenable       : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
    signal usr_readdata         : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_readdata_valid   : std_logic;

    -- Avalon-MM Master Interface
    signal avm_address        : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal avm_read           : std_logic;
    signal avm_write          : std_logic;
    signal avm_waitrequest    : std_logic;
    signal avm_writedata      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avm_byteenable     : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
    signal avm_readdata       : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avm_readdata_valid : std_logic;

    -- Simulation control
    signal simulation_finished : boolean := false;

begin

    -- Instantiate the Unit Under Test (UUT)
    UUT : entity work.sdram_avalon_host
        generic map (
            DATA_WIDTH            => DATA_WIDTH,
            ADDR_WIDTH            => ADDR_WIDTH
        )
        port map (
            clk                  => clk,
            reset                => reset,
            usr_request_valid    => usr_request_valid,
            usr_request_ready    => usr_request_ready,
            usr_request_is_write => usr_request_is_write,
            usr_request_address  => usr_request_address,
            usr_writedata        => usr_writedata,
            usr_byteenable       => usr_byteenable,
            usr_readdata         => usr_readdata,
            usr_readdata_valid   => usr_readdata_valid,
            avm_address          => avm_address,
            avm_read             => avm_read,
            avm_write            => avm_write,
            avm_waitrequest      => avm_waitrequest,
            avm_writedata        => avm_writedata,
            avm_byteenable       => avm_byteenable,
            avm_readdata         => avm_readdata,
            avm_readdata_valid   => avm_readdata_valid
        );

    -- Clock Generation
    clk <= not clk after CLK_PERIOD / 2 when not simulation_finished;

    -- Reset Generation
    reset_proc: process
    begin
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait;
    end process reset_proc;

    -- Avalon-MM Slave Model
    avalon_slave_proc: process(clk)
        -- This slave model has a 2-cycle read latency and inserts 2 wait states for every command.
        constant READ_LATENCY : integer := 2;
        type mem_array_t is array (0 to 255) of std_logic_vector(DATA_WIDTH - 1 downto 0);
        variable memory : mem_array_t := (others => (others => '0'));
        variable read_latency_counter : integer range 0 to READ_LATENCY;
        variable wait_counter : integer range 0 to 2;
        variable read_addr : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                avm_waitrequest    <= '0';
                avm_readdata_valid <= '0';
                avm_readdata       <= (others => '0');
                read_latency_counter := 0;
                wait_counter := 0;
            else
                -- Default assignments
                avm_waitrequest    <= '0';
                avm_readdata_valid <= '0';

                -- Handle wait states
                if (avm_read = '1' or avm_write = '1') and wait_counter = 0 then
                    wait_counter := 2; -- Insert 2 wait states
                end if;

                if wait_counter > 0 then
                    avm_waitrequest <= '1';
                    wait_counter := wait_counter - 1;
                end if;

                -- Handle write command
                if avm_write = '1' and avm_waitrequest = '0' then
                    memory(to_integer(unsigned(avm_address(7 downto 0)))) := avm_writedata;
                end if;

                -- Handle read command and data phase
                if avm_read = '1' and avm_waitrequest = '0' then
                    read_addr := avm_address;
                    read_latency_counter := READ_LATENCY;
                end if;

                if read_latency_counter > 0 then
                    read_latency_counter := read_latency_counter - 1;
                    if read_latency_counter = 0 then
                        avm_readdata_valid <= '1';
                        avm_readdata       <= memory(to_integer(unsigned(read_addr(7 downto 0))));
                    end if;
                end if;
            end if;
        end if;
    end process avalon_slave_proc;

    -- Stimulus Process
    stimulus_proc: process
        -- Procedure to perform a write transaction
        procedure write_transaction(
            constant address  : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
            constant data     : in std_logic_vector(DATA_WIDTH - 1 downto 0);
            constant b_enable : in std_logic_vector(DATA_WIDTH/8 - 1 downto 0) := (others => '1')
        ) is
        begin
            -- Wait until the host is ready to accept a new request
            wait until rising_edge(clk) and usr_request_ready = '1';

            -- Drive the user interface signals for a write command
            usr_request_valid    <= '1';
            usr_request_is_write <= '1';
            usr_request_address  <= address;
            usr_writedata        <= data;
            usr_byteenable       <= b_enable;

            -- Wait for the host to acknowledge the request
            wait until rising_edge(clk) and usr_request_ready = '1';

            -- Deassert valid to complete the handshake
            usr_request_valid <= '0';
        end procedure write_transaction;

        -- Procedure to perform a read transaction
        procedure read_transaction(
            constant address   : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
            variable read_data : out std_logic_vector(DATA_WIDTH - 1 downto 0)
        ) is
        begin
            -- Wait until the host is ready to accept a new request
            wait until rising_edge(clk) and usr_request_ready = '1';

            -- Drive the user interface signals for a read command
            usr_request_valid    <= '1';
            usr_request_is_write <= '0';
            usr_request_address  <= address;

            -- Wait for the host to acknowledge the request
            wait until rising_edge(clk) and usr_request_ready = '1';

            -- Deassert valid to complete the command handshake
            usr_request_valid <= '0';

            -- Wait for the read data to be returned from the host
            wait until rising_edge(clk) and usr_readdata_valid = '1';

            -- Capture the returned data
            read_data := usr_readdata;
        end procedure read_transaction;

        constant TEST_ADDR_1 : std_logic_vector(ADDR_WIDTH - 1 downto 0) := x"00000010";
        constant TEST_DATA_1 : std_logic_vector(DATA_WIDTH - 1 downto 0) := x"DEADBEEF_CAFEF00D_12345678_9ABCDEF0";
        constant TEST_ADDR_2 : std_logic_vector(ADDR_WIDTH - 1 downto 0) := x"0000002A";
        constant TEST_DATA_2 : std_logic_vector(DATA_WIDTH - 1 downto 0) := x"FEEDFACE_00112233_AABBCCDD_EEFF0011";
        variable captured_readdata : std_logic_vector(DATA_WIDTH - 1 downto 0);

    begin
        report "Starting simulation...";
        wait until reset = '0';
        wait for CLK_PERIOD;

        -- Initialize user inputs
        usr_request_valid <= '0';

        -- Test 1: Single Write Transaction
        report "Test 1: Performing single write transaction...";
        write_transaction(TEST_ADDR_1, TEST_DATA_1);

        -- Test 2: Single Read Transaction
        report "Test 2: Performing single read transaction to verify write.";
        read_transaction(TEST_ADDR_1, captured_readdata);
        assert captured_readdata = TEST_DATA_1
            report "FAILURE: Read data mismatch! Expected " & to_hstring(TEST_DATA_1) & ", Got " & to_hstring(captured_readdata)
            severity error;

        -- Test 3: Back-to-back transactions
        report "Test 3: Performing back-to-back write then read.";
        write_transaction(TEST_ADDR_2, TEST_DATA_2);
        read_transaction(TEST_ADDR_2, captured_readdata);
        assert captured_readdata = TEST_DATA_2
            report "FAILURE: Back-to-back read data mismatch!"
            severity error;

        simulation_finished <= true;
        wait;
    end process stimulus_proc;

end architecture test;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity sdram_agent_tb is
end entity sdram_agent_tb;

architecture test of sdram_agent_tb is

    -- Testbench Configuration
    constant DATA_WIDTH     : integer := 128;
    constant ADDR_WIDTH     : integer := 32;
    constant MEM_ADDR_WIDTH : integer := 8; -- Must match the UUT generic
    constant CLK_PERIOD     : time    := 10 ns;
    constant BYTES_PER_WORD : integer := DATA_WIDTH / 8;

    -- UUT Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic;

    -- Avalon-MM Interface Signals
    signal avs_address        : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal avs_read           : std_logic;
    signal avs_write          : std_logic;
    signal avs_writedata      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avs_readdata       : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal avs_readdata_valid : std_logic;
    signal avs_waitrequest    : std_logic;

    -- Simulation control
    signal simulation_finished : boolean := false;

begin

    -- Instantiate the Unit Under Test (UUT)
    UUT : entity work.sdram_avalon_agent
        generic map (
            DATA_WIDTH     => DATA_WIDTH,
            ADDR_WIDTH     => ADDR_WIDTH,
            MEM_ADDR_WIDTH => MEM_ADDR_WIDTH
        )
        port map (
            clk                => clk,
            reset              => reset,
            avs_address        => avs_address,
            avs_read           => avs_read,
            avs_write          => avs_write,
            avs_writedata      => avs_writedata,
            avs_readdata       => avs_readdata,
            avs_readdata_valid => avs_readdata_valid,
            avs_waitrequest    => avs_waitrequest
        );

    -- Clock and Reset Generation
    clk <= not clk after CLK_PERIOD / 2 when not simulation_finished;

    reset_proc: process
    begin
        reset <= '1';
        wait for CLK_PERIOD * 3;
        reset <= '0';
        wait;
    end process reset_proc;

    -- Stimulus Process
    stimulus_proc: process
        -- Procedure to perform an Avalon-MM write transaction
        procedure write_transaction(constant addr : in unsigned(ADDR_WIDTH - 1 downto 0);
                                    constant data : in std_logic_vector(DATA_WIDTH - 1 downto 0)) is
        begin
            wait until rising_edge(clk) and avs_waitrequest = '0';
            avs_write     <= '1';
            avs_address   <= std_logic_vector(addr);
            avs_writedata <= data;
            wait for CLK_PERIOD;
            avs_write <= '0';
            avs_address <= (others => '0'); -- De-assert address after command phase
        end procedure write_transaction;

        -- Procedure to perform an Avalon-MM read transaction
        procedure read_transaction(constant addr        : in  unsigned(ADDR_WIDTH - 1 downto 0);
                                   variable data_read : out std_logic_vector(DATA_WIDTH - 1 downto 0)) is
        begin
            -- Command Phase
            wait until rising_edge(clk) and avs_waitrequest = '0';
            avs_read    <= '1';
            avs_address <= std_logic_vector(addr);
            wait for CLK_PERIOD;
            avs_read <= '0';
            avs_address <= (others => '0'); -- De-assert address after command phase

            -- Data Phase
            wait until rising_edge(clk) and avs_readdata_valid = '1';
            data_read := avs_readdata;
        end procedure read_transaction;

        -- Test data constants
        constant WRITE_DATA_0 : std_logic_vector(DATA_WIDTH-1 downto 0) := x"AAAABBBBCCCCDDDDEEEEFFFF00000000";
        constant WRITE_DATA_1 : std_logic_vector(DATA_WIDTH-1 downto 0) := x"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        constant WRITE_DATA_2 : std_logic_vector(DATA_WIDTH-1 downto 0) := x"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBCC";
        constant WRITE_DATA_3 : std_logic_vector(DATA_WIDTH-1 downto 0) := x"1111111111111111111111111111AAAA";
        constant ZEROS        : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');

        variable captured_data : std_logic_vector(DATA_WIDTH - 1 downto 0);
    begin
        report "Starting simulation...";
        wait until reset = '0';

        -- Initialize signals
        avs_read      <= '0';
        avs_write     <= '0';
        avs_address   <= (others => '0');
        avs_writedata <= (others => '0');
        wait for CLK_PERIOD;

        -- Perform a series of writes with corrected byte addresses
        report "Performing write transactions...";
        write_transaction(to_unsigned(0 * BYTES_PER_WORD, ADDR_WIDTH), WRITE_DATA_0);
        write_transaction(to_unsigned(1 * BYTES_PER_WORD, ADDR_WIDTH), WRITE_DATA_1);
        write_transaction(to_unsigned(2 * BYTES_PER_WORD, ADDR_WIDTH), WRITE_DATA_2);
        write_transaction(to_unsigned(3 * BYTES_PER_WORD, ADDR_WIDTH), WRITE_DATA_3);
        report "Write transactions complete.";

        -- Perform reads and verify data with corrected byte addresses
        report "Performing read verification...";
        read_transaction(to_unsigned(0 * BYTES_PER_WORD, ADDR_WIDTH), captured_data);
        assert captured_data = WRITE_DATA_0 report "FAILURE: Read data at address 0 mismatch!" severity error;
        report "Read data @ 0: " & to_hstring(captured_data);

        read_transaction(to_unsigned(1 * BYTES_PER_WORD, ADDR_WIDTH), captured_data);
        assert captured_data = WRITE_DATA_1 report "FAILURE: Read data at address 1 mismatch!" severity error;
        report "Read data @ 1: " & to_hstring(captured_data);

        read_transaction(to_unsigned(2 * BYTES_PER_WORD, ADDR_WIDTH), captured_data);
        assert captured_data = WRITE_DATA_2 report "FAILURE: Read data at address 2 mismatch!" severity error;
        report "Read data @ 2: " & to_hstring(captured_data);

        read_transaction(to_unsigned(3 * BYTES_PER_WORD, ADDR_WIDTH), captured_data);
        assert captured_data = WRITE_DATA_3 report "FAILURE: Read data at address 3 mismatch!" severity error;
        report "Read data @ 3: " & to_hstring(captured_data);

        -- Test reading an uninitialized address (should be all zeros)
        read_transaction(to_unsigned(4 * BYTES_PER_WORD, ADDR_WIDTH), captured_data);
        assert captured_data = ZEROS report "FAILURE: Read data at address 4 was not zero!" severity error;
        report "Read data @ 4: " & to_hstring(captured_data);

        report "All tests completed successfully.";
        simulation_finished <= true;
        wait;
    end process stimulus_proc;

end architecture test;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity host_agent_integration_tb is
end entity host_agent_integration_tb;

architecture test of host_agent_integration_tb is

    -- Testbench Configuration
    constant DATA_WIDTH     : integer := 128;
    constant ADDR_WIDTH     : integer := 32;
    constant MEM_ADDR_WIDTH : integer := 8; -- Must match agent's generic
    constant CLK_PERIOD     : time    := 10 ns; -- 100 MHz clock
    constant BYTES_PER_WORD : integer := DATA_WIDTH / 8;

    -- System Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic;

    -- User-Side Interface (to Host)
    signal usr_request_valid    : std_logic;
    signal usr_request_ready    : std_logic;
    signal usr_request_is_write : std_logic;
    signal usr_request_address  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal usr_writedata        : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_byteenable       : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
    signal usr_readdata         : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal usr_readdata_valid   : std_logic;

    -- Avalon-MM Interface (between Host and Agent)
    signal av_address        : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal av_read           : std_logic;
    signal av_write          : std_logic;
    signal av_waitrequest    : std_logic;
    signal av_writedata      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal av_byteenable     : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
    signal av_readdata       : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal av_readdata_valid : std_logic;

    -- Simulation control
    signal simulation_finished : boolean := false;

begin

    -- Instantiate the Host (UUT1)
    HOST_UUT : entity work.sdram_avalon_host
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            -- System
            clk   => clk,
            reset => reset,
            -- User-Side
            usr_request_valid    => usr_request_valid,
            usr_request_ready    => usr_request_ready,
            usr_request_is_write => usr_request_is_write,
            usr_request_address  => usr_request_address,
            usr_writedata        => usr_writedata,
            usr_byteenable       => usr_byteenable,
            usr_readdata         => usr_readdata,
            usr_readdata_valid   => usr_readdata_valid,
            -- Avalon-MM Master
            avm_address        => av_address,
            avm_read           => av_read,
            avm_write          => av_write,
            avm_waitrequest    => av_waitrequest,
            avm_writedata      => av_writedata,
            avm_byteenable     => av_byteenable,
            avm_readdata       => av_readdata,
            avm_readdata_valid => av_readdata_valid
        );

    -- Instantiate the Agent (UUT2)
    AGENT_UUT : entity work.sdram_avalon_agent
        generic map (
            DATA_WIDTH     => DATA_WIDTH,
            ADDR_WIDTH     => ADDR_WIDTH,
            MEM_ADDR_WIDTH => MEM_ADDR_WIDTH
        )
        port map (
            -- System
            clk   => clk,
            reset => reset,
            -- Avalon-MM Slave
            avs_address        => av_address,
            avs_read           => av_read,
            avs_write          => av_write,
            avs_writedata      => av_writedata,
            avs_readdata       => av_readdata,
            avs_readdata_valid => av_readdata_valid,
            avs_waitrequest    => av_waitrequest
        );

    -- Clock and Reset Generation
    clk <= not clk after CLK_PERIOD / 2 when not simulation_finished;

    reset_proc: process
    begin
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait;
    end process reset_proc;

    -- Stimulus Process
    stimulus_proc: process
        -- Procedure to perform a write transaction via the host's user interface
        procedure write_transaction(
            constant address  : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
            constant data     : in std_logic_vector(DATA_WIDTH - 1 downto 0)
        ) is
        begin
            wait until rising_edge(clk) and usr_request_ready = '1';
            usr_request_valid    <= '1';
            usr_request_is_write <= '1';
            usr_request_address  <= address;
            usr_writedata        <= data;
            usr_byteenable       <= (others => '1');
            wait until rising_edge(clk);
            usr_request_valid <= '0';
        end procedure write_transaction;

        -- Procedure to perform a read transaction via the host's user interface
        procedure read_transaction(
            constant address   : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
            variable read_data : out std_logic_vector(DATA_WIDTH - 1 downto 0)
        ) is
        begin
            wait until rising_edge(clk) and usr_request_ready = '1';
            usr_request_valid    <= '1';
            usr_request_is_write <= '0';
            usr_request_address  <= address;
            wait until rising_edge(clk);
            usr_request_valid <= '0';

            -- Wait for the read data to be returned from the host
            wait until rising_edge(clk) and usr_readdata_valid = '1';
            read_data := usr_readdata;
        end procedure read_transaction;

        -- Test constants
        constant TEST_ADDR_1 : std_logic_vector(ADDR_WIDTH - 1 downto 0) := std_logic_vector(to_unsigned(16 * BYTES_PER_WORD, ADDR_WIDTH));
        constant TEST_DATA_1 : std_logic_vector(DATA_WIDTH - 1 downto 0) := x"DEADBEEF_CAFEF00D_12345678_9ABCDEF0";
        constant TEST_ADDR_2 : std_logic_vector(ADDR_WIDTH - 1 downto 0) := std_logic_vector(to_unsigned(42 * BYTES_PER_WORD, ADDR_WIDTH));
        constant TEST_DATA_2 : std_logic_vector(DATA_WIDTH - 1 downto 0) := x"FEEDFACE_00112233_AABBCCDD_EEFF0011";
        variable captured_readdata : std_logic_vector(DATA_WIDTH - 1 downto 0);

    begin
        report "Starting integration simulation...";
        wait until reset = '0';
        wait for CLK_PERIOD;

        -- Initialize user inputs
        usr_request_valid <= '0';
        usr_request_is_write <= '0';
        usr_request_address <= (others => '0');
        usr_writedata <= (others => '0');
        usr_byteenable <= (others => '0');

        -- Test 1: Single Write Transaction
        report "Test 1: Performing single write transaction...";
        write_transaction(TEST_ADDR_1, TEST_DATA_1);
        wait until rising_edge(clk) and usr_request_ready = '1'; -- Wait for transaction to complete
        report "Write transaction complete.";

        -- Test 2: Single Read Transaction to verify the write
        report "Test 2: Performing single read transaction to verify write.";
        read_transaction(TEST_ADDR_1, captured_readdata);
        assert captured_readdata = TEST_DATA_1
            report "FAILURE: Read data mismatch! Expected " & to_hstring(TEST_DATA_1) & ", Got " & to_hstring(captured_readdata)
            severity error;
        report "Read verification successful.";

        -- Test 3: Back-to-back write then read
        report "Test 3: Performing back-to-back write then read.";
        write_transaction(TEST_ADDR_2, TEST_DATA_2);
        read_transaction(TEST_ADDR_2, captured_readdata);
        assert captured_readdata = TEST_DATA_2
            report "FAILURE: Back-to-back read data mismatch!"
            severity error;
        report "Back-to-back test successful.";

        report "All tests passed.";
        simulation_finished <= true;
        wait;
    end process stimulus_proc;

end architecture test;
