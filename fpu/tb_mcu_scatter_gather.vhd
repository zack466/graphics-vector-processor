library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


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

    -- ========================================================================
    -- INSTANTIATE 1: Vector Register File (VRF)
    -- ========================================================================
    u_vrf : entity work.vector_reg_file
        generic map ( ADDR_WIDTH => 7 )
        port map (
            clk          => clk,
            reset        => reset,
            
            -- Port A (Driven by Testbench to load/verify data)
            rs1_addr     => rs1_addr,
            rs2_addr     => (others => '0'),
            rs3_addr     => (others => '0'),
            rs1_data     => rs1_data,
            rs2_data     => open,
            rs3_data     => open,
            rd_addr_A    => rd_addr_A,
            rd_data_A    => rd_data_A,
            write_mask_A => write_mask_A,
            we_A         => we_A,

            -- Port B (Driven by MCU)
            rd_addr_B    => vrf_rd_addr_B,
            rd_data_B    => vrf_rd_data_B,
            wr_addr_B    => vrf_wr_addr_B,
            wr_data_B    => vrf_wr_data_B,
            write_mask_B => "1111", -- MCU always writes full 128-bit vector
            we_B         => vrf_we_B
        );

    -- ========================================================================
    -- INSTANTIATE 2: Scatter/Gather MCU
    -- ========================================================================
    u_mcu : entity work.mcu_scatter_gather
        generic map ( WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk               => clk,
            reset             => reset,
            mem_op_valid      => mem_op_valid,
            is_store          => is_store,
            base_addr         => base_addr,
            offset_reg_idx    => offset_reg_idx,
            dest_src_reg_idx  => dest_src_reg_idx,
            exec_mask         => exec_mask,
            mem_stall         => mem_stall,

            reg_read_addr     => vrf_rd_addr_B,
            reg_read_data     => vrf_rd_data_B,
            reg_write_addr    => vrf_wr_addr_B,
            reg_write_data    => vrf_wr_data_B,
            reg_write_en      => vrf_we_B,

            cmd_valid         => cmd_valid,
            cmd_is_store      => cmd_is_store,
            cmd_addr          => cmd_addr,
            cmd_burst_len     => cmd_burst_len,
            cmd_ready         => cmd_ready,
            tx_data           => tx_data,
            tx_byte_en        => tx_byte_en,
            tx_valid          => tx_valid,
            tx_ready          => tx_ready,
            rx_data           => rx_data,
            rx_valid          => rx_valid
        );

    -- ========================================================================
    -- INSTANTIATE 3: Avalon Burst Bridge
    -- ========================================================================
    u_bridge : entity work.avm_burst_bridge
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
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
            rx_data           => rx_data,
            rx_valid          => rx_valid,

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
    -- INSTANTIATE 4: Simulated DDR3 Slave
    -- ========================================================================
    u_memory : entity work.avm_sim_memory
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH, MAX_PENDING_READS => 8 )
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
    -- MAIN STIMULUS PROCESS
    -- ========================================================================
    p_stim : process
    begin
        -- 1. Initialize
        wait for 50 ns;
        wait until rising_edge(clk);
        reset <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        
        report "--- STARTING FULL SYSTEM INTEGRATION TEST ---";

        -- --------------------------------------------------------------------
        -- STEP 1: Pre-load the VRF via Port A
        -- --------------------------------------------------------------------
        report "Pre-loading VRF: Thread Offsets (Reg 0) and Source Data (Reg 1)...";
        for i in 0 to WARP_SIZE - 1 loop
            -- Load Offset into Register 0 (Used for addressing)
            -- We make the offsets contiguous (each thread is +0x10 bytes ahead)
            -- This ensures the MCU will successfully coalesce all 32 threads into a single burst!
            rd_addr_A <= std_logic_vector(to_unsigned(i * 4 + 0, 7)); 
            rd_data_A(0) <= std_logic_vector(to_unsigned(i * 16, 32));
            rd_data_A(1) <= (others => '0');
            rd_data_A(2) <= (others => '0');
            rd_data_A(3) <= (others => '0');
            we_A <= '1';
            wait until rising_edge(clk);
            
            -- Load Test Data into Register 1 (Used for the Store test)
            -- We give each thread recognizable distinct data.
            rd_addr_A <= std_logic_vector(to_unsigned(i * 4 + 1, 7)); 
            rd_data_A(0) <= x"AAAA_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(1) <= x"BBBB_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(2) <= x"CCCC_00" & std_logic_vector(to_unsigned(i, 8));
            rd_data_A(3) <= x"DDDD_00" & std_logic_vector(to_unsigned(i, 8));
            we_A <= '1';
            wait until rising_edge(clk);
        end loop;
        we_A <= '0';
        wait for 50 ns; wait until rising_edge(clk);

        -- --------------------------------------------------------------------
        -- STEP 2: Trigger MCU Memory Store (Scatter to Memory)
        -- --------------------------------------------------------------------
        report "Triggering MCU Vector Store (Reg 1 -> Memory 0x4000)...";
        base_addr        <= x"00004000";
        offset_reg_idx   <= "00"; -- Use Reg 0 for offsets
        dest_src_reg_idx <= "01"; -- Use Reg 1 for source data
        is_store         <= '1';
        exec_mask        <= (others => '1'); -- All 32 threads active
        
        mem_op_valid <= '1';
        wait until rising_edge(clk);
        mem_op_valid <= '0';
        
        -- Wait for the MCU to completely finish the 32-word coalesced write
        loop
            wait until rising_edge(clk);
            exit when mem_stall = '0';
        end loop;
        report "MCU Vector Store Completed.";
        wait for 50 ns; wait until rising_edge(clk);

        -- --------------------------------------------------------------------
        -- STEP 3: Trigger MCU Memory Load (Gather from Memory)
        -- --------------------------------------------------------------------
        report "Triggering MCU Vector Load (Memory 0x4000 -> Reg 2)...";
        -- We will load the data we just wrote back into a NEW register (Reg 2)
        base_addr        <= x"00004000";
        offset_reg_idx   <= "00"; -- Still use Reg 0 for offsets
        dest_src_reg_idx <= "10"; -- Dump incoming data into Reg 2!
        is_store         <= '0';
        
        mem_op_valid <= '1';
        wait until rising_edge(clk);
        mem_op_valid <= '0';
        
        loop
            wait until rising_edge(clk);
            exit when mem_stall = '0';
        end loop;
        report "MCU Vector Load Completed. Checking VRF for data integrity...";

        -- --------------------------------------------------------------------
        -- STEP 4: Verify the Round-Trip Data in the VRF
        -- --------------------------------------------------------------------
        for i in 0 to WARP_SIZE - 1 loop
            -- Read Register 2 for Thread i via Port A
            rs1_addr <= std_logic_vector(to_unsigned(i * 4 + 2, 7));
            wait until rising_edge(clk); 
            wait until rising_edge(clk); -- 1-cycle latency on the VRF read
            
            assert rs1_data(0) = x"AAAA_00" & std_logic_vector(to_unsigned(i, 8))
                report "DATA MISMATCH on Thread " & integer'image(i) & " Element 0" severity error;
            assert rs1_data(1) = x"BBBB_00" & std_logic_vector(to_unsigned(i, 8))
                report "DATA MISMATCH on Thread " & integer'image(i) & " Element 1" severity error;
            assert rs1_data(2) = x"CCCC_00" & std_logic_vector(to_unsigned(i, 8))
                report "DATA MISMATCH on Thread " & integer'image(i) & " Element 2" severity error;
            assert rs1_data(3) = x"DDDD_00" & std_logic_vector(to_unsigned(i, 8))
                report "DATA MISMATCH on Thread " & integer'image(i) & " Element 3" severity error;
        end loop;

        report "--- ALL DATA VERIFIED SUCCESSFULLY ---";
        std.env.stop;

    end process;
end architecture sim;
