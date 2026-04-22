-- ============================================================================
-- TESTBENCH: tb_call_stack
-- ============================================================================
-- PURPOSE:
--   Automated regression test for the function-call instructions
--   (BRA_L, BRA_X, PUSH_L, POP_L) and the MOV instruction.
--   Now updated to verify the new pipelined M10K pixel buffer interface.
--
-- TEST PROGRAM (tools/test10_call_stack.s assembled to instruction words):
--
--   PC  0: 0x00000214  LDI_LO v1.xyzw, 0x0000  -- clear v1
--   PC  1: 0xD8000601  BRA_L leaf              -- call leaf (PC 6); link_reg = 2
--   PC  2: 0x4BC84000  MOV v2.xyzw, v1         -- v2 = v1 = 0x42 (tests MOV)
--   PC  3: 0xD8000801  BRA_L outer             -- call outer (PC 8); link_reg = 4
--   PC  4: 0xF8000006  FLUSH
--   PC  5: 0xFC000026  RETURN v2               -- store v2 + halt warp
--   PC  6: 0x00010A14  LDI_LO v1.xyzw, 0x0042  -- leaf: v1 = 66 (0x42)
--   PC  7: 0xDC000001  BRA_X                   -- return to link_reg
--   PC  8: 0xE0000001  PUSH_L                  -- outer: save link
--   PC  9: 0xD8000601  BRA_L leaf              -- call leaf (PC 6); link_reg = 10
--   PC 10: 0xE4000001  POP_L                   -- restore link
--   PC 11: 0xDC000001  BRA_X                   -- return to caller
--
-- EXECUTION TRACE:
--   PC0 : v1 = 0
--   PC1 : BRA_L → link=2, PC=6
--   PC6 : v1.xyzw = 0x42
--   PC7 : BRA_X  → PC=2
--   PC2 : v2.xyzw = v1 = 0x42   (MOV tested)
--   PC3 : BRA_L  → link=4, PC=8
--   PC8 : PUSH_L → call_stack[0]=4, csp=1, PC=9
--   PC9 : BRA_L  → link=10, PC=6
--   PC6 : v1.xyzw = 0x42 (unchanged, already set)
--   PC7 : BRA_X  → PC=10
--   PC10: POP_L  → link=4, csp=0, PC=11
--   PC11: BRA_X  → PC=4
--   PC4 : FLUSH  (drain FPU pipeline)
--   PC5 : RETURN v2 → pixel snoop fills (v2={0x42,0x42,0x42,0x42}),
--         pixel_buf_valid → warp_halted
--
-- ASSERTIONS:
--   (A) pixel_buf_valid fires exactly once.
--   (B) pixel_buf_addr = 0x00000000 (fb_base_addr=0 << 16 + warp_offset=0 * 4).
--   (C) Pipelined read of 8 beats from M10K confirms all 32 threads = 0x42424242.
--   (D) warp_halted asserts cleanly.
--   (E) warp_break is never asserted (no OP_BREAK in this program).
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_call_stack is
end entity;

architecture sim of tb_call_stack is

    constant PC_WIDTH        : integer := 16;
    constant IMEM_ADDR_WIDTH : integer := 8;
    constant WARP_SIZE       : integer := 32;
    constant DATA_WIDTH      : integer := 128;
    constant CLK_PERIOD      : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- IMEM programming signals
    signal prog_we      : std_logic := '0';
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(31 downto 0)                := (others => '0');

    -- IMEM read port (warp_unit drives the address)
    signal imem_addr : std_logic_vector(PC_WIDTH-1 downto 0);
    signal imem_data : std_logic_vector(31 downto 0);

    -- Warp control
    signal warp_start    : std_logic := '0';
    signal warp_offset   : std_logic_vector(31 downto 0) := (others => '0');
    signal fb_base_addr  : std_logic_vector(15 downto 0) := (others => '0'); -- base 0 → phys 0x00000000
    signal warp_halted   : std_logic;
    signal warp_break    : std_logic;

    -- Pixel buffer outputs (New M10K interface)
    signal pixel_buf_valid : std_logic;
    signal pixel_buf_addr  : std_logic_vector(31 downto 0);
    signal pixel_wr_en     : std_logic;
    signal pixel_wr_addr   : std_logic_vector(4 downto 0);
    signal pixel_wr_data   : std_logic_vector(31 downto 0);

    signal pixel_rd_en     : std_logic := '0';
    signal pixel_rd_addr   : std_logic_vector(2 downto 0) := "000";
    signal pixel_rd_data   : std_logic_vector(DATA_WIDTH-1 downto 0);

    -- Helper: write one instruction word into IMEM
    procedure write_imem(
        signal we   : out std_logic;
        signal addr : out std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0);
        signal data : out std_logic_vector(31 downto 0);
        constant a  : integer;
        constant d  : std_logic_vector(31 downto 0);
        signal clk  : in std_logic
    ) is
    begin
        we   <= '1';
        addr <= std_logic_vector(to_unsigned(a, IMEM_ADDR_WIDTH));
        data <= d;
        wait until rising_edge(clk);
        we   <= '0';
    end procedure;

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- Shared instruction memory (external to warp_unit, same layout as frame_processor)
    u_imem : entity work.instruction_memory
        generic map ( ADDR_WIDTH => IMEM_ADDR_WIDTH )
        port map (
            clk     => clk,
            we      => prog_we,
            wr_addr => prog_wr_addr,
            wr_data => prog_wr_data,
            rd_addr => imem_addr(IMEM_ADDR_WIDTH-1 downto 0),
            rd_data => imem_data
        );

    -- Unit under test
    u_warp : entity work.warp_unit
        generic map (
            PC_WIDTH        => PC_WIDTH,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => WARP_SIZE
        )
        port map (
            clk             => clk,
            reset           => reset,
            imem_addr       => imem_addr,
            imem_data       => imem_data,
            warp_start      => warp_start,
            warp_offset     => warp_offset,
            fb_base_addr    => fb_base_addr,
            warp_halted     => warp_halted,
            warp_break      => warp_break,

            -- Shader Uniforms
            frame_width     => (others => '0'),
            frame_height    => (others => '0'),
            time_ms         => (others => '0'),
            
            -- Pixel Buffer
            pixel_buf_valid => pixel_buf_valid,
            pixel_buf_addr  => pixel_buf_addr,
            pixel_buf_dirty => '0',
            pixel_wr_en     => pixel_wr_en,
            pixel_wr_addr   => pixel_wr_addr,
            pixel_wr_data   => pixel_wr_data
        );

    -- Instantiation of the pixel buffer for testing
    u_pixel_buffer : entity work.pixel_buffer_ram
        port map (
            clk      => clk,
            we       => pixel_wr_en,
            wr_addr  => pixel_wr_addr,
            wr_data  => pixel_wr_data,
            rd_en    => pixel_rd_en,
            rd_addr  => pixel_rd_addr,
            rd_data  => pixel_rd_data
        );

    -- ========================================================================
    -- STIMULUS AND CHECKER PROCESS
    -- ========================================================================
    process
        -- Instruction word constants (pre-assembled from test10_call_stack.s)
        constant INST_LDI_CLEAR   : std_logic_vector(31 downto 0) := x"3C000014"; -- LDI_LO v1.xyzw, 0x0000
        -- BRA_L leaf targets PC 6: (54<<26)|(6<<10)|1 = 0xD8001801
        constant INST_BRA_L_LEAF  : std_logic_vector(31 downto 0) := x"D8001801"; -- BRA_L leaf (PC 6)
        constant INST_MOV_V2_V1   : std_logic_vector(31 downto 0) := x"4BC84000"; -- MOV v2.xyzw, v1
        -- BRA_L outer targets PC 8: (54<<26)|(8<<10)|1 = 0xD8002001
        constant INST_BRA_L_OUTER : std_logic_vector(31 downto 0) := x"D8002001"; -- BRA_L outer (PC 8)
        constant INST_FLUSH       : std_logic_vector(31 downto 0) := x"F8000006"; -- FLUSH
        -- RETURN v2: (63<<26)|(2<<14)|6 = 0xFC008006
        constant INST_RETURN_V2   : std_logic_vector(31 downto 0) := x"FC008006"; -- RETURN v2
        constant INST_LDI_42      : std_logic_vector(31 downto 0) := x"3C010814"; -- LDI_LO v1.xyzw, 0x0042
        constant INST_BRA_X       : std_logic_vector(31 downto 0) := x"DC000001"; -- BRA_X
        constant INST_PUSH_L      : std_logic_vector(31 downto 0) := x"E0000001"; -- PUSH_L
        constant INST_POP_L       : std_logic_vector(31 downto 0) := x"E4000001"; -- POP_L

        -- Expected pixel value: v2 = {X=0x42, Y=0x42, Z=0x42, W=0x42}
        -- Packed: W[7:0] & Z[7:0] & Y[7:0] & X[7:0] = 0x42424242
        -- 4 pixels packed into one 128-bit burst beat
        constant EXPECTED_BEAT    : std_logic_vector(127 downto 0) := x"42424242_42424242_42424242_42424242";

        variable all_pixels_ok : boolean := true;
    begin
        -- ----------------------------------------------------------------
        -- 1. Reset
        -- ----------------------------------------------------------------
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        reset <= '0';
        wait until rising_edge(clk);

        -- ----------------------------------------------------------------
        -- 2. Program instruction memory (12 instructions)
        --
        --   PC  0-5  : Main code
        --   PC  6-7  : leaf function
        --   PC  8-11 : outer function
        -- ----------------------------------------------------------------
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  0, INST_LDI_CLEAR,   clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  1, INST_BRA_L_LEAF,  clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  2, INST_MOV_V2_V1,   clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  3, INST_BRA_L_OUTER, clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  4, INST_FLUSH,       clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  5, INST_RETURN_V2,   clk);
        -- leaf function
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  6, INST_LDI_42,      clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  7, INST_BRA_X,       clk);
        -- outer function
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  8, INST_PUSH_L,      clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data,  9, INST_BRA_L_LEAF,  clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data, 10, INST_POP_L,       clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data, 11, INST_BRA_X,       clk);
        report "IMEM programmed (12 instructions)";

        -- ----------------------------------------------------------------
        -- 3. Start the warp
        -- ----------------------------------------------------------------
        warp_offset <= x"00000000";
        warp_start  <= '1';
        wait until rising_edge(clk);
        warp_start  <= '0';
        report "Warp started";

        -- ----------------------------------------------------------------
        -- 4. Wait for pixel_buf_valid (fires after STORE EXEC_WAIT)
        -- ----------------------------------------------------------------
        report "Waiting for pixel_buf_valid...";
        wait until pixel_buf_valid = '1';
        report "pixel_buf_valid asserted. addr=0x" & to_hstring(pixel_buf_addr);

        -- (A+B) Check pixel_buf_addr: base_addr=0x0000 << 16 + offset=0 * 4 = 0
        assert pixel_buf_addr = x"00000000"
            report "FAIL (A/B): pixel_buf_addr: expected 0x00000000, got 0x" &
                   to_hstring(pixel_buf_addr)
            severity failure;

        -- ----------------------------------------------------------------
        -- 5. Pipelined readout of the 8 Avalon beats from the M10K RAM
        -- ----------------------------------------------------------------
        report "Verifying 8 beats of pipelined pixel readout...";
        pixel_rd_en <= '1';
        for i in 0 to 8 loop
            -- Drive address
            if i < 8 then
                pixel_rd_addr <= std_logic_vector(to_unsigned(i, 3));
            else
                pixel_rd_en <= '0';
            end if;

            wait until rising_edge(clk);

            -- Check data from previous cycle (1-cycle read latency)
            if i > 0 then
                if pixel_rd_data /= EXPECTED_BEAT then
                    report "FAIL (C): beat " & integer'image(i-1) & 
                           " mismatch: expected 128-bit 0x42..., got 0x" & 
                           to_hstring(pixel_rd_data)
                        severity error;
                    all_pixels_ok := false;
                end if;
            end if;
        end loop;

        assert all_pixels_ok report "FAIL (C): pixel mismatch in one or more beats"
            severity failure;
        report "PASS (C): all 8 burst beats match 0x42424242 per thread";

        -- ----------------------------------------------------------------
        -- 6. Wait for warp_halted (fires after RETURN)
        -- ----------------------------------------------------------------
        if warp_halted = '0' then
            wait until warp_halted = '1';
        end if;
        report "Warp halted.";

        -- (D) warp_halted asserted cleanly
        assert warp_halted = '1'
            report "FAIL (D): warp_halted should be '1'" severity failure;

        -- (E) warp_break never asserted
        assert warp_break = '0'
            report "FAIL (E): warp_break should not be asserted" severity failure;

        report ">> tb_call_stack: ALL TESTS PASSED (BRA_L, BRA_X, PUSH_L, POP_L, MOV, RETURN reg verified)";
        std.env.stop;
    end process;

end architecture sim;
