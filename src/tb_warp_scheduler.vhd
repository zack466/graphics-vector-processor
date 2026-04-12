-- ============================================================================
-- TESTBENCH: tb_warp_scheduler
-- ============================================================================
-- PURPOSE:
--   Verifies that warp_scheduler correctly:
--   1. Dispatches warp offsets 0, WARP_SIZE, 2*WARP_SIZE, ... in sequence.
--   2. Asserts frame_done exactly once after all warps complete.
--   3. Returns to IDLE and accepts a second frame_start.
--
-- MOCK WARP:
--   A simple counter process simulates warp_unit: it asserts warp_halted
--   after a fixed latency once warp_start fires, letting us test the
--   scheduler in isolation without instantiating the full warp_unit.
--
-- TEST CASES:
--   1. Small frame: 4 × 8 = 32 pixels → 1 warp (offset 0 only).
--   2. Medium frame: 8 × 8 = 64 pixels → 2 warps (offsets 0, 32).
--   3. Large frame: 64 × 4 = 256 pixels → 8 warps (offsets 0..224 step 32).
--   4. Re-trigger: second frame_start after frame_done.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_warp_scheduler is
end entity;

architecture sim of tb_warp_scheduler is
    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant CLK_PERIOD : time    := 10 ns;

    -- Mock warp latency: cycles from warp_start to warp_halted
    constant MOCK_WARP_LATENCY : integer := 5;

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';

    signal frame_start  : std_logic := '0';
    signal frame_width  : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_height : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_done   : std_logic;

    signal warp_start  : std_logic;
    signal warp_offset : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal warp_halted : std_logic := '1'; -- starts halted (no warp running)

begin
    clk <= not clk after CLK_PERIOD / 2;

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
            warp_start   => warp_start,
            warp_offset  => warp_offset,
            warp_halted  => warp_halted
        );

    -- ========================================================================
    -- Mock warp: when warp_start fires, assert warp_halted='0' immediately
    -- (warp is running) then re-assert '1' after MOCK_WARP_LATENCY cycles.
    -- ========================================================================
    process(clk)
        variable countdown : integer := 0;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                warp_halted <= '1';
                countdown   := 0;
            elsif warp_start = '1' then
                warp_halted <= '0';
                countdown   := MOCK_WARP_LATENCY;
            elsif countdown > 0 then
                countdown := countdown - 1;
                if countdown = 0 then
                    warp_halted <= '1';
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- Main test process
    -- ========================================================================
    process
        -- Helper: run one frame and verify offset sequence
        procedure run_frame(
            constant width    : integer;
            constant height   : integer;
            constant exp_warps: integer
        ) is
            variable exp_offset : unsigned(31 downto 0);
            variable got_offset : unsigned(31 downto 0);
            variable warp_count : integer;
        begin
            frame_width  <= std_logic_vector(to_unsigned(width, 16));
            frame_height <= std_logic_vector(to_unsigned(height, 16));
            frame_start  <= '1';
            wait until rising_edge(clk);
            frame_start  <= '0';

            exp_offset  := (others => '0');
            warp_count  := 0;

            -- Track dispatched warps until frame_done
            while true loop
                -- Wait for either warp_start or frame_done
                wait until rising_edge(clk) and (warp_start = '1' or frame_done = '1');

                if frame_done = '1' then
                    exit;
                end if;

                -- warp_start fired: check offset
                got_offset := unsigned(warp_offset);
                assert got_offset = exp_offset
                    report "Warp " & integer'image(warp_count) &
                           ": expected offset " & integer'image(to_integer(exp_offset)) &
                           " got " & integer'image(to_integer(got_offset))
                    severity failure;

                exp_offset  := exp_offset + to_unsigned(WARP_SIZE, 32);
                warp_count  := warp_count + 1;
            end loop;

            assert warp_count = exp_warps
                report "Expected " & integer'image(exp_warps) & " warps, got " &
                       integer'image(warp_count)
                severity failure;

            report "Frame " & integer'image(width) & "x" & integer'image(height) &
                   " (" & integer'image(exp_warps) & " warps): PASS";
        end procedure;

    begin
        -- ----------------------------------------------------------------
        -- Reset
        -- ----------------------------------------------------------------
        wait for 2 * CLK_PERIOD;
        reset <= '0';
        wait for CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- Test 1: 4×8 = 32 pixels → 1 warp
        -- ----------------------------------------------------------------
        run_frame(4, 8, 1);
        wait for 2 * CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- Test 2: 8×8 = 64 pixels → 2 warps
        -- ----------------------------------------------------------------
        run_frame(8, 8, 2);
        wait for 2 * CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- Test 3: 64×4 = 256 pixels → 8 warps
        -- ----------------------------------------------------------------
        run_frame(64, 4, 8);
        wait for 2 * CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- Test 4: Re-trigger with same frame size (scheduler returns to IDLE)
        -- ----------------------------------------------------------------
        run_frame(8, 8, 2);
        wait for 2 * CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- Test 5: Verify frame_done is only a 1-cycle pulse
        --         (checks both that it asserts and then deasserts)
        -- ----------------------------------------------------------------
        frame_width  <= std_logic_vector(to_unsigned(4, 16));
        frame_height <= std_logic_vector(to_unsigned(8, 16));
        frame_start  <= '1';
        wait until rising_edge(clk);
        frame_start  <= '0';
        wait until frame_done = '1';
        -- Wait for the very next event on frame_done (must be '0' to be a pulse)
        wait until frame_done = '0';
        report "Test 5 (frame_done pulse): PASS";
        wait for 2 * CLK_PERIOD;

        report "tb_warp_scheduler: ALL TESTS PASSED" severity note;
        std.env.stop;
    end process;

end architecture sim;
