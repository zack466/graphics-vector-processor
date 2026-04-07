library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_mcu_scatter_gather is
    -- Testbench
end entity;

architecture sim of tb_mcu_scatter_gather is

    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- MCU Control Signals
    signal mem_op_valid     : std_logic := '0';
    signal is_store         : std_logic := '0';
    signal base_addr        : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal offset_reg_idx   : std_logic_vector(1 downto 0) := "00";
    signal dest_src_reg_idx : std_logic_vector(1 downto 0) := "01";
    signal exec_mask        : std_logic_vector(WARP_SIZE-1 downto 0) := (others => '1');
    signal mem_stall        : std_logic;

    -- VRF <-> MCU Signals
    signal vrf_rd_addr_B  : std_logic_vector(6 downto 0);
    signal vrf_rd_data_B  : vector_t;
    signal vrf_wr_addr_B  : std_logic_vector(6 downto 0);
    signal vrf_wr_data_B  : vector_t;
    signal vrf_we_B       : std_logic;

    -- VRF Port A (Testbench Backdoor)
    signal rs1_addr       : std_logic_vector(6 downto 0) := (others => '0');
    signal rs1_data       : vector_t;
    signal rd_addr_A      : std_logic_vector(6 downto 0) := (others => '0');
    signal rd_data_A      : vector_t := (others => (others => '0'));
    signal write_mask_A   : std_logic_vector(3 downto 0) := "1111";
    signal we_A           : std_logic := '0';

    -- MCU <-> Bridge Signals
    signal cmd_valid      : std_logic;
    signal cmd_is_store   : std_logic;
    signal cmd_addr       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal cmd_burst_len  : std_logic_vector(7 downto 0);
    signal cmd_ready      : std_logic;
    signal tx_data        : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal tx_byte_en     : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal tx_valid       : std_logic;
    signal tx_ready       : std_logic;
    signal rx_data        : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal rx_valid       : std_logic;

    -- Bridge <-> Avalon Slave Memory Signals
    signal avm_address       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal avm_burstcount    : std_logic_vector(7 downto 0);
    signal avm_write         : std_logic;
    signal avm_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avm_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal avm_read          : std_logic;
    signal avm_readdata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal avm_readdatavalid : std_logic;
    signal avm_waitrequest   : std_logic;

begin

    clk <= not clk after CLK_PERIOD / 2;

    u_vrf : entity work.vector_reg_file
        generic map ( ADDR_WIDTH => 7 )
        port map (
            clk          => clk, reset => reset,
            rs1_addr     => rs1_addr, rs2_addr => (others => '0'), rs3_addr => (others => '0'),
            rs1_data     => rs1_data, rs2_data => open, rs3_data => open,
            rd_addr_A    => rd_addr_A, rd_data_A => rd_data_A, write_mask_A => write_mask_A, we_A => we_A,
            rd_addr_B    => vrf_rd_addr_B, rd_data_B => vrf_rd_data_B, wr_addr_B => vrf_wr_addr_B,
            wr_data_B    => vrf_wr_data_B, write_mask_B => "1111", we_B => vrf_we_B
        );

    u_mcu : entity work.mcu_scatter_gather
        generic map ( WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk => clk, reset => reset, mem_op_valid => mem_op_valid, is_store => is_store,
            base_addr => base_addr, offset_reg_idx => offset_reg_idx, dest_src_reg_idx => dest_src_reg_idx,
            exec_mask => exec_mask, mem_stall => mem_stall, reg_read_addr => vrf_rd_addr_B,
            reg_read_data => vrf_rd_data_B, reg_write_addr => vrf_wr_addr_B, reg_write_data => vrf_wr_data_B,
            reg_write_en => vrf_we_B, cmd_valid => cmd_valid, cmd_is_store => cmd_is_store,
            cmd_addr => cmd_addr, cmd_burst_len => cmd_burst_len, cmd_ready => cmd_ready,
            tx_data => tx_data, tx_byte_en => tx_byte_en, tx_valid => tx_valid, tx_ready => tx_ready,
            rx_data => rx_data, rx_valid => rx_valid
        );

    u_bridge : entity work.avm_burst_bridge
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk => clk, reset => reset, cmd_valid => cmd_valid, cmd_is_store => cmd_is_store,
            cmd_addr => cmd_addr, cmd_burst_len => cmd_burst_len, cmd_ready => cmd_ready,
            tx_data => tx_data, tx_byte_en => tx_byte_en, tx_valid => tx_valid, tx_ready => tx_ready,
            rx_data => rx_data, rx_valid => rx_valid, avm_address => avm_address,
            avm_burstcount => avm_burstcount, avm_write => avm_write, avm_writedata => avm_writedata,
            avm_byteenable => avm_byteenable, avm_read => avm_read, avm_readdata => avm_readdata,
            avm_readdatavalid => avm_readdatavalid, avm_waitrequest => avm_waitrequest
        );

    u_memory : entity work.avm_sim_memory
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH, MAX_PENDING_READS => 8 )
        port map (
            clk => clk, reset => reset, avs_address => avm_address, avs_burstcount => avm_burstcount,
            avs_write => avm_write, avs_writedata => avm_writedata, avs_byteenable => avm_byteenable,
            avs_read => avm_read, avs_readdata => avm_readdata, avs_readdatavalid => avm_readdatavalid,
            avs_waitrequest => avm_waitrequest
        );

    -- ========================================================================
    -- MAIN STIMULUS PROCESS
    -- ========================================================================
    p_stim : process
        variable v_rx_caught : integer := 0;
    begin
        wait for 50 ns; wait until rising_edge(clk);
        reset <= '0';
        wait for 50 ns; wait until rising_edge(clk);
        report "--- STARTING FULL SYSTEM INTEGRATION TEST ---";

        -- --------------------------------------------------------------------
        -- TEST 1: PRE-LOAD & BASIC SCATTER/GATHER
        -- --------------------------------------------------------------------
        report "TEST 1: Pre-loading VRF: Thread Offsets (Reg 0) and Source Data (Reg 1)...";
        for i in 0 to WARP_SIZE - 1 loop
            rd_addr_A <= std_logic_vector(to_unsigned(i * 4 + 0, 7)); 
            rd_data_A(0) <= std_logic_vector(to_unsigned(i * 16, 32));
            rd_data_A(1) <= (others => '0'); rd_data_A(2) <= (others => '0'); rd_data_A(3) <= (others => '0');
            we_A <= '1'; wait until rising_edge(clk);
            
            rd_addr_A <= std_logic_vector(to_unsigned(i * 4 + 1, 7)); 
            rd_data_A(0) <= x"AAAA_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(1) <= x"BBBB_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(2) <= x"CCCC_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(3) <= x"DDDD_00" & std_logic_vector(to_unsigned(i, 8));
            we_A <= '1'; wait until rising_edge(clk);
        end loop;
        we_A <= '0'; wait for 50 ns; wait until rising_edge(clk);

        report "TEST 1: Triggering Full Vector Store (Reg 1 -> Memory 0x4000)...";
        base_addr <= x"00004000"; offset_reg_idx <= "00"; dest_src_reg_idx <= "01";
        is_store <= '1'; exec_mask <= (others => '1'); 
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop wait until rising_edge(clk); exit when mem_stall = '0'; end loop;

        report "TEST 1: Triggering Full Vector Load (Memory 0x4000 -> Reg 2)...";
        dest_src_reg_idx <= "10"; is_store <= '0'; 
        
        -- Safely count incoming RX pulses while waiting for mem_stall to drop
        v_rx_caught := 0;
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop 
            wait until rising_edge(clk);
            if rx_valid = '1' then v_rx_caught := v_rx_caught + 1; end if;
            exit when mem_stall = '0' and v_rx_caught = WARP_SIZE;
        end loop;
        
        -- Allow 4 cycles for the Port B write to propagate through your VRF collision FIFO
        wait for 40 ns; wait until rising_edge(clk);

        for i in 0 to WARP_SIZE - 1 loop
            rs1_addr <= std_logic_vector(to_unsigned(i * 4 + 2, 7));
            wait until rising_edge(clk); wait until rising_edge(clk);
            assert rs1_data(0) = x"AAAA_00" & std_logic_vector(to_unsigned(i, 8)) report "ERR" severity error;
        end loop;
        report "TEST 1: Basic Scatter/Gather Verified.";
        wait for 100 ns;

        -- --------------------------------------------------------------------
        -- TEST 2: THREAD MASKING & MEMORY OVERWRITE
        -- --------------------------------------------------------------------
        report "TEST 2: Loading 'Overwrite Data' into Register 3...";
        for i in 0 to WARP_SIZE - 1 loop
            rd_addr_A <= std_logic_vector(to_unsigned(i * 4 + 3, 7)); 
            rd_data_A(0) <= x"1111_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(1) <= x"2222_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(2) <= x"3333_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(3) <= x"4444_00" & std_logic_vector(to_unsigned(i, 8));
            we_A <= '1'; wait until rising_edge(clk);
        end loop;
        we_A <= '0'; wait for 50 ns; wait until rising_edge(clk);

        report "TEST 2: Triggering Masked Vector Store to SAME Base Address (0x4000) using 0x55555555 mask...";
        base_addr <= x"00004000"; offset_reg_idx <= "00"; dest_src_reg_idx <= "11"; -- Reg 3
        is_store <= '1'; exec_mask <= x"55555555"; -- Alternating threads active
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop wait until rising_edge(clk); exit when mem_stall = '0'; end loop;

        report "TEST 2: Reading back Full Vector (Unmasked) to verify Overwrite vs Preservation...";
        dest_src_reg_idx <= "10"; -- Overwrite Reg 2 with readback
        is_store <= '0'; exec_mask <= x"FFFFFFFF"; -- Read all threads
        
        v_rx_caught := 0;
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop 
            wait until rising_edge(clk);
            if rx_valid = '1' then v_rx_caught := v_rx_caught + 1; end if;
            exit when mem_stall = '0' and v_rx_caught = WARP_SIZE;
        end loop;
        wait for 40 ns; wait until rising_edge(clk);

        for i in 0 to WARP_SIZE - 1 loop
            rs1_addr <= std_logic_vector(to_unsigned(i * 4 + 2, 7));
            wait until rising_edge(clk); wait until rising_edge(clk);
            
            if (i mod 2) = 0 then
                assert rs1_data(0) = x"1111_00" & std_logic_vector(to_unsigned(i, 8)) report "OVERWRITE FAILED T" & integer'image(i) severity error;
                assert rs1_data(1) = x"2222_00" & std_logic_vector(to_unsigned(i, 8)) report "OVERWRITE FAILED T" & integer'image(i) severity error;
            else
                assert rs1_data(0) = x"AAAA_00" & std_logic_vector(to_unsigned(i, 8)) report "PRESERVATION FAILED T" & integer'image(i) severity error;
                assert rs1_data(1) = x"BBBB_00" & std_logic_vector(to_unsigned(i, 8)) report "PRESERVATION FAILED T" & integer'image(i) severity error;
            end if;
        end loop;
        report "TEST 2: Thread Masking Verified.";
        wait for 100 ns;

        -- --------------------------------------------------------------------
        -- TEST 3: RAPID SEQUENTIAL EXECUTION
        -- --------------------------------------------------------------------
        report "TEST 3: Rapid Back-to-Back Sequences (Write -> Write -> Read)...";
        
        -- Sequence 1: Write Reg 1 to 0x8000
        base_addr <= x"00008000"; offset_reg_idx <= "00"; dest_src_reg_idx <= "01"; is_store <= '1'; exec_mask <= x"FFFFFFFF";
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop wait until rising_edge(clk); exit when mem_stall = '0'; end loop;
        
        -- Sequence 2: Immediately Write Reg 3 to 0x9000
        base_addr <= x"00009000"; dest_src_reg_idx <= "11"; is_store <= '1'; 
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop wait until rising_edge(clk); exit when mem_stall = '0'; end loop;
        
        -- Sequence 3: Immediately Read 0x8000 back to Reg 2
        base_addr <= x"00008000"; dest_src_reg_idx <= "10"; is_store <= '0'; 
        
        v_rx_caught := 0;
        mem_op_valid <= '1'; wait until rising_edge(clk); mem_op_valid <= '0';
        loop 
            wait until rising_edge(clk);
            if rx_valid = '1' then v_rx_caught := v_rx_caught + 1; end if;
            exit when mem_stall = '0' and v_rx_caught = WARP_SIZE;
        end loop;
        wait for 40 ns; wait until rising_edge(clk);

        for i in 0 to WARP_SIZE - 1 loop
            rs1_addr <= std_logic_vector(to_unsigned(i * 4 + 2, 7));
            wait until rising_edge(clk); wait until rising_edge(clk);
            assert rs1_data(0) = x"AAAA_00" & std_logic_vector(to_unsigned(i, 8)) report "SEQ ERROR" severity error;
        end loop;
        
        report "--- ALL TESTS COMPLETED SUCCESSFULLY ---";
        std.env.stop;
    end process;
end architecture sim;
