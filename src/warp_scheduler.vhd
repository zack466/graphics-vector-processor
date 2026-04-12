-- ============================================================================
-- COMPONENT: warp_scheduler
-- ============================================================================
-- PURPOSE:
--   Frame-level FSM that iterates warp_offset from 0 to (total_pixels - 1)
--   in steps of WARP_SIZE, driving a single warp_unit through every pixel
--   block needed to render a complete frame.  A single `frame_start` pulse
--   triggers the full iteration; `frame_done` pulses when the last warp
--   completes.
--
--   Designed for extensibility to multiple concurrent warps (latency hiding):
--   the warp_start / warp_halted ports are indexed arrays whose size is the
--   NUM_WARPS generic.  The single-warp instantiation uses NUM_WARPS=1.
--
-- FSM STATES:
--
--   IDLE       Wait for frame_start.  On entry: latch total_pixels =
--              frame_width * frame_height and reset next_offset = 0.
--
--   DISPATCH      Assert warp_start(0)='1' for exactly one cycle with
--                warp_offset(0) = next_offset.  Advance next_offset by WARP_SIZE.
--
--   WAIT_RUNNING  Wait for warp_halted(0)='0' (warp has started executing).
--                This state is necessary because warp_halted is still '1'
--                immediately after DISPATCH — the warp takes one or two cycles
--                to transition out of HALTED after warp_start fires.  Without
--                this state, WAIT_HALT would see the old '1' and exit instantly.
--
--   WAIT_HALT     Wait for warp_halted(0)='1' (warp FSM returned to HALTED
--                after OP_RETURN).  The warp's MEM_WAIT already blocks until
--                the full burst completes, so no separate MCU-done check is
--                needed.
--                - next_offset < total_pixels  → DISPATCH (next warp block)
--                - next_offset >= total_pixels → DONE
--
--   DONE          Assert frame_done='1' for one cycle; return to IDLE.
--
-- TIMING NOTES:
--   - frame_start must be a 1-cycle pulse; holding it will not re-trigger
--     the FSM while it is already running.
--   - warp_start is a 1-cycle pulse; the warp_unit latches warp_offset on
--     the same cycle.
--   - total_pixels is registered from frame_width * frame_height on the same
--     cycle frame_start is detected.  The multiply is a DSP-inferred unsigned
--     multiply (16×16 → 32 bits).
--   - frame_done is a 1-cycle pulse, not a level signal.
--
-- EXTENSION TO MULTIPLE WARPS (Change 3):
--   Set NUM_WARPS > 1.  The DISPATCH state should send warp_start to any idle
--   warp slot and WAIT_HALT should track which slots are done.  All internal
--   next_offset logic carries over unchanged.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity warp_scheduler is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;

        -- Frame control
        frame_start  : in  std_logic;   -- 1-cycle pulse: begin rendering a frame
        frame_width  : in  std_logic_vector(15 downto 0);  -- pixels per row
        frame_height : in  std_logic_vector(15 downto 0);  -- rows per frame
        frame_done   : out std_logic;   -- 1-cycle pulse: all warps completed

        -- Warp 0 control (NUM_WARPS=1 for now; extend to arrays for Change 3)
        warp_start   : out std_logic;
        warp_offset  : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        warp_halted  : in  std_logic;   -- '1' while warp FSM is in HALTED state

        -- Framebuffer addressing (passed through to warp_unit unchanged; future
        -- double-buffering logic will toggle this between two base addresses here)
        fb_base_addr : in  std_logic_vector(15 downto 0);  -- input from frame_processor
        fb_base_out  : out std_logic_vector(15 downto 0)   -- forwarded to warp_unit
    );
end entity warp_scheduler;

architecture rtl of warp_scheduler is

    type state_t is (IDLE, DISPATCH, WAIT_RUNNING, WAIT_HALT, DONE);
    signal state : state_t := IDLE;

    -- Total pixel count for the current frame (registered on frame_start)
    signal total_pixels : unsigned(31 downto 0) := (others => '0');

    -- Next warp offset to dispatch (increments by WARP_SIZE after each dispatch)
    signal next_offset  : unsigned(31 downto 0) := (others => '0');

begin

    -- Pass fb_base_addr through unchanged.  In a future double-buffering
    -- extension the scheduler would toggle between two addresses here.
    fb_base_out <= fb_base_addr;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state        <= IDLE;
                total_pixels <= (others => '0');
                next_offset  <= (others => '0');
                warp_start   <= '0';
                frame_done   <= '0';
                warp_offset  <= (others => '0');
            else
                -- Default outputs (overridden in specific states)
                warp_start <= '0';
                frame_done <= '0';

                case state is

                    when IDLE =>
                        if frame_start = '1' then
                            -- Latch frame dimensions and compute total pixel count.
                            -- 16-bit × 16-bit unsigned multiply → 32-bit result.
                            total_pixels <= unsigned(frame_width) * unsigned(frame_height);
                            next_offset <= (others => '0');
                            state <= DISPATCH;
                        end if;

                    when DISPATCH =>
                        -- Pulse warp_start for one cycle and drive warp_offset.
                        warp_start  <= '1';
                        warp_offset <= std_logic_vector(next_offset);
                        -- Advance offset so WAIT_HALT can check completion condition.
                        next_offset <= next_offset + to_unsigned(WARP_SIZE, 32);
                        state       <= WAIT_RUNNING;

                    when WAIT_RUNNING =>
                        -- Wait for warp_halted to deassert, confirming the warp
                        -- has started executing (transitioned out of HALTED).
                        -- Without this state, WAIT_HALT would see the residual '1'
                        -- from the previous HALTED state and exit instantly.
                        if warp_halted = '0' then
                            state <= WAIT_HALT;
                        end if;

                    when WAIT_HALT =>
                        -- Wait for the warp to finish (warp_halted reasserts on OP_RETURN).
                        if warp_halted = '1' then
                            if next_offset < total_pixels then
                                state <= DISPATCH;
                            else
                                state <= DONE;
                            end if;
                        end if;

                    when DONE =>
                        frame_done <= '1';
                        state      <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
