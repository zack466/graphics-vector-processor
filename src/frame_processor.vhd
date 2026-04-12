-- ============================================================================
-- COMPONENT: frame_processor
-- ============================================================================
-- PURPOSE:
--   Top-level structural entity that wires together every subsystem needed to
--   render a complete frame to DDR3 SDRAM from a single `frame_start` pulse.
--   No datapath logic lives here; this entity is pure wiring.
--
-- SUBSYSTEM MAP:
--   u_imem   : instruction_memory  — shared M10K BRAM; all warps run the same
--                                    shader program loaded via prog_* ports.
--   u_sched  : warp_scheduler      — frame-level FSM; iterates warp_offset from
--                                    0 to frame_width*frame_height in steps of 32.
--   u_warp   : warp_unit           — single SIMT warp (IFU, decode, issue, exec,
--                                    VRF, PRF, pixel snoop buffer).
--   u_mcu    : mcu_block_transfer  — accepts warp_unit's 1024-bit pixel buffer and
--                                    emits 8 sequential 128-bit Avalon burst beats.
--   u_bridge : avm_burst_bridge    — Avalon-MM burst protocol driver to DDR3.
--
-- TOPOLOGY:
--
--   [frame_start / frame_width / frame_height]
--        |
--   [u_sched: warp_scheduler]
--        |  warp_start, warp_offset
--        v
--   [u_warp: warp_unit] <──> [u_imem: instruction_memory]
--        |  pixel_buf_valid, pixel_buf_addr, pixel_buf_data, pixel_exec_mask
--        |  <── mem_stall ──
--        v
--   [u_mcu: mcu_block_transfer]
--        |  cmd/tx channels
--        v
--   [u_bridge: avm_burst_bridge]
--        |  avm_* (Avalon-MM master)
--        v
--   [DDR3 SDRAM]
--
-- EXTENSION TO MULTIPLE WARPS:
--   Instantiate N warp_unit entities and extend warp_scheduler to NUM_WARPS=N.
--   The MCU will need an arbiter to accept pixel buffers from multiple warps;
--   see todo.md (Change 3) for the full extension path.
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
--   frame_done        : 1-cycle pulse when all warps have completed.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity frame_processor is
    generic (
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
        -- Frame Control Interface
        -- ==========================================
        frame_start       : in  std_logic;
        frame_width       : in  std_logic_vector(15 downto 0);
        frame_height      : in  std_logic_vector(15 downto 0);
        frame_done        : out std_logic;

        -- Framebuffer base address: upper 16 bits of the DDR3 byte address used
        -- by the RETURN instruction.  Passed through warp_scheduler → warp_unit.
        -- Set to 0x0000 for a single framebuffer; alternate between 0x0000 and a
        -- second page address to implement double buffering with vsync later.
        fb_base_addr      : in  std_logic_vector(15 downto 0) := (others => '0')
    );
end entity frame_processor;

architecture structural of frame_processor is

    -- ========================================================================
    -- Internal Interconnect
    -- ========================================================================

    -- IMEM read port (warp_unit drives address, IMEM returns data)
    signal imem_rd_addr : std_logic_vector(PC_WIDTH-1 downto 0);
    signal imem_rd_data : std_logic_vector(31 downto 0);

    -- Scheduler → Warp
    signal sched_warp_start  : std_logic;
    signal sched_warp_offset : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal sched_fb_base     : std_logic_vector(15 downto 0); -- fb_base forwarded by scheduler
    signal warp_halted_sig   : std_logic;

    -- Warp → MCU
    signal warp_pixel_valid : std_logic;
    signal warp_pixel_addr  : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal warp_pixel_data  : std_logic_vector(1023 downto 0);
    signal warp_exec_mask   : std_logic_vector(WARP_SIZE-1 downto 0);

    -- MCU → Warp (back-pressure)
    signal mcu_mem_stall    : std_logic;

    -- MCU → Bridge (command channel)
    signal int_cmd_valid    : std_logic;
    signal int_cmd_is_store : std_logic;
    signal int_cmd_addr     : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal int_cmd_burst_len: std_logic_vector(7 downto 0);
    signal int_cmd_ready    : std_logic;

    -- MCU → Bridge (TX write-data channel)
    signal int_tx_data      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_tx_byte_en   : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal int_tx_valid     : std_logic;
    signal int_tx_ready     : std_logic;

    -- Bridge → MCU (RX read-data; unused since MCU only stores)
    signal int_rx_data      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_rx_valid     : std_logic;

begin

    -- ========================================================================
    -- Instruction Memory (shared; all warps run the same program)
    -- ========================================================================
    u_imem : entity work.instruction_memory
        generic map ( ADDR_WIDTH => IMEM_ADDR_WIDTH )
        port map (
            clk     => clk,
            we      => prog_we,
            wr_addr => prog_wr_addr,
            wr_data => prog_wr_data,
            rd_addr => imem_rd_addr(IMEM_ADDR_WIDTH-1 downto 0),
            rd_data => imem_rd_data
        );

    -- ========================================================================
    -- Warp Scheduler (frame-level FSM)
    -- ========================================================================
    u_sched : entity work.warp_scheduler
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH
        )
        port map (
            clk          => clk, reset => reset,
            frame_start  => frame_start,
            frame_width  => frame_width,
            frame_height => frame_height,
            frame_done   => frame_done,
            warp_start   => sched_warp_start,
            warp_offset  => sched_warp_offset,
            warp_halted  => warp_halted_sig,
            fb_base_addr => fb_base_addr,
            fb_base_out  => sched_fb_base
        );

    -- ========================================================================
    -- Warp Unit (single warp; extend to N for latency hiding)
    -- ========================================================================
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
            imem_addr       => imem_rd_addr,
            imem_data       => imem_rd_data,
            warp_start      => sched_warp_start,
            warp_offset     => sched_warp_offset,
            fb_base_addr    => sched_fb_base,
            warp_halted     => warp_halted_sig,
            warp_break      => open,
            pixel_buf_valid => warp_pixel_valid,
            pixel_buf_addr  => warp_pixel_addr,
            pixel_buf_data  => warp_pixel_data,
            pixel_exec_mask => warp_exec_mask,
            mem_stall       => mcu_mem_stall
        );

    -- ========================================================================
    -- Block Transfer MCU
    -- ========================================================================
    u_mcu : entity work.mcu_block_transfer
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk             => clk, reset => reset,
            pixel_buf_valid => warp_pixel_valid,
            base_addr       => warp_pixel_addr,
            exec_mask       => warp_exec_mask,
            mem_stall       => mcu_mem_stall,
            pixel_buf_data  => warp_pixel_data,
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
    -- Avalon Burst Bridge
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

end architecture structural;
