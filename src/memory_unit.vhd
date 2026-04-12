-- ============================================================================
-- COMPONENT: memory_unit
-- ============================================================================
-- PURPOSE:
--   Structural wrapper that composes the block transfer MCU
--   (mcu_block_transfer) and the Avalon burst bridge (avm_burst_bridge) into a
--   single, self-contained memory subsystem.  The wrapper exists for one
--   reason: to hide the internal AXI-stream-like handshake (cmd/tx buses)
--   that connects the MCU to the bridge from the processor top level.  The
--   processor only needs to see three interface groups:
--     1. Processor-control signals (mem_op_valid / mem_stall, addressing).
--     2. Snooped data from the Execution Unit (collected here and packed into
--        a flat 1024-bit buffer before being handed to mcu_block_transfer).
--     3. An Avalon-MM master port aimed at external DDR3 SDRAM.
--
-- PIXEL SNOOP BUFFER:
--   mcu_block_transfer no longer contains a snoop buffer — it expects a
--   pre-packed flat 1024-bit pixel buffer on its pixel_buf_data port.  This
--   wrapper owns the snoop buffer: it accumulates one packed pixel per thread
--   as the execution unit issues mem_store_* events during EXEC_WAIT, then
--   concatenates them into a flat vector and passes it to the MCU alongside
--   the pixel_buf_valid trigger (= mem_op_valid from the processor FSM).
--
-- INTERNAL TOPOLOGY:
--
--   [processor FSM]
--        |  mem_op_valid, base_addr, exec_mask
--        v
--   [pixel snoop buffer]  <── Execution Unit (snooped mem_store_*)
--        |   int_pixel_buf_data (1024-bit flat)
--        |   int_pixel_buf_valid (= mem_op_valid)
--        v
--   [ mcu_block_transfer ]
--        |   int_cmd_*  (command channel: address, burst length)
--        |   int_tx_*   (write-data channel: data, byte-enable, valid/ready)
--        v
--   [ avm_burst_bridge ]
--        |   avm_* (Avalon-MM master to DDR3 controller)
--        v
--   [external DDR3]
--
-- HOW TO USE:
--   1. Assert mem_op_valid for exactly ONE clock cycle when the processor FSM
--      is in EXEC_WAIT and the issuer has finished all 32 threads.  The snoop
--      buffer must already be fully populated at this point (execution unit
--      writeback for all 32 threads has completed during EXEC_WAIT).
--   2. mem_stall rises on the same cycle as mem_op_valid (combinational in
--      the MCU).  The processor FSM waits in MEM_WAIT until mem_stall deasserts.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity memory_unit is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Interface 1: Processor Control (From Issue/Decode)
        -- ==========================================
        mem_op_valid      : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        -- Snooped store data (from execution unit writeback during EXEC_WAIT)
        mem_store_valid   : in  std_logic;
        mem_store_thread  : in  std_logic_vector(4 downto 0);
        mem_store_data    : in  vector_t;

        -- ==========================================
        -- Interface 2: Avalon-MM Master (To External DDR3)
        -- ==========================================
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_byteenable    : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avm_read          : out std_logic;
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic
    );
end entity;

architecture struct of memory_unit is

    -- ========================================================================
    -- Pixel Snoop Buffer
    -- ========================================================================
    -- WHY here rather than in mcu_block_transfer: mcu_block_transfer now
    -- accepts a pre-packed flat buffer (pixel_buf_data) to keep its interface
    -- clean for use in warp_unit as well.  This wrapper holds the snoop
    -- buffer on behalf of processor.vhd, which continues to expose the raw
    -- execution-unit snoop signals to this wrapper.
    type snoop_buf_t is array(0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal snoop_buf          : snoop_buf_t := (others => (others => '0'));
    signal int_pixel_buf_data : std_logic_vector(1023 downto 0);

    -- ========================================================================
    -- Internal Interconnect Signals (MCU <-> Bridge)
    -- ========================================================================
    signal int_cmd_valid     : std_logic;
    signal int_cmd_is_store  : std_logic;
    signal int_cmd_addr      : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal int_cmd_burst_len : std_logic_vector(7 downto 0);
    signal int_cmd_ready     : std_logic;

    signal int_tx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_tx_byte_en    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal int_tx_valid      : std_logic;
    signal int_tx_ready      : std_logic;

    signal int_rx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_rx_valid      : std_logic;

begin

    -- ========================================================================
    -- Pixel Snoop Buffer Write Port
    -- ========================================================================
    -- Accumulates one packed pixel per thread as the execution unit issues
    -- mem_store_* events during EXEC_WAIT.  Packing:
    --   pixel = W[7:0] & Z[7:0] & Y[7:0] & X[7:0]
    -- The buffer is not cleared between warps — old pixels are overwritten
    -- each time the 32-thread issue sequence runs.
    process(clk)
    begin
        if rising_edge(clk) then
            if mem_store_valid = '1' then
                snoop_buf(to_integer(unsigned(mem_store_thread))) <=
                    mem_store_data(3)(7 downto 0) &
                    mem_store_data(2)(7 downto 0) &
                    mem_store_data(1)(7 downto 0) &
                    mem_store_data(0)(7 downto 0);
            end if;
        end if;
    end process;

    -- Flatten snoop_buf into a 1024-bit vector for mcu_block_transfer.
    -- int_pixel_buf_data[i*32+31 : i*32] = snoop_buf(i) = thread i's pixel.
    gen_flat : for i in 0 to WARP_SIZE-1 generate
        int_pixel_buf_data(i*32+31 downto i*32) <= snoop_buf(i);
    end generate;

    -- ========================================================================
    -- INSTANTIATE: Block Transfer MCU
    -- ========================================================================
    u_mcu : entity work.mcu_block_transfer
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            pixel_buf_valid   => mem_op_valid,
            base_addr         => base_addr,
            exec_mask         => exec_mask,
            mem_stall         => mem_stall,
            pixel_buf_data    => int_pixel_buf_data,

            cmd_valid         => int_cmd_valid,
            cmd_is_store      => int_cmd_is_store,
            cmd_addr          => int_cmd_addr,
            cmd_burst_len     => int_cmd_burst_len,
            cmd_ready         => int_cmd_ready,

            tx_data           => int_tx_data,
            tx_byte_en        => int_tx_byte_en,
            tx_valid          => int_tx_valid,
            tx_ready          => int_tx_ready
        );

    -- ========================================================================
    -- INSTANTIATE: Avalon Burst Bridge
    -- ========================================================================
    u_bridge : entity work.avm_burst_bridge
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            cmd_valid         => int_cmd_valid,
            cmd_is_store      => int_cmd_is_store,
            cmd_addr          => int_cmd_addr,
            cmd_burst_len     => int_cmd_burst_len,
            cmd_ready         => int_cmd_ready,

            tx_data           => int_tx_data,
            tx_byte_en        => int_tx_byte_en,
            tx_valid          => int_tx_valid,
            tx_ready          => int_tx_ready,

            rx_data           => int_rx_data,
            rx_valid          => int_rx_valid,

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

end architecture struct;
