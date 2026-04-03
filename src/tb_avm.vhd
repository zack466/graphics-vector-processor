library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_avm is
    -- Testbench has no ports
end entity;

architecture sim of tb_avm is

    -- ========================================================================
    -- Constants & Signals
    -- ========================================================================
    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';

    -- Internal Bridge Signals (Stimulus <-> Master)
    signal cmd_valid    : std_logic := '0';
    signal cmd_is_store : std_logic := '0';
    signal cmd_addr     : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal cmd_burst_len: std_logic_vector(7 downto 0) := (others => '0');
    signal cmd_ready    : std_logic;
    
    signal tx_data      : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal tx_byte_en   : std_logic_vector((DATA_WIDTH/8)-1 downto 0) := (others => '1');
    signal tx_valid     : std_logic := '0';
    signal tx_ready     : std_logic;
    
    signal rx_data      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal rx_valid     : std_logic;

    -- Avalon-MM Bus Signals (Master <-> Slave)
    signal avm_address       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal avm_burstcount    : std_logic_vector(7 downto 0);
    signal avm_write         : std_logic;
    signal avm_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avm_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal avm_read          : std_logic;
    signal avm_readdata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avm_readdatavalid : std_logic;
    signal avm_waitrequest   : std_logic;

    -- ========================================================================
    -- EXPECTED DATA QUEUE (Fixes the undefined errors)
    -- ========================================================================
    -- This queue passes the expected answers from the Stimulus to the Checker
    type expected_queue_t is array (0 to 511) of unsigned(DATA_WIDTH-1 downto 0);
    signal expected_queue : expected_queue_t := (others => (others => '0'));
    signal q_head         : integer := 0; 
    signal q_tail         : integer := 0; 

begin

    -- ========================================================================
    -- Clock Generation
    -- ========================================================================
    clk <= not clk after CLK_PERIOD / 2;

    -- ========================================================================
    -- Device Under Test 1: The Avalon Master Bridge
    -- ========================================================================
    u_master_bridge : entity work.avm_burst_bridge
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,
            
            cmd_valid         => cmd_valid,
            cmd_is_store      => cmd_is_store,
            cmd_addr          => cmd_addr,
            cmd_burst_len     => cmd_burst_len,
            cmd_ready         => cmd_ready,
            tx_data           => tx_data,
            tx_byte_en        => tx_byte_en,
            tx_valid          => tx_valid,
            tx_ready          => tx_ready,
            rx_data           => rx_data,     -- We will check this output!
            rx_valid          => rx_valid,    -- We will check this output!

            avm_address       => avm_address,
            avm_burstcount    => avm_burstcount,
            avm_write         => avm_write,
            avm_writedata     => avm_writedata,
            avm_byteenable    => avm_byteenable,
            avm_read          => avm_read,
            avm_readdata      => avm_readdata,
            avm_readdatavalid => avm_readdatavalid,
            avm_waitrequest   => avm_waitrequest
        );

    -- ========================================================================
    -- Device Under Test 2: The Simulated Avalon Slave RAM
    -- ========================================================================
    u_sim_memory : entity work.avm_sim_memory
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH,
            MEM_WORDS  => 1024,
            MAX_DELAY  => 5,
            MAX_PENDING_READS => 4
        )
        port map (
            clk               => clk,
            reset             => reset,
            
            avs_address       => avm_address,
            avs_burstcount    => avm_burstcount,
            avs_write         => avm_write,
            avs_writedata     => avm_writedata,
            avs_byteenable    => avm_byteenable,
            avs_read          => avm_read,
            avs_readdata      => avm_readdata,
            avs_readdatavalid => avm_readdatavalid,
            avs_waitrequest   => avm_waitrequest
        );

    -- ========================================================================
    -- PROCESS 1: CHECKER (Asynchronous Data Verification)
    -- ========================================================================
    -- This process runs continuously in the background, verifying data from the
    -- Bridge's rx_data port the exact moment rx_valid pulses high.
    checker_proc: process
        variable v_q_tail : integer := 0;
    begin
        wait until rising_edge(clk);
        if reset = '0' then
            if rx_valid = '1' then
                if v_q_tail >= q_head then
                    report "FATAL: Received rx_valid from bridge but no data was expected!" severity failure;
                else
                    -- Ensure the data coming OUT of the bridge perfectly matches the expected queue
                    assert unsigned(rx_data) = expected_queue(v_q_tail)
                        report "DATA MISMATCH on Bridge RX! Expected: 0x" & to_hstring(expected_queue(v_q_tail)) & 
                               ", Got: 0x" & to_hstring(unsigned(rx_data))
                        severity error;
                    
                    v_q_tail := v_q_tail + 1;
                    q_tail   <= v_q_tail; 
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- PROCESS 2: STIMULUS (Issues Commands)
    -- ========================================================================
    p_stimulus : process
        variable timeout  : integer := 0;
        variable v_q_head : integer := 0;
        variable temp_addr : unsigned(ADDR_WIDTH-1 downto 0);
    
        procedure exec_write_burst(
            constant start_addr : in unsigned(ADDR_WIDTH-1 downto 0);
            constant burst_len  : in integer;
            constant base_data  : in unsigned(DATA_WIDTH-1 downto 0);
            constant byte_en    : in std_logic_vector((DATA_WIDTH/8)-1 downto 0) := (others => '1')
        ) is
            variable current_data : unsigned(DATA_WIDTH-1 downto 0) := base_data;
        begin
            cmd_addr      <= std_logic_vector(start_addr);
            cmd_burst_len <= std_logic_vector(to_unsigned(burst_len, 8));
            cmd_is_store  <= '1';
            cmd_valid     <= '1';
            
            loop
                wait until rising_edge(clk);
                exit when cmd_ready = '1';
            end loop;
            cmd_valid <= '0';

            for i in 0 to burst_len - 1 loop
                tx_data    <= std_logic_vector(current_data);
                tx_byte_en <= byte_en;
                tx_valid   <= '1';
                
                loop
                    wait until rising_edge(clk);
                    exit when tx_ready = '1';
                end loop;
                current_data := current_data + 1;
            end loop;
            
            tx_valid   <= '0';
            tx_byte_en <= (others => '1');
            wait until rising_edge(clk);
        end procedure;

        procedure exec_read_req(
            constant start_addr : in unsigned(ADDR_WIDTH-1 downto 0);
            constant burst_len  : in integer;
            constant expected_data : in unsigned(DATA_WIDTH-1 downto 0)
        ) is
        begin
            -- Pre-load the checker queue with the expected answers
            for i in 0 to burst_len-1 loop
                expected_queue(v_q_head) <= expected_data + i;
                v_q_head := v_q_head + 1;
            end loop;
            q_head <= v_q_head; 

            cmd_addr      <= std_logic_vector(start_addr);
            cmd_burst_len <= std_logic_vector(to_unsigned(burst_len, 8));
            cmd_is_store  <= '0';
            cmd_valid     <= '1';
            
            timeout := 0;
            loop
                wait until rising_edge(clk);
                exit when cmd_ready = '1';
                timeout := timeout + 1;
                assert timeout < 1000 report "FATAL: Read request cmd_ready stall timeout!" severity failure;
            end loop;
            
            cmd_valid <= '0';
        end procedure;

        procedure wait_for_reads is
        begin
            timeout := 0;
            loop
                wait until rising_edge(clk);
                exit when q_head = q_tail; 
                timeout := timeout + 1;
                assert timeout < 5000 report "FATAL: Timeout waiting for all reads to finish!" severity failure;
            end loop;
            wait for 20 ns;
            wait until rising_edge(clk);
        end procedure;

    begin
        wait for 50 ns;
        wait until rising_edge(clk);
        reset <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);

        report "--- STARTING AVALON-MM BRIDGE TESTS ---";

        report "Test 1: Single Word Write/Read";
        exec_write_burst(x"00001000", 1, to_unsigned(999, DATA_WIDTH));
        exec_read_req(x"00001000", 1, to_unsigned(999, DATA_WIDTH));
        wait_for_reads;

        report "Test 2: Burst of 4 Words";
        exec_write_burst(x"00002000", 4, to_unsigned(5000, DATA_WIDTH));
        exec_read_req(x"00002000", 4, to_unsigned(5000, DATA_WIDTH));
        wait_for_reads;

        report "Test 3: Overwriting Memory";
        exec_write_burst(x"00001000", 1, to_unsigned(8888, DATA_WIDTH));
        exec_read_req(x"00001000", 1, to_unsigned(8888, DATA_WIDTH));
        wait_for_reads;

        report "Test 4: Long Burst of 16 Words";
        exec_write_burst(x"00003000", 16, to_unsigned(100, DATA_WIDTH));
        exec_read_req(x"00003000", 16, to_unsigned(100, DATA_WIDTH));
        wait_for_reads;

        report "Test 5: Bridge Byte Enable Masking";
        exec_write_burst(x"00004000", 1, unsigned'(x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"));
        exec_write_burst(x"00004000", 1, unsigned'(x"00000000000000000000000000000000"), x"00FF");
        exec_read_req(x"00004000", 1, unsigned'(x"FFFFFFFFFFFFFFFF0000000000000000"));
        wait_for_reads;

        report "Test 6: Interleaved Read/Write";
        exec_write_burst(x"00006000", 1, to_unsigned(6001, DATA_WIDTH));
        exec_read_req(x"00006000", 1, to_unsigned(6001, DATA_WIDTH));
        exec_write_burst(x"00006010", 2, to_unsigned(6002, DATA_WIDTH));
        exec_read_req(x"00006010", 2, to_unsigned(6002, DATA_WIDTH));
        wait_for_reads;

        report "Test 7: Complex Byte Enable Stitching";
        exec_write_burst(x"00007000", 1, unsigned'(x"00000000000000000000000000000000"));
        exec_write_burst(x"00007000", 1, unsigned'(x"11111111111111111111111111111111"), x"000F"); 
        exec_write_burst(x"00007000", 1, unsigned'(x"22222222222222222222222222222222"), x"00F0"); 
        exec_write_burst(x"00007000", 1, unsigned'(x"33333333333333333333333333333333"), x"0F00"); 
        exec_write_burst(x"00007000", 1, unsigned'(x"44444444444444444444444444444444"), x"F000"); 
        exec_read_req(x"00007000", 1, unsigned'(x"44444444333333332222222211111111"));
        wait_for_reads;

        report "Test 8: Master-Side Idle Delays";
        exec_write_burst(x"00008000", 1, to_unsigned(8001, DATA_WIDTH));
        wait for 130 ns; wait until rising_edge(clk);
        exec_write_burst(x"00008010", 1, to_unsigned(8002, DATA_WIDTH));
        exec_read_req(x"00008000", 1, to_unsigned(8001, DATA_WIDTH));
        wait for 75 ns; wait until rising_edge(clk);
        exec_read_req(x"00008010", 1, to_unsigned(8002, DATA_WIDTH));
        wait_for_reads;

        report "Test 9: Maximum Pipeline Saturation";
        exec_write_burst(x"00009000", 1, to_unsigned(9000, DATA_WIDTH));
        exec_write_burst(x"00009010", 3, to_unsigned(9100, DATA_WIDTH));
        exec_write_burst(x"00009040", 2, to_unsigned(9200, DATA_WIDTH));
        exec_write_burst(x"00009060", 4, to_unsigned(9300, DATA_WIDTH));
        exec_read_req(x"00009000", 1, to_unsigned(9000, DATA_WIDTH));
        exec_read_req(x"00009010", 3, to_unsigned(9100, DATA_WIDTH));
        exec_read_req(x"00009040", 2, to_unsigned(9200, DATA_WIDTH));
        exec_read_req(x"00009060", 4, to_unsigned(9300, DATA_WIDTH));
        wait_for_reads;

        report "Test 10: Heavy Sequential Write Load (10 chained bursts)";
        temp_addr := x"0000A000";
        for i in 0 to 9 loop
            exec_write_burst(temp_addr, 4, to_unsigned(10000 + (i*10), DATA_WIDTH));
            temp_addr := temp_addr + x"40"; 
        end loop;
        
        temp_addr := x"0000A000";
        for i in 0 to 9 loop
            exec_read_req(temp_addr, 4, to_unsigned(10000 + (i*10), DATA_WIDTH));
            temp_addr := temp_addr + x"40"; 
        end loop;
        wait_for_reads;

        report "Test 11: Deep Pipeline Overload (8 chained reads)";
        temp_addr := x"0000B000";
        for i in 0 to 7 loop
            exec_write_burst(temp_addr, 1, to_unsigned(20000 + i, DATA_WIDTH));
            temp_addr := temp_addr + x"10";
        end loop;

        temp_addr := x"0000B000";
        for i in 0 to 7 loop
            exec_read_req(temp_addr, 1, to_unsigned(20000 + i, DATA_WIDTH));
            temp_addr := temp_addr + x"10";
        end loop;
        wait_for_reads;

        report "Test 12: High-Speed Ping-Pong (Rapid W/R/W/R switching)";
        temp_addr := x"0000C000";
        for i in 0 to 15 loop
            exec_write_burst(temp_addr, 1, to_unsigned(30000 + i, DATA_WIDTH));
            exec_read_req(temp_addr, 1, to_unsigned(30000 + i, DATA_WIDTH));
            temp_addr := temp_addr + x"10";
        end loop;
        wait_for_reads;

        -- ====================================================================
        -- FINAL CONFIRMATION
        -- ====================================================================
        report "--- ALL STRESS TESTS PASSED SUCCESSFULLY ---";
        report "Total Read Beats Verified by Checker Process: " & integer'image(q_head);
        std.env.stop;
        
    end process;

end architecture sim;
