library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_avm_sim_memory is
    -- Empty entity for testbench
end entity;

architecture sim of tb_avm_sim_memory is

    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk               : std_logic := '0';
    signal reset             : std_logic := '1';

    -- Avalon-MM Signals
    signal avs_address       : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal avs_burstcount    : std_logic_vector(7 downto 0) := (others => '0');
    signal avs_write         : std_logic := '0';
    signal avs_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal avs_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0) := (others => '1');
    signal avs_read          : std_logic := '0';
    signal avs_readdata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avs_readdatavalid : std_logic;
    signal avs_waitrequest   : std_logic;

    -- Communication between Stimulus and Checker processes
    type expected_queue_t is array (0 to 255) of unsigned(DATA_WIDTH-1 downto 0);
    signal expected_queue : expected_queue_t := (others => (others => '0'));
    signal q_head         : integer := 0; 
    signal q_tail         : integer := 0; 
    
    signal tests_done     : std_logic := '0';

begin

    -- Clock Generation
    clk <= not clk after CLK_PERIOD / 2;

    -- DUT Instantiation
    u_dut : entity work.avm_sim_memory
        generic map (
            ADDR_WIDTH        => ADDR_WIDTH,
            DATA_WIDTH        => DATA_WIDTH,
            MEM_WORDS         => 1024,
            MAX_DELAY         => 5,
            MAX_PENDING_READS => 4
        )
        port map (
            clk               => clk,
            reset             => reset,
            avs_address       => avs_address,
            avs_burstcount    => avs_burstcount,
            avs_write         => avs_write,
            avs_writedata     => avs_writedata,
            avs_byteenable    => avs_byteenable,
            avs_read          => avs_read,
            avs_readdata      => avs_readdata,
            avs_readdatavalid => avs_readdatavalid,
            avs_waitrequest   => avs_waitrequest
        );

    -- ========================================================================
    -- PROCESS 1: CHECKER (Runs concurrently to catch returning data)
    -- ========================================================================
    checker_proc: process
        variable v_q_tail : integer := 0;
    begin
        wait until rising_edge(clk);
        if reset = '0' and tests_done = '0' then
            if avs_readdatavalid = '1' then
                if v_q_tail >= q_head then
                    report "FATAL: Received readdatavalid but no data was expected!" severity failure;
                else
                    assert unsigned(avs_readdata) = expected_queue(v_q_tail)
                        report "DATA MISMATCH! Expected: 0x" & to_hstring(expected_queue(v_q_tail)) & 
                               ", Got: 0x" & to_hstring(unsigned(avs_readdata))
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
    stimulus_proc: process
        variable timeout  : integer := 0;
        variable v_q_head : integer := 0;

        -----------------------------------------------------------------------
        procedure do_write(
            base_addr  : in unsigned(ADDR_WIDTH-1 downto 0);
            burst_len  : in integer;
            start_data : in unsigned(DATA_WIDTH-1 downto 0);
            byte_en    : in std_logic_vector((DATA_WIDTH/8)-1 downto 0) := (others => '1') 
        ) is
            variable current_data : unsigned(DATA_WIDTH-1 downto 0) := start_data;
        begin
            avs_address    <= std_logic_vector(base_addr);
            avs_burstcount <= std_logic_vector(to_unsigned(burst_len, 8));
            avs_byteenable <= byte_en;
            avs_write      <= '1';

            for i in 0 to burst_len-1 loop
                avs_writedata <= std_logic_vector(current_data);
                timeout := 0;
                loop
                    wait until rising_edge(clk);
                    exit when avs_waitrequest = '0';
                    timeout := timeout + 1;
                    assert timeout < 500 report "FATAL: Write waitrequest timeout!" severity failure;
                end loop;
                current_data := current_data + 1;
            end loop;
            
            avs_write      <= '0';
            avs_byteenable <= (others => '1'); 
            wait until rising_edge(clk);
        end procedure;

        -----------------------------------------------------------------------
        procedure do_read_req(
            base_addr     : in unsigned(ADDR_WIDTH-1 downto 0);
            burst_len     : in integer;
            expected_data : in unsigned(DATA_WIDTH-1 downto 0)
        ) is
        begin
            for i in 0 to burst_len-1 loop
                expected_queue(v_q_head) <= expected_data + i;
                v_q_head := v_q_head + 1;
            end loop;
            q_head <= v_q_head; 

            avs_address    <= std_logic_vector(base_addr);
            avs_burstcount <= std_logic_vector(to_unsigned(burst_len, 8));
            avs_read       <= '1';
            
            timeout := 0;
            loop
                wait until rising_edge(clk);
                exit when avs_waitrequest = '0';
                timeout := timeout + 1;
                assert timeout < 500 report "FATAL: Read request waitrequest timeout!" severity failure;
            end loop;
            
            avs_read <= '0';
        end procedure;

        -----------------------------------------------------------------------
        procedure wait_for_reads is
        begin
            timeout := 0;
            loop
                wait until rising_edge(clk);
                exit when q_head = q_tail; 
                timeout := timeout + 1;
                assert timeout < 2000 report "FATAL: Timeout waiting for all reads to finish!" severity failure;
            end loop;
            for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        end procedure;

    begin
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        reset <= '0';
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        report "--- STARTING DDR3 AVALON-MM SIMULATION ---";

        -- ====================================================================
        -- 1. INDIVIDUAL READS/WRITES
        -- ====================================================================
        report "Test 1: Individual Singles...";
        do_write(x"00001000", 1, to_unsigned(1111, DATA_WIDTH)); 
        do_write(x"00001010", 1, to_unsigned(2222, DATA_WIDTH));

        do_read_req(x"00001000", 1, to_unsigned(1111, DATA_WIDTH));
        do_read_req(x"00001010", 1, to_unsigned(2222, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 2. INDIVIDUAL BURSTS
        -- ====================================================================
        report "Test 2: Individual Bursts...";
        do_write(x"00002000", 4, to_unsigned(3330, DATA_WIDTH));
        do_write(x"00002040", 4, to_unsigned(4440, DATA_WIDTH));

        do_read_req(x"00002000", 4, to_unsigned(3330, DATA_WIDTH));
        wait_for_reads;
        do_read_req(x"00002040", 4, to_unsigned(4440, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 3. PIPELINED INDIVIDUAL READS
        -- ====================================================================
        report "Test 3: Pipelined Singles...";
        do_write(x"00003000", 1, to_unsigned(5000, DATA_WIDTH));
        do_write(x"00003010", 1, to_unsigned(6000, DATA_WIDTH));
        do_write(x"00003020", 1, to_unsigned(7000, DATA_WIDTH));

        do_read_req(x"00003000", 1, to_unsigned(5000, DATA_WIDTH));
        do_read_req(x"00003010", 1, to_unsigned(6000, DATA_WIDTH));
        do_read_req(x"00003020", 1, to_unsigned(7000, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 4. PIPELINED BURSTS 
        -- ====================================================================
        report "Test 4: Pipelined Bursts...";
        do_write(x"00004000", 2, to_unsigned(8800, DATA_WIDTH)); 
        do_write(x"00004020", 3, to_unsigned(9900, DATA_WIDTH)); 
        do_write(x"00004050", 4, to_unsigned(1100, DATA_WIDTH)); 

        do_read_req(x"00004000", 2, to_unsigned(8800, DATA_WIDTH));
        do_read_req(x"00004020", 3, to_unsigned(9900, DATA_WIDTH));
        do_read_req(x"00004050", 4, to_unsigned(1100, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 5. BYTE ENABLE (PARTIAL WRITE) TEST
        -- ====================================================================
        report "Test 5: Byte Enable Masking...";
        do_write(x"00005000", 1, unsigned'(x"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
        do_write(x"00005000", 1, unsigned'(x"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"), x"00FF");
        do_read_req(x"00005000", 1, unsigned'(x"AAAAAAAAAAAAAAAABBBBBBBBBBBBBBBB"));
        wait_for_reads;

        -- ====================================================================
        -- 6. INTERLEAVED READ/WRITE TRANSACTIONS
        -- ====================================================================
        report "Test 6: Interleaved Read/Write...";
        -- Issue a write, immediately read it, immediately write the next addr, immediately read...
        do_write(x"00006000", 1, to_unsigned(6001, DATA_WIDTH));
        do_read_req(x"00006000", 1, to_unsigned(6001, DATA_WIDTH));
        
        do_write(x"00006010", 2, to_unsigned(6002, DATA_WIDTH));
        do_read_req(x"00006010", 2, to_unsigned(6002, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 7. THE "STITCH-UP" BYTE ENABLE STRESS TEST
        -- ====================================================================
        report "Test 7: Complex Byte Enable Stitching...";
        -- Initialize memory to 0
        do_write(x"00007000", 1, unsigned'(x"00000000000000000000000000000000"));
        
        -- Write 4 distinct 32-bit (4-byte) chunks sequentially
        do_write(x"00007000", 1, unsigned'(x"11111111111111111111111111111111"), x"000F"); -- Bytes 0-3
        do_write(x"00007000", 1, unsigned'(x"22222222222222222222222222222222"), x"00F0"); -- Bytes 4-7
        do_write(x"00007000", 1, unsigned'(x"33333333333333333333333333333333"), x"0F00"); -- Bytes 8-11
        do_write(x"00007000", 1, unsigned'(x"44444444444444444444444444444444"), x"F000"); -- Bytes 12-15
        
        -- Verify they all merged successfully
        do_read_req(x"00007000", 1, unsigned'(x"44444444333333332222222211111111"));
        wait_for_reads;

        -- ====================================================================
        -- 8. MASTER-SIDE IDLE DELAYS
        -- ====================================================================
        report "Test 8: Master-Side Idle Delays...";
        do_write(x"00008000", 1, to_unsigned(8001, DATA_WIDTH));
        
        -- Insert a synthetic delay where the master drops the bus
        for i in 1 to 13 loop wait until rising_edge(clk); end loop;
        
        do_write(x"00008010", 1, to_unsigned(8002, DATA_WIDTH));
        do_read_req(x"00008000", 1, to_unsigned(8001, DATA_WIDTH));
        
        for i in 1 to 7 loop wait until rising_edge(clk); end loop;
        
        do_read_req(x"00008010", 1, to_unsigned(8002, DATA_WIDTH));
        wait_for_reads;

        -- ====================================================================
        -- 9. MAXIMUM PIPELINE SATURATION (Mixed Lengths)
        -- ====================================================================
        report "Test 9: Maximum Pipeline Saturation...";
        do_write(x"00009000", 1, to_unsigned(9000, DATA_WIDTH)); -- Len 1
        do_write(x"00009010", 3, to_unsigned(9100, DATA_WIDTH)); -- Len 3
        do_write(x"00009040", 2, to_unsigned(9200, DATA_WIDTH)); -- Len 2
        do_write(x"00009060", 4, to_unsigned(9300, DATA_WIDTH)); -- Len 4
        
        -- Queue up exactly MAX_PENDING_READS (4)
        do_read_req(x"00009000", 1, to_unsigned(9000, DATA_WIDTH));
        do_read_req(x"00009010", 3, to_unsigned(9100, DATA_WIDTH));
        do_read_req(x"00009040", 2, to_unsigned(9200, DATA_WIDTH));
        do_read_req(x"00009060", 4, to_unsigned(9300, DATA_WIDTH));
        
        -- Let the checker sort out the 10 combined beats of returning data
        wait_for_reads;

        report "--- ALL STRESS TESTS PASSED SUCCESSFULLY ---";
        tests_done <= '1';
        std.env.stop;
        
    end process;

end architecture sim;
