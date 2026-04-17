-- ============================================================================
-- COMPONENT: warp_scheduler
-- ============================================================================
-- PURPOSE:
--   Frame-level FSM that iterates warp_offset from 0 to (total_pixels - 1)
--   in steps of WARP_SIZE, dispatching pixel blocks to NUM_WARPS concurrent
--   warp_unit instances.  A single `frame_start` pulse triggers the full
--   iteration; `frame_done` pulses when all warps have halted.
--
--   The scheduler maximises throughput by dispatching to any idle warp every
--   clock cycle.  If both warps are idle and work remains, it dispatches to
--   warp 0 on one cycle and warp 1 on the next (priority: lowest index first).
--
-- FSM STATES:
--
--   IDLE       Wait for frame_start.  On entry: latch total_pixels =
--              frame_width * frame_height and reset next_offset = 0.
--
--   RUNNING    Each cycle:
--              1. Clear disp_pending(i) when warp_halted(i) deasserts, meaning
--                 the warp has acknowledged the dispatch and is now running.
--              2. If next_offset < total_pixels, scan for the first warp where
--                 warp_halted(i)='1' AND disp_pending(i)='0'.  Dispatch to it:
--                 assert warp_start(i) for one cycle, latch warp_offset(i),
--                 advance next_offset by WARP_SIZE, set disp_pending(i)='1'.
--              3. If next_offset >= total_pixels AND all warp_halted='1' AND
--                 all disp_pending='0': transition to DONE.
--
--   DONE       Assert frame_done='1' for one cycle; return to IDLE.
--
-- DISPATCH ARBITRATION:
--   Priority scan: warp 0 is tried before warp 1 (before warp 2, ...).
--   Because the scan only dispatches one warp per cycle, back-to-back dispatch
--   to different warps happens on consecutive cycles without any gap.
--
-- PENDING TRACKING (disp_pending):
--   After a warp_start pulse, warp_halted(i) may remain '1' for 1-2 cycles
--   while the warp_unit's FSM exits HALTED.  Without disp_pending, the
--   scheduler would see warp_halted(i)='1' and try to dispatch the same warp
--   again.  disp_pending(i) is set on dispatch and cleared when warp_halted(i)
--   first deasserts, preventing double-dispatch.
--
-- COMPLETION:
--   DONE is entered only when next_offset >= total_pixels AND all warp slots
--   are confirmed idle (halted=1, pending=0).  This guarantees every pixel
--   block that was dispatched has fully completed before frame_done fires.
--
-- TIMING NOTES:
--   - frame_start must be a 1-cycle pulse; the FSM ignores it while RUNNING.
--   - warp_start(i) is a 1-cycle pulse; the warp_unit latches warp_offset(i)
--     on the same rising edge.
--   - total_pixels is registered from frame_width * frame_height on the cycle
--     frame_start is detected.  The multiply is DSP-inferred (16×16 → 32 bits).
--   - frame_done is a 1-cycle pulse, not a level signal.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity warp_scheduler is
    generic (
        NUM_WARPS  : integer := 2;  -- Number of concurrent warp units
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

        -- Per-warp control (arrays of size NUM_WARPS)
        warp_start   : out std_logic_vector(NUM_WARPS-1 downto 0);       -- 1-cycle dispatch pulse per warp
        warp_offset  : out slv32_array_t(0 to NUM_WARPS-1);              -- pixel base offset for each warp
        warp_halted  : in  std_logic_vector(NUM_WARPS-1 downto 0);       -- '1' while warp FSM is HALTED

        -- Framebuffer base address forwarded to warp_unit unchanged
        fb_base_addr : in  std_logic_vector(15 downto 0);
        fb_base_out  : out std_logic_vector(15 downto 0)
    );
end entity warp_scheduler;

architecture rtl of warp_scheduler is

    type state_t is (IDLE, RUNNING, DONE);
    signal state : state_t := IDLE;

    -- Total pixel count for the current frame (registered on frame_start)
    signal total_pixels  : unsigned(31 downto 0) := (others => '0');

    -- Next warp offset to dispatch (increments by WARP_SIZE after each dispatch)
    signal next_offset   : unsigned(31 downto 0) := (others => '0');

    -- disp_pending(i): set when warp i has been dispatched but has not yet
    -- deasserted warp_halted (i.e., it hasn't transitioned out of HALTED yet).
    -- Prevents the scheduler from dispatching the same warp twice in a row.
    signal disp_pending  : std_logic_vector(NUM_WARPS-1 downto 0) := (others => '0');

    -- Registered per-warp offset outputs
    signal warp_offset_reg : slv32_array_t(0 to NUM_WARPS-1) := (others => (others => '0'));

begin

    -- Pass fb_base_addr through unchanged.
    fb_base_out <= fb_base_addr;

    -- Drive warp_offset output from the registered array
    gen_offset: for i in 0 to NUM_WARPS-1 generate
        warp_offset(i) <= warp_offset_reg(i);
    end generate;

    process(clk)
        variable v_all_done  : std_logic;     -- '1' when all warps are idle and work is done
        variable v_sel       : integer range 0 to NUM_WARPS-1; -- selected warp for dispatch
        variable v_dispatched: boolean;        -- true once a warp is dispatched this cycle
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state        <= IDLE;
                total_pixels <= (others => '0');
                next_offset  <= (others => '0');
                disp_pending <= (others => '0');
                warp_start   <= (others => '0');
                frame_done   <= '0';
                for i in 0 to NUM_WARPS-1 loop
                    warp_offset_reg(i) <= (others => '0');
                end loop;
            else
                -- Default pulse outputs
                warp_start <= (others => '0');
                frame_done <= '0';

                case state is

                    when IDLE =>
                        if frame_start = '1' then
                            total_pixels <= unsigned(frame_width) * unsigned(frame_height);
                            next_offset  <= (others => '0');
                            disp_pending <= (others => '0');
                            state        <= RUNNING;
                        end if;

                    when RUNNING =>
                        -- Step 1: Clear disp_pending for any warp that has started running.
                        -- Once warp_halted deasserts the warp has left HALTED, confirming
                        -- it received its dispatch.
                        for i in 0 to NUM_WARPS-1 loop
                            if warp_halted(i) = '0' then
                                disp_pending(i) <= '0';
                            end if;
                        end loop;

                        -- Step 2: If work remains, find the first idle warp and dispatch.
                        -- An idle warp has halted='1' and no pending dispatch.
                        v_dispatched := false;
                        if next_offset < total_pixels then
                            for i in 0 to NUM_WARPS-1 loop
                                if not v_dispatched and
                                   warp_halted(i) = '1' and disp_pending(i) = '0' then
                                    warp_start(i)      <= '1';
                                    warp_offset_reg(i) <= std_logic_vector(next_offset);
                                    next_offset        <= next_offset +
                                                         to_unsigned(WARP_SIZE, 32);
                                    disp_pending(i)    <= '1';
                                    v_dispatched       := true;
                                end if;
                            end loop;
                        end if;

                        -- Step 3: Check for frame completion.
                        -- All work is dispatched and every warp has halted (with no
                        -- pending dispatch that could still be in-flight).
                        v_all_done := '1';
                        for i in 0 to NUM_WARPS-1 loop
                            -- A warp is not done if it is currently running (halted='0')
                            -- or if it was dispatched but hasn't acknowledged yet.
                            if warp_halted(i) = '0' or disp_pending(i) = '1' then
                                v_all_done := '0';
                            end if;
                        end loop;
                        if next_offset >= total_pixels and v_all_done = '1' then
                            state <= DONE;
                        end if;

                    when DONE =>
                        frame_done <= '1';
                        state      <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
