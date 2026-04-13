library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_mcu_block_transfer is
end entity;

architecture sim of tb_mcu_block_transfer is
    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- MCU Control Signals
    signal pixel_buf_valid  : std_logic := '0';
    signal base_addr        : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal mem_stall        : std_logic;

    -- ==========================================
    -- M10K Pixel Buffer RAM Signals
    -- ==========================================
    -- Write port (driven by testbench to simulate warp threads)
    signal tb_pixel_we      : std_logic := '0';
    signal tb_pixel_wr_addr : std_logic_vector(4 downto 0) := (others => '0');
    signal tb_pixel_wr_data : word_t := (others => '0');

    -- Read port (driven by MCU)
    signal pixel_rd_en      : std_logic;
    signal pixel_rd_addr    : std_logic_vector(2 downto 0);
    signal pixel_rd_data    : std_logic_vector(DATA_WIDTH-1 downto 0);

    -- Avalon Bridge Command
    signal cmd_valid        : std_logic;
    signal cmd_is_store     : std_logic;
    signal cmd_addr         : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal cmd_burst_len    : std_logic_vector(7 downto 0);
    signal cmd_ready        : std_logic := '0';

    -- Avalon Bridge TX
    signal tx_data          : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal tx_byte_en       : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal tx_valid         : std_logic;
    signal tx_ready         : std_logic := '0';

begin
    clk <= not clk after CLK_PERIOD / 2;

    -- ========================================================================
    -- Instantiate the new mixed-width RAM
    -- ========================================================================
    u_pixel_buffer : entity work.pixel_buffer_ram
        port map (
            clk      => clk,
            -- Testbench "warp" write port
            we       => tb_pixel_we,
            wr_addr  => tb_pixel_wr_addr,
            wr_data  => tb_pixel_wr_data,
            -- MCU read port
            rd_en    => pixel_rd_en,
            rd_addr  => pixel_rd_addr,
            rd_data  => pixel_rd_data
        );

    -- ========================================================================
    -- Instantiate the MCU
    -- ========================================================================
    u_mcu : entity work.mcu_block_transfer
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk             => clk, 
            reset           => reset,
            pixel_buf_valid => pixel_buf_valid,
            base_addr       => base_addr,
            mem_stall       => mem_stall,
            
            -- Hook up the RAM read interface
            pixel_rd_en     => pixel_rd_en,
            pixel_rd_addr   => pixel_rd_addr,
            pixel_rd_data   => pixel_rd_data,
            
            cmd_valid       => cmd_valid, 
            cmd_is_store    => cmd_is_store, 
            cmd_addr        => cmd_addr,
            cmd_burst_len   => cmd_burst_len, 
            cmd_ready       => cmd_ready,
            
            tx_data         => tx_data, 
            tx_byte_en      => tx_byte_en, 
            tx_valid        => tx_valid,
            tx_ready        => tx_ready
        );

    process
    begin
        -- Reset
        wait for 2 * CLK_PERIOD;
        reset <= '0';
        wait for CLK_PERIOD;

        -- ====================================================================
        -- 1. Fill the M10K Pixel Buffer
        -- ====================================================================
        -- Simulate the warp execution unit writing 32 pixels over 32 clock cycles.
        -- Thread i gets packed pixel: i*4+3 (W) & i*4+2 (Z) & i*4+1 (Y) & i*4+0 (X).
        report "Pre-filling M10K pixel buffer...";
        for i in 0 to 31 loop
            tb_pixel_we      <= '1';
            tb_pixel_wr_addr <= std_logic_vector(to_unsigned(i, 5));
            tb_pixel_wr_data <= std_logic_vector(to_unsigned(
                (i*4+3) * 2**24 + (i*4+2) * 2**16 + (i*4+1) * 2**8 + (i*4+0), 32));
            wait until rising_edge(clk);
        end loop;
        
        -- Disable write enable after filling
        tb_pixel_we <= '0';
        wait until rising_edge(clk);
        report "Pixel buffer pre-filled!";

        -- ====================================================================
        -- 2. Trigger the MCU Block Transfer
        -- ====================================================================
        base_addr <= x"00001000";
        pixel_buf_valid <= '1';
        wait until rising_edge(clk);
        pixel_buf_valid <= '0';

        -- Verify that command is issued to the bridge
        report "Waiting for cmd_valid...";
        wait until cmd_valid = '1';
        report "Got cmd_valid!";
        cmd_ready <= '1';
        wait until rising_edge(clk);
        cmd_ready <= '0';

        -- ====================================================================
        -- 3. Simulate Avalon Bus Handshake
        -- ====================================================================
        -- Verify that 8 TX beats are pushed to the bridge
        report "Waiting for tx beats...";
        for i in 0 to 7 loop
            if tx_valid = '0' then
                wait until tx_valid = '1';
            end if;
            report "Got tx_valid beat " & integer'image(i);
            
            -- Accept the beat immediately
            tx_ready <= '1';
            wait until rising_edge(clk);
            tx_ready <= '0';
            
            -- Optional: Add a wait state here to test the pipeline freezing!
            -- wait until rising_edge(clk); 
        end loop;

        -- Wait a few cycles for mem_stall to clear
        for i in 0 to 5 loop
            wait until rising_edge(clk);
        end loop;

        assert mem_stall = '0' report "Mem stall not deasserted" severity failure;

        report "Simulation Completed Successfully." severity note;
        std.env.stop;
    end process;
end architecture sim;
