-- ============================================================================
-- FILE: frame_processor.vhd
-- COMPONENT: frame_processor
-- ============================================================================
-- PURPOSE:
--   Top-level structural entity that wires together every subsystem needed to
--   render a complete frame to DDR3 SDRAM from a single `frame_start` pulse.
--   No datapath logic lives here; this entity is pure wiring and per-warp
--   synchronisation bookkeeping.
--
-- SUBSYSTEM MAP:
--   u_imem[i]  : instruction_memory  — one physical M10K BRAM copy per warp,
--                                      all receiving the same prog_* writes
--                                      simultaneously.  Giving each warp its
--                                      own IMEM copy avoids the 2-port M10K
--                                      limit when warps run at different PCs.
--   u_sched    : warp_scheduler      — frame-level FSM; dispatches WARP_SIZE-
--                                      pixel blocks to any idle warp in round-
--                                      robin order.
--   u_warp[i]  : warp_unit           — one SIMT warp per slot: IFU, decode,
--                                      issue, exec, VRF, PRF.  Each warp has
--                                      its own pixel buffer RAM (u_pbuf[i]).
--   u_pbuf[i]  : pixel_buffer_ram    — per-warp M10K pixel buffer.  Written by
--                                      warp_unit i via pixel_wr_* ports;
--                                      read by the MCU during burst transfer.
--   u_mcu      : mcu_block_transfer  — arbitrates across all NUM_WARPS pixel
--                                      buffers and emits 8 sequential 128-bit
--                                      Avalon burst beats for each.
--   u_bridge   : avm_burst_bridge    — Avalon-MM burst protocol driver to DDR3.
--
-- MULTI-WARP LATENCY HIDING:
--   Each warp transitions directly to HALTED as soon as it fills its pixel
--   buffer (no MEM_WAIT state).  The scheduler sees warp_halted immediately
--   and can dispatch the next pixel block while the MCU drains the filled
--   buffer in the background.
--
--   Each warp has a per-warp `pixel_buf_dirty` level signal managed here.
--   If a warp finishes its next block before the MCU has completed the previous
--   transfer, it stalls in DECODE until `pixel_buf_dirty` clears.
--
-- INSTRUCTION MEMORY REPLICATION:
--   All NUM_WARPS IMEM copies receive identical prog_* writes and therefore
--   hold the same shader program.  A single IMEM cannot serve multiple warps
--   at different PCs because M10K block RAMs have at most 2 independent ports.
--
-- PORT DESCRIPTIONS:
--   clk, reset        : System clock and synchronous active-high reset.
--   avm_*             : Avalon-MM master port to DDR3 controller.
--   prog_we           : Write-enable for instruction memory programming.
--   prog_wr_addr      : IMEM word address (IMEM_ADDR_WIDTH bits).
--   prog_wr_data      : 32-bit instruction word to write.
--   frame_start       : 1-cycle pulse from host to begin rendering a frame.
--   frame_width       : Frame width in pixels (16-bit unsigned).
--   frame_height      : Frame height in pixels (16-bit unsigned).
--   time_ms           : Elapsed time in milliseconds (shader uniform).
--   frame_done        : 1-cycle pulse when all warps have completed and all
--                       pixel transfers have finished.
--   fb_base_addr      : Upper 16 bits of DDR3 byte address used by RETURN.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity frame_processor is
    generic (
        NUM_WARPS       : integer := 2;   -- Number of concurrent warp units
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128;
        REG_WIDTH       : integer := 4
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Avalon-MM Master (To DDR3 via Burst Bridge)
        -- ==========================================
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_byteenable    : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avm_read          : out std_logic;
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic;

        -- ==========================================
        -- Instruction Memory Programming Interface
        -- ==========================================
        prog_we           : in  std_logic;
        prog_wr_addr      : in  std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0);
        prog_wr_data      : in  std_logic_vector(31 downto 0);

        -- ==========================================
        -- Frame Control & Uniform Interface
        -- ==========================================
        frame_start       : in  std_logic;
        frame_width       : in  std_logic_vector(15 downto 0);
        frame_height      : in  std_logic_vector(15 downto 0);
        time_ms           : in  std_logic_vector(31 downto 0) := (others => '0');
        frame_done        : out std_logic;

        -- Upper 16 bits of DDR3 byte address used by RETURN.
        fb_base_addr      : in  std_logic_vector(15 downto 0) := (others => '0')
    );
end entity frame_processor;

architecture structural of frame_processor is

    -- ========================================================================
    -- PER-WARP INTERCONNECT ARRAYS
    -- ========================================================================

    -- IMEM read interfaces (one per warp; same data in each copy)
    signal imem_rd_addr : slv16_array_t(0 to NUM_WARPS-1);
    signal imem_rd_data : slv32_array_t(0 to NUM_WARPS-1);

    -- Scheduler → per-warp control
    signal sched_warp_start  : std_logic_vector(NUM_WARPS-1 downto 0);
    signal sched_warp_offset : slv32_array_t(0 to NUM_WARPS-1);
    signal sched_fb_base     : std_logic_vector(15 downto 0);
    signal warp_halted_vec   : std_logic_vector(NUM_WARPS-1 downto 0);
    signal sched_frame_done  : std_logic;

    -- Per-warp pixel-buffer dirty flags (level: '1' while buffer awaits MCU)
    signal pixel_buf_dirty   : std_logic_vector(NUM_WARPS-1 downto 0) := (others => '0');
    signal mcu_pixel_done    : std_logic_vector(NUM_WARPS-1 downto 0);

    -- Per-warp pixel_buf_valid pulses from warp_unit
    signal warp_pixel_valid  : std_logic_vector(NUM_WARPS-1 downto 0);
    -- Per-warp DDR3 base addresses output by warp_unit
    signal warp_pixel_addr   : slv32_array_t(0 to NUM_WARPS-1);

    -- Per-warp pixel buffer WRITE interface (warp → pixel_buffer_ram)
    signal warp_pix_wr_en    : std_logic_vector(NUM_WARPS-1 downto 0);
    signal warp_pix_wr_addr  : slv5_array_t(0 to NUM_WARPS-1);
    signal warp_pix_wr_data  : slv32_array_t(0 to NUM_WARPS-1);

    -- Per-warp pixel buffer READ interface (MCU → pixel_buffer_ram)
    signal pix_rd_en         : std_logic_vector(NUM_WARPS-1 downto 0);
    signal pix_rd_addr       : slv3_array_t(0 to NUM_WARPS-1);
    signal pix_rd_data       : slv128_array_t(0 to NUM_WARPS-1);

    -- MCU → Bridge (command channel)
    signal int_cmd_valid     : std_logic;
    signal int_cmd_is_store  : std_logic;
    signal int_cmd_addr      : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal int_cmd_burst_len : std_logic_vector(7 downto 0);
    signal int_cmd_ready     : std_logic;

    -- MCU → Bridge (TX write-data channel)
    signal int_tx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_tx_byte_en    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal int_tx_valid      : std_logic;
    signal int_tx_ready      : std_logic;

    -- Bridge → MCU (RX read-data; unused since MCU only stores)
    signal int_rx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_rx_valid      : std_logic;

    -- Latched uniforms
    signal frame_width_reg   : std_logic_vector(15 downto 0);
    signal frame_height_reg  : std_logic_vector(15 downto 0);
    signal time_ms_reg       : std_logic_vector(31 downto 0);

    signal frame_done_pending : std_logic := '0';

begin

    -- ========================================================================
    -- UNIFORM LATCH & DIRTY-FLAG MANAGEMENT
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pixel_buf_dirty    <= (others => '0');
                frame_done_pending <= '0';
                frame_done         <= '0';
            else
                frame_done <= '0';

                -- Per-warp dirty flag: set when warp pulses pixel_buf_valid,
                -- cleared when the MCU completes the burst for that warp.
                for i in 0 to NUM_WARPS-1 loop
                    if warp_pixel_valid(i) = '1' then
                        pixel_buf_dirty(i) <= '1';
                    elsif mcu_pixel_done(i) = '1' then
                        pixel_buf_dirty(i) <= '0';
                    end if;
                end loop;

                -- Delay frame_done until all buffers have been flushed to DDR3.
                -- pixel_buf_dirty = "00" means all pending MCU transfers are done.
                if sched_frame_done = '1' then
                    frame_done_pending <= '1';
                end if;

                if frame_done_pending = '1' and
                   (pixel_buf_dirty = (pixel_buf_dirty'range => '0') or
                    mcu_pixel_done /= (mcu_pixel_done'range => '0')) then
                    frame_done         <= '1';
                    frame_done_pending <= '0';
                end if;
            end if;

            -- Latch uniforms to prevent glitches during active rendering
            frame_width_reg  <= frame_width;
            frame_height_reg <= frame_height;
            time_ms_reg      <= time_ms;
        end if;
    end process;

    -- ========================================================================
    -- WARP SCHEDULER
    -- ========================================================================
    u_sched : entity work.warp_scheduler
        generic map (
            NUM_WARPS  => NUM_WARPS,
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk          => clk, reset => reset,
            frame_start  => frame_start,
            frame_width  => frame_width,
            frame_height => frame_height,
            frame_done   => sched_frame_done,
            warp_start   => sched_warp_start,
            warp_offset  => sched_warp_offset,
            warp_halted  => warp_halted_vec,
            fb_base_addr => fb_base_addr,
            fb_base_out  => sched_fb_base
        );

    -- ========================================================================
    -- MCU BLOCK TRANSFER (Shared; arbitrates across all warp pixel buffers)
    -- ========================================================================
    u_mcu : entity work.mcu_block_transfer
        generic map (
            NUM_WARPS  => NUM_WARPS,
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk             => clk, reset => reset,
            pixel_buf_valid => pixel_buf_dirty,   -- level signal per warp
            base_addr       => warp_pixel_addr,
            pixel_buf_done  => mcu_pixel_done,
            pixel_rd_en     => pix_rd_en,
            pixel_rd_addr   => pix_rd_addr,
            pixel_rd_data   => pix_rd_data,
            cmd_valid       => int_cmd_valid,
            cmd_is_store    => int_cmd_is_store,
            cmd_addr        => int_cmd_addr,
            cmd_burst_len   => int_cmd_burst_len,
            cmd_ready       => int_cmd_ready,
            tx_data         => int_tx_data,
            tx_byte_en      => int_tx_byte_en,
            tx_valid        => int_tx_valid,
            tx_ready        => int_tx_ready
        );

    -- ========================================================================
    -- AVALON BURST BRIDGE
    -- ========================================================================
    u_bridge : entity work.avm_burst_bridge
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk, reset => reset,
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

    -- ========================================================================
    -- PER-WARP GENERATE BLOCK
    -- Instantiates one instruction_memory, one warp_unit, and one
    -- pixel_buffer_ram for each warp slot.  All IMEM copies receive the same
    -- prog_* writes and therefore hold the same shader program.
    -- ========================================================================
    gen_warps: for i in 0 to NUM_WARPS-1 generate

        -- ----------------------------------------------------------------
        -- Instruction Memory (one copy per warp; all hold the same program)
        -- ----------------------------------------------------------------
        u_imem : entity work.instruction_memory
            generic map ( ADDR_WIDTH => IMEM_ADDR_WIDTH )
            port map (
                clk     => clk,
                we      => prog_we,              -- broadcast to all copies
                wr_addr => prog_wr_addr,
                wr_data => prog_wr_data,
                rd_addr => imem_rd_addr(i)(IMEM_ADDR_WIDTH-1 downto 0),
                rd_data => imem_rd_data(i)
            );

        -- ----------------------------------------------------------------
        -- Warp Unit
        -- ----------------------------------------------------------------
        u_warp : entity work.warp_unit
            generic map (
                PC_WIDTH        => PC_WIDTH,
                IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
                WARP_SIZE       => WARP_SIZE,
                ADDR_WIDTH      => ADDR_WIDTH,
                DATA_WIDTH      => DATA_WIDTH,
                REG_WIDTH       => REG_WIDTH
            )
            port map (
                clk             => clk, reset => reset,
                imem_addr       => imem_rd_addr(i),
                imem_data       => imem_rd_data(i),
                warp_start      => sched_warp_start(i),
                warp_offset     => sched_warp_offset(i),
                fb_base_addr    => sched_fb_base,
                warp_halted     => warp_halted_vec(i),
                warp_break      => open,
                frame_width     => frame_width_reg,
                frame_height    => frame_height_reg,
                time_ms         => time_ms_reg,
                pixel_buf_valid => warp_pixel_valid(i),
                pixel_buf_addr  => warp_pixel_addr(i),
                pixel_buf_dirty => pixel_buf_dirty(i),
                pixel_wr_en     => warp_pix_wr_en(i),
                pixel_wr_addr   => warp_pix_wr_addr(i),
                pixel_wr_data   => warp_pix_wr_data(i)
            );

        -- ----------------------------------------------------------------
        -- Per-warp Pixel Buffer RAM (M10K)
        -- Write port: from warp_unit (32-bit × 32 entries)
        -- Read port:  from MCU (128-bit × 8 entries)
        -- ----------------------------------------------------------------
        u_pbuf : entity work.pixel_buffer_ram
            port map (
                clk     => clk,
                we      => warp_pix_wr_en(i),
                wr_addr => warp_pix_wr_addr(i),
                wr_data => warp_pix_wr_data(i),
                rd_en   => pix_rd_en(i),
                rd_addr => pix_rd_addr(i),
                rd_data => pix_rd_data(i)
            );

    end generate gen_warps;

end architecture structural;
