-- ============================================================================
-- TESTBENCH: tb_mcu_block_transfer
-- ============================================================================
-- PURPOSE:
--   Validates mcu_block_transfer in single-warp mode (NUM_WARPS=1).
--   Fills a pixel_buffer_ram with known data, drives pixel_buf_valid(0)='1'
--   as a level signal (held high until pixel_buf_done(0) pulses), then
--   simulates the Avalon handshake and verifies that 8 TX beats are emitted.
--
-- NOTE on pixel_buf_valid:
--   In the multi-warp design, pixel_buf_valid is a level signal held '1'
--   until pixel_buf_done pulses.  This testbench holds the signal high for
--   the full duration of the transfer and deasserts it on the done cycle.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_mcu_block_transfer is
end entity;

architecture sim of tb_mcu_block_transfer is

    constant NUM_WARPS  : integer := 1; -- single-warp unit test
    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- MCU Control Signals (arrays of size 1)
    signal pixel_buf_valid  : std_logic_vector(NUM_WARPS-1 downto 0) := (others => '0');
    signal base_addr        : slv32_array_t(0 to NUM_WARPS-1) := (others => (others => '0'));
    signal pixel_buf_done   : std_logic_vector(NUM_WARPS-1 downto 0);

    -- M10K Pixel Buffer RAM Signals
    signal tb_pixel_we      : std_logic := '0';
    signal tb_pixel_wr_addr : std_logic_vector(4 downto 0) := (others => '0');
    signal tb_pixel_wr_data : word_t := (others => '0');

    -- MCU → RAM read interface (arrays of size 1)
    signal pixel_rd_en      : std_logic_vector(NUM_WARPS-1 downto 0);
    signal pixel_rd_addr    : slv3_array_t(0 to NUM_WARPS-1);
    signal pixel_rd_data    : slv128_array_t(0 to NUM_WARPS-1);

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
    -- Pixel Buffer RAM (warp 0's buffer)
    -- ========================================================================
    u_pixel_buffer : entity work.pixel_buffer_ram
        port map (
            clk     => clk,
            we      => tb_pixel_we,
            wr_addr => tb_pixel_wr_addr,
            wr_data => tb_pixel_wr_data,
            rd_en   => pixel_rd_en(0),
            rd_addr => pixel_rd_addr(0),
            rd_data => pixel_rd_data(0)
        );

    -- ========================================================================
    -- MCU Block Transfer (NUM_WARPS=1 for this unit test)
    -- ========================================================================
    u_mcu : entity work.mcu_block_transfer
        generic map (
            NUM_WARPS  => NUM_WARPS,
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk             => clk,
            reset           => reset,
            pixel_buf_valid => pixel_buf_valid,
            base_addr       => base_addr,
            pixel_buf_done  => pixel_buf_done,
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
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- 1. Fill the M10K Pixel Buffer (simulate warp execution unit)
        -- ====================================================================
        report "Pre-filling M10K pixel buffer...";
        for i in 0 to 31 loop
            tb_pixel_we      <= '1';
            tb_pixel_wr_addr <= std_logic_vector(to_unsigned(i, 5));
            tb_pixel_wr_data <= std_logic_vector(to_unsigned(
                (i*4+3) * 2**24 + (i*4+2) * 2**16 + (i*4+1) * 2**8 + (i*4+0), 32));
            wait until rising_edge(clk);
        end loop;
        tb_pixel_we <= '0';
        wait until rising_edge(clk);
        report "Pixel buffer pre-filled!";

        -- ====================================================================
        -- 2. Assert pixel_buf_valid as a level signal and trigger MCU
        -- ====================================================================
        base_addr(0)       <= x"00001000";
        pixel_buf_valid(0) <= '1';  -- hold high until pixel_buf_done

        -- Verify command is issued to the bridge
        report "Waiting for cmd_valid...";
        wait until cmd_valid = '1';
        report "Got cmd_valid!";
        cmd_ready <= '1';
        wait until rising_edge(clk);
        cmd_ready <= '0';

        -- ====================================================================
        -- 3. Simulate Avalon Bus Handshake (8 beats)
        -- ====================================================================
        report "Waiting for tx beats...";
        for i in 0 to 7 loop
            if tx_valid = '0' then
                wait until tx_valid = '1';
            end if;
            report "Got tx_valid beat " & integer'image(i);
            tx_ready <= '1';
            wait until rising_edge(clk);
            tx_ready <= '0';
        end loop;

        -- Deassert valid once MCU signals done
        wait until pixel_buf_done(0) = '1';
        pixel_buf_valid(0) <= '0';
        report "pixel_buf_done received, transfer complete.";

        -- Wait for idle
        for i in 0 to 5 loop wait until rising_edge(clk); end loop;

        report "tb_mcu_block_transfer: PASSED" severity note;
        std.env.stop;
    end process;

end architecture sim;
