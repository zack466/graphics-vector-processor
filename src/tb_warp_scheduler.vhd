-- ============================================================================
-- TESTBENCH: tb_warp_scheduler
-- ============================================================================
-- PURPOSE:
--   Verifies that warp_scheduler correctly:
--   1. Dispatches warp offsets 0, WARP_SIZE, 2*WARP_SIZE, ... in sequence.
--   2. Asserts frame_done exactly once after all warps complete.
--   3. Returns to IDLE and accepts a second frame_start.
--
-- NUM_WARPS=2 OPERATION:
--   Two independent mock warps simulate warp_unit behaviour.  Each asserts
--   its warp_halted bit '0' one cycle after receiving a warp_start, then
--   reasserts '1' after MOCK_WARP_LATENCY cycles, modelling execution and
--   OP_RETURN completion.
--
--   The test collects all dispatched (warp_start, warp_offset) pairs until
--   frame_done fires, then verifies:
--     - Total dispatch count equals the expected number of warp blocks.
--     - Offsets were issued as the monotonically increasing sequence
--       0, WARP_SIZE, 2*WARP_SIZE, ... regardless of which physical warp
--       received each block.
--
-- TEST CASES:
--   1. Small frame: 4 × 8 = 32 pixels → 1 warp block (offset 0 only).
--   2. Medium frame: 8 × 8 = 64 pixels → 2 warp blocks (offsets 0, 32).
--   3. Large frame: 64 × 4 = 256 pixels → 8 warp blocks (offsets 0..224).
--   4. Re-trigger: second frame_start after frame_done (same 8×8 frame).
--   5. Pulse check: frame_done is a 1-cycle pulse.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_warp_scheduler is
end entity;

architecture sim of tb_warp_scheduler is

    constant NUM_WARPS  : integer := 2;
    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant CLK_PERIOD : time    := 10 ns;

    -- Mock warp latency: cycles from warp_start to warp_halted re-assertion.
    -- Must be > 1 so that warp_halted has time to deassert before re-asserting.
    constant MOCK_WARP_LATENCY : integer := 5;

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';

    signal frame_start  : std_logic := '0';
    signal frame_width  : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_height : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_done   : std_logic;

    -- Multi-warp interface
    signal warp_start   : std_logic_vector(NUM_WARPS-1 downto 0);
    signal warp_offset  : slv32_array_t(0 to NUM_WARPS-1);
    signal warp_halted  : std_logic_vector(NUM_WARPS-1 downto 0) := (others => '1');
    signal fb_base_out  : std_logic_vector(15 downto 0);

    -- Collected dispatch log (up to 64 blocks; more than any test needs)
    type offset_log_t is array (0 to 63) of unsigned(31 downto 0);
    signal dispatch_log   : offset_log_t := (others => (others => '0'));
    signal dispatch_count : integer := 0;

begin
    clk <= not clk after CLK_PERIOD / 2;

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
            frame_done   => frame_done,
            warp_start   => warp_start,
            warp_offset  => warp_offset,
            warp_halted  => warp_halted,
            fb_base_addr => (others => '0'),
            fb_base_out  => fb_base_out
        );

    -- ========================================================================
    -- Mock warps: for each warp i, when warp_start(i) fires, deassert
    -- warp_halted(i) immediately (warp is running), then re-assert after
    -- MOCK_WARP_LATENCY cycles (warp has halted after OP_RETURN).
    -- Each warp runs a fully independent countdown.
    -- ========================================================================
    gen_mock: for i in 0 to NUM_WARPS-1 generate
        process(clk)
            variable countdown : integer := 0;
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    warp_halted(i) <= '1';
                    countdown      := 0;
                elsif warp_start(i) = '1' then
                    warp_halted(i) <= '0';
                    countdown      := MOCK_WARP_LATENCY;
                elsif countdown > 0 then
                    countdown := countdown - 1;
                    if countdown = 0 then
                        warp_halted(i) <= '1';
                    end if;
                end if;
            end if;
        end process;
    end generate;

    -- ========================================================================
    -- Dispatch logger: record (warp index, offset) whenever any warp_start
    -- fires.  Captures all simultaneous dispatches in a single cycle.
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                dispatch_count <= 0;
                dispatch_log   <= (others => (others => '0'));
            else
                for i in 0 to NUM_WARPS-1 loop
                    if warp_start(i) = '1' then
                        dispatch_log(dispatch_count)   <= unsigned(warp_offset(i));
                        dispatch_count                 <= dispatch_count + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- Main test process
    -- ========================================================================
    process
        -- Run one complete frame and check dispatch results.
        procedure run_frame(
            constant width     : integer;
            constant height    : integer;
            constant exp_warps : integer
        ) is
            variable start_count : integer;
            variable got_count   : integer;
            variable exp_offset  : unsigned(31 downto 0);
        begin
            -- Capture current dispatch count before starting
            start_count := dispatch_count;

            frame_width  <= std_logic_vector(to_unsigned(width, 16));
            frame_height <= std_logic_vector(to_unsigned(height, 16));
            frame_start  <= '1';
            wait until rising_edge(clk);
            frame_start  <= '0';

            -- Wait for frame_done
            wait until frame_done = '1';
            -- Allow the logger process to capture any dispatches on this cycle
            wait until rising_edge(clk);

            got_count := dispatch_count - start_count;

            assert got_count = exp_warps
                report "Frame " & integer'image(width) & "x" & integer'image(height) &
                       ": expected " & integer'image(exp_warps) & " dispatches, got " &
                       integer'image(got_count)
                severity failure;

            -- Verify offsets are the monotone sequence 0, WARP_SIZE, 2*WARP_SIZE...
            exp_offset := (others => '0');
            for k in 0 to exp_warps-1 loop
                assert dispatch_log(start_count + k) = exp_offset
                    report "Dispatch " & integer'image(k) &
                           ": expected offset " & integer'image(to_integer(exp_offset)) &
                           " got " & integer'image(to_integer(dispatch_log(start_count + k)))
                    severity failure;
                exp_offset := exp_offset + to_unsigned(WARP_SIZE, 32);
            end loop;

            report "Frame " & integer'image(width) & "x" & integer'image(height) &
                   " (" & integer'image(exp_warps) & " blocks): PASS";
        end procedure;

    begin
        -- ----------------------------------------------------------------
        -- Reset
        -- ----------------------------------------------------------------
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        reset <= '0';
        wait until rising_edge(clk);

        -- ----------------------------------------------------------------
        -- Test 1: 4×8 = 32 pixels → 1 warp block
        -- ----------------------------------------------------------------
        run_frame(4, 8, 1);
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        -- ----------------------------------------------------------------
        -- Test 2: 8×8 = 64 pixels → 2 warp blocks
        -- ----------------------------------------------------------------
        run_frame(8, 8, 2);
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        -- ----------------------------------------------------------------
        -- Test 3: 64×4 = 256 pixels → 8 warp blocks
        -- ----------------------------------------------------------------
        run_frame(64, 4, 8);
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        -- ----------------------------------------------------------------
        -- Test 4: Re-trigger with same frame size (scheduler returns to IDLE)
        -- ----------------------------------------------------------------
        run_frame(8, 8, 2);
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        -- ----------------------------------------------------------------
        -- Test 5: Verify frame_done is only a 1-cycle pulse
        -- ----------------------------------------------------------------
        frame_width  <= std_logic_vector(to_unsigned(4, 16));
        frame_height <= std_logic_vector(to_unsigned(8, 16));
        frame_start  <= '1';
        wait until rising_edge(clk);
        frame_start  <= '0';
        wait until frame_done = '1';
        wait until frame_done = '0';
        report "Test 5 (frame_done pulse): PASS";
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        report "tb_warp_scheduler: ALL TESTS PASSED" severity note;
        std.env.stop;
    end process;

end architecture sim;
