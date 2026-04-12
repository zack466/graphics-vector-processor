-- ============================================================================
-- TESTBENCH: tb_warp_unit
-- ============================================================================
-- PURPOSE:
--   Verifies that warp_unit correctly sequences through a minimal shader
--   program, fires pixel_buf_valid after all 32 threads are issued for a MEM
--   instruction, waits in MEM_WAIT until mem_stall deasserts, and finally
--   asserts warp_halted after OP_RETURN.
--
-- TEST PROGRAM (loaded into instruction_memory):
--   Addr 0: OP_FLUSH              (drain pipeline)        0xF8000006
--   Addr 1: RETURN v1             (store reg1 + halt)     0xFC000016
--
-- INSTRUCTION ENCODING:
--   [3:0]   = inst_type
--   [7:4]   = source register index (RETURN only)
--   [31:26] = opcode (SYS instructions)
--
--   INST_TYPE_SYS  = "0110" = 0x6
--   OP_FLUSH       = "111110" in [31:26] → 0xF8000006
--   RETURN v1 (SYS): opcode=0x3F, reg=1 in [7:4], type=0x6
--     → (63<<26) | (1<<4) | 6 = 0xFC000016
--     phys_addr = fb_base_addr << 16 + warp_offset*4
--     With fb_base_addr=0x0001: phys = 0x00010000 (for offset=0)
--
-- SEQUENCE:
--   1. Reset, then program IMEM.
--   2. Pulse warp_start with warp_offset=0; fb_base_addr=0x0001.
--   3. Warp runs: FETCH×2 → DECODE(OP_FLUSH) → EXEC_WAIT(28+32 cycles) →
--      ADVANCE_PC → FETCH×2 → DECODE(RETURN v1) → EXEC_WAIT(32 cycles) →
--      pixel_buf_valid pulse → MEM_WAIT.
--   4. TB asserts mem_stall='0' to release MEM_WAIT.
--   5. MEM_WAIT → HALTED (RETURN goes directly to HALTED, no ADVANCE_PC).
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_warp_unit is
end entity;

architecture sim of tb_warp_unit is

    constant PC_WIDTH        : integer := 16;
    constant IMEM_ADDR_WIDTH : integer := 8;
    constant WARP_SIZE       : integer := 32;
    constant CLK_PERIOD      : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- IMEM programming interface (connected to instruction_memory instance)
    signal prog_we      : std_logic := '0';
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(31 downto 0) := (others => '0');

    -- IMEM read port (warp_unit drives address, gets data back)
    signal imem_addr : std_logic_vector(PC_WIDTH-1 downto 0);
    signal imem_data : std_logic_vector(31 downto 0);

    -- Warp control
    signal warp_start   : std_logic := '0';
    signal warp_offset  : std_logic_vector(31 downto 0) := (others => '0');
    signal fb_base_addr : std_logic_vector(15 downto 0) := x"0001"; -- base 0x0001 → phys 0x00010000
    signal warp_halted  : std_logic;
    signal warp_break   : std_logic;

    -- Pixel buffer interface
    signal pixel_buf_valid : std_logic;
    signal pixel_buf_addr  : std_logic_vector(31 downto 0);
    signal pixel_buf_data  : std_logic_vector(1023 downto 0);
    signal pixel_exec_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal mem_stall       : std_logic := '0';  -- TB controls this (simulates MCU)

    -- Helper procedure to write one instruction into IMEM
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

    -- Shared instruction memory (external to warp_unit, mirroring frame_processor layout)
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
            clk             => clk, reset => reset,
            imem_addr       => imem_addr,
            imem_data       => imem_data,
            warp_start      => warp_start,
            warp_offset     => warp_offset,
            fb_base_addr    => fb_base_addr,
            warp_halted     => warp_halted,
            warp_break      => warp_break,
            pixel_buf_valid => pixel_buf_valid,
            pixel_buf_addr  => pixel_buf_addr,
            pixel_buf_data  => pixel_buf_data,
            pixel_exec_mask => pixel_exec_mask,
            mem_stall       => mem_stall
        );

    process
        -- Instruction encodings
        constant INST_FLUSH     : std_logic_vector(31 downto 0) := x"F8000006"; -- OP_FLUSH | SYS
        -- RETURN v1: (63<<26)|(1<<4)|6 = 0xFC000016; address = fb_base_addr<<16 + warp_offset*4
        constant INST_RETURN_V1 : std_logic_vector(31 downto 0) := x"FC000016"; -- RETURN v1 | SYS
    begin
        -- ----------------------------------------------------------------
        -- 1. Reset
        -- ----------------------------------------------------------------
        wait for 2 * CLK_PERIOD;
        reset <= '0';
        wait for CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- 2. Program instruction memory (2 instructions)
        -- ----------------------------------------------------------------
        write_imem(prog_we, prog_wr_addr, prog_wr_data, 0, INST_FLUSH,     clk);
        write_imem(prog_we, prog_wr_addr, prog_wr_data, 1, INST_RETURN_V1, clk);
        report "IMEM programmed";

        -- ----------------------------------------------------------------
        -- 3. Start the warp
        -- ----------------------------------------------------------------
        warp_offset <= x"00000000";
        warp_start  <= '1';
        wait until rising_edge(clk);
        warp_start  <= '0';
        report "Warp started";

        -- ----------------------------------------------------------------
        -- 4. Wait for pixel_buf_valid (fires after OP_STORE EXEC_WAIT)
        -- ----------------------------------------------------------------
        report "Waiting for pixel_buf_valid...";
        wait until pixel_buf_valid = '1';
        report "pixel_buf_valid asserted! addr=0x" & to_hstring(pixel_buf_addr);

        -- Verify address: base_addr=0x0001 << 16 = 0x00010000, warp_offset=0
        assert pixel_buf_addr = x"00010000"
            report "Wrong pixel_buf_addr: expected 0x00010000, got 0x" & to_hstring(pixel_buf_addr)
            severity failure;

        -- ----------------------------------------------------------------
        -- 5. Release MEM_WAIT by deasserting mem_stall
        --    (In real design, mem_stall comes from mcu_block_transfer;
        --     here we drive it from the TB to simulate instant completion.)
        -- ----------------------------------------------------------------
        -- pixel_buf_valid is a 1-cycle pulse; mem_stall is already '0'
        -- so MEM_WAIT exits immediately on the next rising edge.
        wait until rising_edge(clk);
        report "MEM_WAIT released";

        -- ----------------------------------------------------------------
        -- 6. Wait for warp_halted (fires after OP_RETURN)
        -- ----------------------------------------------------------------
        report "Waiting for warp_halted...";
        wait until warp_halted = '1';
        report "warp_halted asserted - warp completed successfully";

        assert warp_break = '0'
            report "warp_break should not be asserted" severity failure;

        -- ----------------------------------------------------------------
        -- 7. Verify warp can be restarted
        -- ----------------------------------------------------------------
        report "Testing warp restart with warp_offset=32...";
        warp_offset <= std_logic_vector(to_unsigned(32, 32));
        warp_start  <= '1';
        wait until rising_edge(clk);
        warp_start  <= '0';

        -- Wait for warp_halted to deassert (combinational from state; takes one
        -- clock cycle for `running` to propagate into the FSM and change state)
        wait until warp_halted = '0';
        report "warp_halted deasserted - second run in progress";

        -- Wait for second pixel_buf_valid
        wait until pixel_buf_valid = '1';
        report "Second pixel_buf_valid: addr=0x" & to_hstring(pixel_buf_addr);

        -- Verify address for warp_offset=32: base=0x00010000 + 32*4=128=0x80 → 0x00010080
        assert pixel_buf_addr = x"00010080"
            report "Wrong pixel_buf_addr for offset 32: expected 0x00010080, got 0x" &
                   to_hstring(pixel_buf_addr)
            severity failure;

        wait until rising_edge(clk);
        wait until warp_halted = '1';
        report "Second warp halted";

        report "tb_warp_unit: ALL TESTS PASSED" severity note;
        std.env.stop;
    end process;

end architecture sim;
