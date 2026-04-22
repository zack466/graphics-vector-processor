-- ============================================================================
-- FILE: frame_processor.vhd
-- COMPONENT: Frame Processor
-- ============================================================================
-- 
-- The fully integrated frame processor that computes pixels based on a shader
-- program and writes it to a framebuffer in memory. Does not contain any logic,
-- but rather wires together all the necessary sub-components.
--
-- Inputs:
--  - clk, reset    : system clock and synchronous active-high reset.
--  - prog_we       : Write-enable for instruction memory programming.
--  - prog_wr_addr  : IMEM word address (IMEM_ADDR_WIDTH bits).
--  - prog_wr_data  : 32-bit instruction word to write.
--  - frame_width   : Frame width in pixels (16-bit unsigned).
--  - frame_height  : Frame height in pixels (16-bit unsigned).
--  - time_ms       : Elapsed time in milliseconds (shader uniform).
--  - frame_start   : 1-cycle pulse from host to begin rendering a frame.
--
-- Outputs:
--   avm_*      : Avalon-MM 128-bit interface to DDR3 RAM.
--   frame_done : 1-cycle pulse when all warps have completed.
--
-- Entities:
--   u_imem   : instruction_memory  - shared M10K SRAM; contains the current shader
--                                    program in machine code. Written to via
--                                    prog_* ports.
--   u_sched  : warp_scheduler      - frame-level FSM; iterates warp_offset from
--                                    0 to frame_width*frame_height in steps of 32
--                                    and triggers warps (32 threads each).
--   u_warp   : warp_unit           - single SIMT warp (IFU, decode, issue, exec,
--                                    VRF, PRF). Writes output pixels to
--                                    a internal pixel buffer.
--   u_mcu    : mcu_block_transfer  - Fetches pixels from the warp's pixel buffer and
--                                    emits 8 sequential 128-bit Avalon burst beats
--                                    to write it entirely to RAM. Since all pixels
--                                    are adjacent, we automatically get coalescing.
--   u_bridge : avm_burst_bridge    - Bridges the block transfer memory controller
--                                    to the Avalon-MM interface using a state
--                                    machine (simplifies the MCU write interface).
--   u_pixel_buffer : pixel_buffer_ram - stores a single warp's output pixels in a
--                                       32 x 32 = 1024 bit buffer so the values
--                                       can be easily bursted to DDR3 RAM.
--
-- Future work: The current design should be modular enough that we can instantiate
-- more warp units to do work in parallel. The warp scheduler and MCU just need to
-- modified to support multiple warps through an arbiter or two. And of course,
-- the design also still needs to fit onto the FPGA being used.
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity frame_processor is
    generic (
        PC_WIDTH        : integer := 16;    -- width of program counter
        IMEM_ADDR_WIDTH : integer := 8;     -- instruction memory address width (256 instructions max)
        WARP_SIZE       : integer := 32;    -- number of threads per warp
        ADDR_WIDTH      : integer := 32;    -- SDRAM address width
        DATA_WIDTH      : integer := 128;   -- SDRAM data width
        REG_WIDTH       : integer := 4      -- width of vector register file (16 registers)
    );
    port (
        clk               : in  std_logic;  -- system clock
        reset             : in  std_logic;  -- system reset

        -- ==========================================
        -- Avalon-MM Master to DDR3 RAM, used for framebuffer writes
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
        -- Frame Control
        -- ==========================================
        frame_start       : in  std_logic;  -- pulsed to trigger for drawing a single frame
        frame_done        : out std_logic;  -- pulsed to signal done drawing a frame

        -- ==========================================
        -- Shader Uniforms
        -- ==========================================
        frame_width       : in  std_logic_vector(15 downto 0);
        frame_height      : in  std_logic_vector(15 downto 0);
        time_ms           : in  std_logic_vector(31 downto 0) := (others => '0');

        -- Framebuffer base address: upper 16 bits of the DDR3 byte address used
        -- by the RETURN instruction.
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
    signal warp_halted_sig   : std_logic;
    signal sched_frame_done  : std_logic;

    -- Pixel Buffer State, used to arbitrate with block transfer MCU
    signal pixel_buf_dirty    : std_logic := '0';
    signal mcu_pixel_done     : std_logic;

    -- Warp ↔ MCU Handshake and RAM interface
    signal warp_pixel_valid   : std_logic;
    signal warp_pixel_addr    : std_logic_vector(ADDR_WIDTH-1 downto 0);
    
    -- Pixel Buffer Write Interface (from warp)
    signal warp_pixel_wr_en   : std_logic;
    signal warp_pixel_wr_addr : std_logic_vector(4 downto 0);
    signal warp_pixel_wr_data : std_logic_vector(31 downto 0);
    
    -- Pixel Buffer Read Interface (from MCU)
    signal warp_pixel_rd_en   : std_logic;
    signal warp_pixel_rd_addr : std_logic_vector(2 downto 0);
    signal warp_pixel_rd_data : std_logic_vector(DATA_WIDTH-1 downto 0);

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

    -- Uniform registers
    signal frame_width_reg   : std_logic_vector(15 downto 0);
    signal frame_height_reg  : std_logic_vector(15 downto 0);
    signal time_ms_reg       : std_logic_vector(31 downto 0);

    signal frame_done_pending : std_logic := '0';

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pixel_buf_dirty    <= '0';
                frame_done_pending <= '0';
                frame_done         <= '0';
            else
                frame_done <= '0';

                if warp_pixel_valid = '1' then
                    -- pixel buffer is ready to be output to memory
                    pixel_buf_dirty <= '1';
                elsif mcu_pixel_done = '1' then
                    -- pixel buffer has been written to memory, ready for a new frame
                    pixel_buf_dirty <= '0';
                end if;

                if sched_frame_done = '1' then
                    -- warp scheduler has finished dispatching all warps
                    frame_done_pending <= '1';
                end if;

                if frame_done_pending = '1' and (pixel_buf_dirty = '0' or mcu_pixel_done = '1') then
                    -- frame is done being drawn
                    frame_done <= '1';
                    frame_done_pending <= '0';
                end if;
            end if;
            
            -- Latch in uniforms to prevent issues if they happen to change
            -- while the processor is running.
            frame_width_reg  <= frame_width;
            frame_height_reg <= frame_height;
            time_ms_reg      <= time_ms;
        end if;
    end process;

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
            frame_done   => sched_frame_done,
            warp_start   => sched_warp_start,
            warp_offset  => sched_warp_offset,
            warp_halted  => warp_halted_sig
        );

    -- ========================================================================
    -- Warp Unit (single warp; extend to N for latency hiding)
    -- ========================================================================
    u_warp : entity work.warp_unit
        generic map (
            PC_WIDTH        => PC_WIDTH,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => WARP_SIZE,
            REG_WIDTH       => REG_WIDTH
        )
        port map (
            clk             => clk, reset => reset,
            imem_addr       => imem_rd_addr,
            imem_data       => imem_rd_data,
            warp_start      => sched_warp_start,
            warp_offset     => sched_warp_offset,
            fb_base_addr    => fb_base_addr,
            warp_halted     => warp_halted_sig,
            warp_break      => open,
            
            -- Shader uniforms
            frame_width     => frame_width_reg,
            frame_height    => frame_height_reg,
            time_ms         => time_ms_reg,
            
            -- pixel buffer interface
            pixel_buf_valid => warp_pixel_valid,
            pixel_buf_addr  => warp_pixel_addr,
            pixel_buf_dirty => pixel_buf_dirty,
            
            -- write port to pixel buffer
            pixel_wr_en     => warp_pixel_wr_en,
            pixel_wr_addr   => warp_pixel_wr_addr,
            pixel_wr_data   => warp_pixel_wr_data
        );

    -- ========================================================================
    -- Central Pixel Buffer RAM (M10K)
    -- ========================================================================
    u_pixel_buffer : entity work.pixel_buffer_ram
        port map (
            clk      => clk,
            we       => warp_pixel_wr_en,
            wr_addr  => warp_pixel_wr_addr,
            wr_data  => warp_pixel_wr_data,
            rd_en    => warp_pixel_rd_en,
            rd_addr  => warp_pixel_rd_addr,
            rd_data  => warp_pixel_rd_data
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
            pixel_buf_done  => mcu_pixel_done,
            pixel_rd_en     => warp_pixel_rd_en,
            pixel_rd_addr   => warp_pixel_rd_addr,
            pixel_rd_data   => warp_pixel_rd_data,
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
