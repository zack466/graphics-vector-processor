-- ============================================================================
-- COMPONENT: mcu_block_transfer
-- ============================================================================
-- PURPOSE:
--   Memory Control Unit for warp-wide block stores.  Arbitrates across
--   NUM_WARPS pixel buffers and bursts each full buffer to DDR3 via the
--   Avalon burst bridge.
--
--   Each warp_unit has a dedicated M10K pixel_buffer_ram at the frame_processor
--   level.  When a warp fills its buffer it asserts pixel_buf_valid(i)='1'
--   (a level signal held until pixel_buf_done(i) is pulsed).  The MCU scans
--   the valid bits in IDLE using round-robin arbitration, selects one warp,
--   then reads its pixel buffer and emits 8 sequential 128-bit Avalon beats.
--
-- ARBITRATION:
--   A simple round-robin arbiter scans pixel_buf_valid starting from rr_next
--   (the warp after the one most recently served).  On each IDLE visit, at
--   most one warp is selected; the others are served in subsequent IDLE passes.
--
-- M10K READ PIPELINE:
--   The pixel_buffer_ram has a 1-cycle registered-read latency.  To keep the
--   Avalon data stream flowing, the MCU issues the read for beat k+1 in the
--   same cycle that beat k is accepted by the bridge.  tx_ready from the bridge
--   gates both the RAM read and the TX data advance, so if the bridge stalls
--   the RAM pipeline freezes in place and no beat is lost.
--
--   Prefetch beat 0:  In IDLE, as soon as a valid warp is detected, rd_en(i)
--   is asserted for that warp with rd_addr=0.  By the time STORE_CMD exits
--   (cmd_ready accepted), beat 0 is already latched in the RAM output register.
--
-- PORT DESCRIPTIONS:
--   pixel_buf_valid(i) : Level signal from frame_processor; '1' while warp i's
--                        pixel buffer is full and waiting for transfer.
--   base_addr(i)       : Computed DDR3 byte address for warp i's pixel block.
--   pixel_buf_done(i)  : 1-cycle pulse after warp i's burst is fully accepted.
--   pixel_rd_en(i)     : Read-enable for warp i's M10K pixel_buffer_ram.
--   pixel_rd_addr(i)   : 3-bit beat address (0-7) for warp i's RAM read port.
--   pixel_rd_data(i)   : 128-bit data word returned from warp i's RAM.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity mcu_block_transfer is
    generic (
        NUM_WARPS  : integer := 2;   -- Number of warp pixel buffers to arbitrate
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- Per-warp pixel buffer control (level signals: held '1' until done)
        pixel_buf_valid   : in  std_logic_vector(NUM_WARPS-1 downto 0);
        base_addr         : in  slv32_array_t(0 to NUM_WARPS-1);
        pixel_buf_done    : out std_logic_vector(NUM_WARPS-1 downto 0);

        -- Per-warp M10K pixel_buffer_ram read interface
        pixel_rd_en       : out std_logic_vector(NUM_WARPS-1 downto 0);
        pixel_rd_addr     : out slv3_array_t(0 to NUM_WARPS-1);
        pixel_rd_data     : in  slv128_array_t(0 to NUM_WARPS-1);

        -- Avalon Burst Bridge Command Channel
        cmd_valid         : out std_logic;
        cmd_is_store      : out std_logic;
        cmd_addr          : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : out std_logic_vector(7 downto 0);
        cmd_ready         : in  std_logic;

        -- Avalon Burst Bridge TX Channel (Writes)
        tx_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        tx_byte_en        : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        tx_valid          : out std_logic;
        tx_ready          : in  std_logic
    );
end entity;

architecture rtl of mcu_block_transfer is

    type state_t is (IDLE, STORE_CMD, STORE_BURST);
    signal state : state_t := IDLE;

    -- Latched destination address for the current burst
    signal latched_base_addr : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');

    -- Which warp is currently being served
    signal selected_warp : integer range 0 to NUM_WARPS-1 := 0;

    -- Round-robin start index: next burst will prefer this warp index
    signal rr_next : integer range 0 to NUM_WARPS-1 := 0;

    signal cmd_valid_reg : std_logic := '0';
    signal tx_valid_reg  : std_logic := '0';

    -- tx_count: number of beats accepted by the Avalon bridge.
    -- rd_count: number of beats requested from the selected warp's M10K RAM.
    signal tx_count : integer range 0 to 7 := 0;
    signal rd_count : integer range 0 to 7 := 0;

    -- Combinational: which warp to serve next (round-robin priority)
    signal arb_valid : std_logic;                         -- '1' if any warp is ready
    signal arb_sel   : integer range 0 to NUM_WARPS-1;   -- selected warp index

begin

    -- ========================================================================
    -- ROUND-ROBIN ARBITER (Combinational)
    -- ========================================================================
    -- Scan from rr_next, wrapping around, to find the first warp with a valid
    -- pixel buffer.  arb_valid goes '1' and arb_sel holds the chosen index.
    process(pixel_buf_valid, rr_next)
        variable v_found : boolean;
        variable v_idx   : integer range 0 to NUM_WARPS-1;
    begin
        arb_valid <= '0';
        arb_sel   <= 0;
        v_found   := false;
        for j in 0 to NUM_WARPS-1 loop
            if not v_found then
                v_idx := (rr_next + j) mod NUM_WARPS;
                if pixel_buf_valid(v_idx) = '1' then
                    arb_sel   <= v_idx;
                    arb_valid <= '1';
                    v_found   := true;
                end if;
            end if;
        end loop;
    end process;

    -- ========================================================================
    -- FIXED OUTPUT ASSIGNMENTS
    -- ========================================================================
    cmd_valid     <= cmd_valid_reg;
    cmd_is_store  <= '1';
    cmd_addr      <= latched_base_addr;
    cmd_burst_len <= std_logic_vector(to_unsigned(8, 8)); -- 8 beats = 32 pixels

    tx_valid      <= tx_valid_reg;
    tx_data       <= pixel_rd_data(selected_warp);        -- mux from selected warp's RAM

    tx_byte_en    <= (others => '1');                     -- all byte lanes valid

    -- ========================================================================
    -- PIXEL RAM READ CONTROL (Combinational)
    -- ========================================================================
    -- Only the selected (or about-to-be-selected) warp's RAM is read.
    -- All other warps' rd_en are '0' and their rd_addr is "000".
    --
    -- In IDLE: if the arbiter found a valid warp, prefetch beat 0 so it is
    --   ready by the time STORE_CMD sends the Avalon command.
    -- In STORE_CMD: when cmd_ready is accepted, advance to beat 1.
    -- In STORE_BURST: advance on each tx_ready acceptance.
    process(state, arb_valid, arb_sel, selected_warp,
            cmd_valid_reg, cmd_ready, tx_valid_reg, tx_ready, rd_count)
        variable v_warp : integer range 0 to NUM_WARPS-1;
        variable v_en   : std_logic;
        variable v_addr : std_logic_vector(2 downto 0);
    begin
        -- Default: all disabled
        pixel_rd_en  <= (others => '0');
        pixel_rd_addr <= (others => "000");

        case state is
            when IDLE =>
                -- Prefetch beat 0 from the warp the arbiter chose this cycle
                if arb_valid = '1' then
                    pixel_rd_en(arb_sel)  <= '1';
                    pixel_rd_addr(arb_sel) <= "000";
                end if;

            when STORE_CMD =>
                -- Advance to beat 1 when the command is accepted
                if cmd_ready = '1' and cmd_valid_reg = '1' then
                    pixel_rd_en(selected_warp)   <= '1';
                    pixel_rd_addr(selected_warp) <= std_logic_vector(to_unsigned(1, 3));
                end if;

            when STORE_BURST =>
                -- Advance read pipeline one beat ahead of TX so data is ready
                if tx_ready = '1' and tx_valid_reg = '1' then
                    pixel_rd_en(selected_warp)   <= '1';
                    pixel_rd_addr(selected_warp) <=
                        std_logic_vector(to_unsigned(rd_count, 3));
                end if;
        end case;
    end process;

    -- ========================================================================
    -- FSM SEQUENTIAL LOGIC
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state            <= IDLE;
                cmd_valid_reg    <= '0';
                tx_valid_reg     <= '0';
                pixel_buf_done   <= (others => '0');
                tx_count         <= 0;
                rd_count         <= 0;
                selected_warp    <= 0;
                rr_next          <= 0;
                latched_base_addr <= (others => '0');
            else
                -- Default: clear completion pulses
                pixel_buf_done <= (others => '0');

                case state is

                    when IDLE =>
                        -- Arbiter picked a warp; latch its address and start
                        if arb_valid = '1' then
                            selected_warp     <= arb_sel;
                            latched_base_addr <= base_addr(arb_sel);
                            -- Advance round-robin pointer past the selected warp
                            rr_next           <= (arb_sel + 1) mod NUM_WARPS;
                            rd_count          <= 0;
                            tx_count          <= 0;
                            cmd_valid_reg     <= '1';
                            state             <= STORE_CMD;
                        end if;

                    when STORE_CMD =>
                        if cmd_ready = '1' and cmd_valid_reg = '1' then
                            cmd_valid_reg <= '0';
                            tx_valid_reg  <= '1';
                            -- Beat 0 is already latching inside the RAM this cycle.
                            -- Advance rd_count to fetch beat 1 next cycle.
                            rd_count      <= 1;
                            state         <= STORE_BURST;
                        end if;

                    when STORE_BURST =>
                        -- Pipeline advances only when the Avalon bridge accepts the beat
                        if tx_ready = '1' and tx_valid_reg = '1' then
                            if tx_count = 7 then
                                -- Burst complete: clear TX, signal done, return to IDLE
                                tx_valid_reg               <= '0';
                                pixel_buf_done(selected_warp) <= '1';
                                state                      <= IDLE;
                            else
                                tx_count <= tx_count + 1;
                                -- Cap rd_count at 7 to prevent rolling over the RAM bound
                                if rd_count < 7 then
                                    rd_count <= rd_count + 1;
                                end if;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
