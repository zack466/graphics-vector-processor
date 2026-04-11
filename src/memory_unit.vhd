-- ============================================================================
-- COMPONENT: memory_unit
-- ============================================================================
-- PURPOSE:
--   Structural wrapper that composes the block transfer MCU
--   (mcu_block_transfer) and the Avalon burst bridge (avm_burst_bridge) into a
--   single, self-contained memory subsystem.  The wrapper exists for one
--   reason: to hide the internal AXI-stream-like handshake (cmd/tx/rx buses)
--   that connects the MCU to the bridge from the processor top level.  The
--   processor only needs to see three interface groups:
--     1. Processor-control signals (mem_op_valid / mem_stall, addressing).
--     2. Snooped data from Execution Unit
--     3. An Avalon-MM master port aimed at external DDR3 SDRAM.
--
-- INTERNAL TOPOLOGY:
--
--   [processor FSM]
--        |  mem_op_valid, base_addr, …
--        v
--   [ mcu_block_transfer ] <──> Execution Unit (snooped mem_store_*)
--        |   int_cmd_*  (command channel: address, burst length, direction)
--        |   int_tx_*   (write-data channel: data, byte-enable, valid/ready)
--        v
--   [ avm_burst_bridge ]
--        |   avm_* (Avalon-MM master to DDR3 controller)
--        v
--   [external DDR3]
--
--   The cmd/tx/rx buses form a lightweight custom AXI-stream-like interface
--   chosen because Avalon burst protocol is fiddly to implement in the MCU
--   directly (waitrequest back-pressure, burst beat counting).  Isolating
--   that complexity in the bridge keeps the MCU state machine clean.
--
-- HOW TO USE:
--   1. Assert mem_op_valid for exactly ONE clock cycle when the processor FSM
--      is in DECODE and has a MEM instruction.  The MCU latches the address
--      and register indices on that cycle.
--   2. Hold all control inputs (base_addr, etc.) stable from the
--      cycle mem_op_valid is asserted until mem_stall deasserts.
--   3. The processor FSM waits in MEM_WAIT until mem_stall deasserts.
--      Because mem_stall is driven combinationally by the MCU (asserts on
--      the same cycle as mem_op_valid), no bubble state is required between
--      DECODE and MEM_WAIT.
--
-- PORT DESCRIPTIONS:
--   clk               : System clock.  All registers are rising-edge.
--   reset             : Synchronous active-high reset.
--   mem_op_valid      : 1-cycle pulse from FSM DECODE state that starts a
--                       block store operation.  Latched internally.
--   base_addr         : 32-bit byte address.  Bits[31:16] come from the
--                       14-bit instruction immediate zero-extended to 16 bits,
--                       then placed in the upper half (bits[29:16] effective).
--                       This gives a 1 GB word-aligned addressing window.
--   dest_src_reg_idx  : Register holding the data to store.
--   exec_mask         : 32-bit active-thread mask from the IFU.  Threads with
--                       a '0' bit are masked out via Avalon byte enables.
--   mem_stall         : Asserted by MCU while the block store is in
--                       progress.  Deasserts when all data is written.
--   avm_*             : Standard Avalon-MM burst master signals to DDR3.
--
-- TIMING / LATENCY:
--   - mem_op_valid must be a single-cycle pulse; holding it longer will
--     re-trigger the MCU.
--   - mem_stall rises combinationally on the same cycle as mem_op_valid.
--   - Total latency depends on burst length and DDR3 waitrequest timing;
--     the MCU handles all back-pressure internally.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity memory_unit is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128;
        REG_WIDTH  : integer := 2
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Interface 1: Processor Control (From Issue/Decode)
        -- ==========================================
        mem_op_valid      : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        dest_src_reg_idx  : in  std_logic_vector(REG_WIDTH-1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        mem_store_valid   : in  std_logic;
        mem_store_thread  : in  std_logic_vector(4 downto 0);
        mem_store_data    : in  vector_t;

        -- ==========================================
        -- Interface 3: Avalon-MM Master (To External DDR3)
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
    -- Internal Interconnect Signals (MCU <-> Bridge)
    -- ========================================================================
    -- WHY a custom two-channel bus instead of Avalon directly in the MCU:
    --   Avalon burst requires the master to count beat cycles, respect
    --   waitrequest on EVERY beat, and not re-issue a new burst until the
    --   previous one completes.  Encoding all of that into the block-transfer
    --   state machine would couple memory-protocol concerns with pixel-packing
    --   logic.  Instead, the MCU issues a one-shot command (addr + burst length)
    --   on the cmd channel and streams data on tx; the bridge is solely
    --   responsible for the Avalon handshake.
    --
    -- cmd channel  : command/address phase.  cmd_valid/cmd_ready handshake.
    --                cmd_ready deasserts when bridge is busy with a prior burst.
    -- tx channel   : write-data phase for stores.  tx_valid/tx_ready handshake
    --                allows bridge to apply back-pressure if the DDR FIFO fills.
    -- NOTE: The bridge also exposes an rx channel for reads, but loads are not
    --       supported by the block-transfer MCU; int_rx_* are unused by the MCU.

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
    -- INSTANTIATE: Block Transfer MCU
    -- ========================================================================
    -- WHY mcu_block_transfer lives here rather than in the processor top level:
    --   The MCU snoops the execution unit's mem_store_* outputs to collect one
    --   pixel per thread as the barrel scheduler issues threads 0–31, then
    --   autonomously emits 8 sequential 128-bit Avalon burst beats.  The
    --   processor top level does not need to know about thread sequencing or
    --   pixel packing — it just waits for mem_stall='0'.  Wrapping here hides
    --   that detail behind a clean mem_op_valid / mem_stall handshake.
    u_mcu : entity work.mcu_block_transfer
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH,
            REG_WIDTH  => REG_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            -- Processor Control Interfaces
            mem_op_valid      => mem_op_valid,
            base_addr         => base_addr,
            dest_src_reg_idx  => dest_src_reg_idx,
            exec_mask         => exec_mask,
            mem_stall         => mem_stall,

            -- Snooped store data
            mem_store_valid   => mem_store_valid,
            mem_store_thread  => mem_store_thread,
            mem_store_data    => mem_store_data,

            -- Internal Bridge Interfaces
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
    -- WHY a separate bridge entity rather than inline Avalon logic in the MCU:
    --   The Avalon burst protocol (burstcount, waitrequest back-pressure on
    --   every beat, address-phase vs. data-phase timing) is non-trivial.
    --   Isolating it here means the MCU state machine only deals with its
    --   clean cmd/tx/rx channels, and the bridge only deals with Avalon
    --   compliance.  Either can be swapped independently (e.g., to target
    --   AXI instead of Avalon) without touching the other.
    u_bridge : entity work.avm_burst_bridge
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            -- Internal Bridge Interfaces
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

            -- External Avalon-MM Master Interfaces
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
