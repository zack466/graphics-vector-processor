-- ============================================================================
-- TESTBENCH: tb_frame_processor_automated
-- ============================================================================
-- PURPOSE:
--   End-to-end automated regression driver for frame_processor.  Loads a
--   shader program from PROGRAM_FILE, fires a single frame_start pulse, and
--   waits for frame_done.  After the frame completes the testbench takes over
--   the Avalon bus and reads back the framebuffer from simulated DDR3 SDRAM,
--   writing the result to MEMORY_DUMP_FILE.
--
-- USAGE (from src/ directory):
--   Pass PROGRAM_FILE via GHDL generic override:
--     ./work/tb_frame_processor_automated \
--         -gPROGRAM_FILE=program.hex \
--         -gMEMORY_DUMP_FILE=memory_dump.hex \
--         --stop-time=10ms
--
-- FRAME PARAMETERS:
--   FRAME_WIDTH  x FRAME_HEIGHT pixels are rendered.  Each WARP_SIZE-pixel
--   group is handled by one warp; warp_scheduler dispatches them all
--   automatically.  Defaults: 32x32 = 1024 pixels = 32 warps.
--
-- MEMORY LAYOUT:
--   Assumes the shader stores to base address 0x0000 (STORE v, 0x0000),
--   producing a framebuffer at physical addresses 0x00000000..DUMP_END_ADDR.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;
use work.vector_types_pkg.all;

entity tb_frame_processor_automated is
    generic (
        PROGRAM_FILE     : string  := "program.hex";
        MEMORY_DUMP_FILE : string  := "memory_dump.hex";
        FRAME_WIDTH      : integer := 32;   -- pixels per row
        FRAME_HEIGHT     : integer := 32;   -- rows per frame
        DUMP_START_ADDR  : integer := 0;    -- framebuffer base in DDR3
        DUMP_END_ADDR    : integer := 4096; -- 32*32*4 bytes
        FB_BASE_ADDR     : integer := 0     -- framebuffer base (16-bit upper word of DDR3 byte address)
    );
end entity tb_frame_processor_automated;

architecture sim of tb_frame_processor_automated is

    constant PC_WIDTH        : integer := 16;
    constant IMEM_ADDR_WIDTH : integer := 8;
    constant WARP_SIZE       : integer := 32;
    constant ADDR_WIDTH      : integer := 32;
    constant DATA_WIDTH      : integer := 128;
    constant CLK_PERIOD      : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Frame Processor Avalon-MM Master Signals
    signal proc_avm_address       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal proc_avm_burstcount    : std_logic_vector(7 downto 0);
    signal proc_avm_write         : std_logic;
    signal proc_avm_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal proc_avm_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal proc_avm_read          : std_logic;

    -- Testbench Avalon-MM Master Signals (backdoor readback after frame_done)
    signal tb_takeover            : std_logic := '0';
    signal tb_avm_address         : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal tb_avm_burstcount      : std_logic_vector(7 downto 0) := "00000001";
    signal tb_avm_read            : std_logic := '0';

    -- Shared Memory Slave Signals
    signal mem_avm_address        : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal mem_avm_burstcount     : std_logic_vector(7 downto 0);
    signal mem_avm_write          : std_logic;
    signal mem_avm_writedata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_byteenable     : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal mem_avm_read           : std_logic;
    signal mem_avm_readdata       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_readdatavalid  : std_logic;
    signal mem_avm_waitrequest    : std_logic;

    -- Instruction Memory Programming
    signal prog_we      : std_logic := '0';
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(31 downto 0) := (others => '0');

    -- Frame Control
    signal frame_start  : std_logic := '0';
    signal fp_width     : std_logic_vector(15 downto 0) := (others => '0');
    signal fp_height    : std_logic_vector(15 downto 0) := (others => '0');
    signal frame_done   : std_logic;

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- ========================================================================
    -- BUS MULTIPLEXER: frame_processor drives bus normally; TB takes over
    -- after frame_done to read back the framebuffer.
    -- ========================================================================
    mem_avm_address    <= tb_avm_address    when tb_takeover = '1' else proc_avm_address;
    mem_avm_burstcount <= tb_avm_burstcount when tb_takeover = '1' else proc_avm_burstcount;
    mem_avm_write      <= '0'               when tb_takeover = '1' else proc_avm_write;
    mem_avm_writedata  <= (others => '0')   when tb_takeover = '1' else proc_avm_writedata;
    mem_avm_byteenable <= (others => '1')   when tb_takeover = '1' else proc_avm_byteenable;
    mem_avm_read       <= tb_avm_read       when tb_takeover = '1' else proc_avm_read;

    -- ========================================================================
    -- DUT: Frame Processor
    -- ========================================================================
    u_frame_processor : entity work.frame_processor
        generic map (
            PC_WIDTH        => PC_WIDTH,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => WARP_SIZE,
            ADDR_WIDTH      => ADDR_WIDTH,
            DATA_WIDTH      => DATA_WIDTH
        )
        port map (
            clk               => clk, reset => reset,
            avm_address       => proc_avm_address,
            avm_burstcount    => proc_avm_burstcount,
            avm_write         => proc_avm_write,
            avm_writedata     => proc_avm_writedata,
            avm_byteenable    => proc_avm_byteenable,
            avm_read          => proc_avm_read,
            avm_readdata      => mem_avm_readdata,
            avm_readdatavalid => mem_avm_readdatavalid,
            avm_waitrequest   => mem_avm_waitrequest,
            prog_we           => prog_we,
            prog_wr_addr      => prog_wr_addr,
            prog_wr_data      => prog_wr_data,
            frame_start       => frame_start,
            frame_width       => fp_width,
            frame_height      => fp_height,
            frame_done        => frame_done,
            fb_base_addr      => std_logic_vector(to_unsigned(FB_BASE_ADDR, 16))
        );

    -- ========================================================================
    -- Simulated DDR3 SDRAM
    -- ========================================================================
    u_memory : entity work.avm_sim_memory
        generic map ( ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk               => clk, reset => reset,
            avs_address       => mem_avm_address,
            avs_burstcount    => mem_avm_burstcount,
            avs_write         => mem_avm_write,
            avs_writedata     => mem_avm_writedata,
            avs_byteenable    => mem_avm_byteenable,
            avs_read          => mem_avm_read,
            avs_readdata      => mem_avm_readdata,
            avs_readdatavalid => mem_avm_readdatavalid,
            avs_waitrequest   => mem_avm_waitrequest
        );

    -- ========================================================================
    -- MAIN STIMULUS PROCESS
    -- ========================================================================
    p_main : process

        -- Read one 128-bit word from the simulated memory via the backdoor bus
        procedure read_memory(addr : std_logic_vector(31 downto 0)) is
        begin
            tb_avm_address <= addr; tb_avm_read <= '1';
            wait until rising_edge(clk);
            while mem_avm_waitrequest = '1' loop wait until rising_edge(clk); end loop;
            tb_avm_read <= '0';
            while mem_avm_readdatavalid = '0' loop wait until rising_edge(clk); end loop;
            wait until rising_edge(clk);
        end procedure;

        variable rom_ptr   : integer := 0;

        file     prog_file : text;
        variable prog_line : line;
        variable prog_word : std_logic_vector(31 downto 0);
        variable good      : boolean;

        file     dump_file : text;
        variable dump_line : line;
        variable dump_addr : integer;

    begin
        wait for 50 ns; wait until rising_edge(clk); reset <= '0';
        wait for 50 ns; wait until rising_edge(clk);
        report "--- STARTING FRAME PROCESSOR TEST ---";

        -- ====================================================================
        -- 1. LOAD SHADER PROGRAM
        -- ====================================================================
        report "Loading instruction memory from " & PROGRAM_FILE & "...";
        file_open(prog_file, PROGRAM_FILE, read_mode);
        rom_ptr := 0;
        while not endfile(prog_file) loop
            readline(prog_file, prog_line);
            hread(prog_line, prog_word, good);
            if good then
                prog_wr_addr <= std_logic_vector(to_unsigned(rom_ptr, IMEM_ADDR_WIDTH));
                prog_wr_data <= prog_word;
                prog_we <= '1';
                wait until rising_edge(clk);
                rom_ptr := rom_ptr + 1;
            end if;
        end loop;
        file_close(prog_file);
        prog_we <= '0';
        wait for 50 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 2. RENDER FRAME (single pulse; scheduler dispatches all warps)
        -- ====================================================================
        report "Starting frame render (" & integer'image(FRAME_WIDTH) &
               "x" & integer'image(FRAME_HEIGHT) & ", " &
               integer'image((FRAME_WIDTH * FRAME_HEIGHT + WARP_SIZE - 1) / WARP_SIZE) &
               " warps)...";

        fp_width     <= std_logic_vector(to_unsigned(FRAME_WIDTH,  16));
        fp_height    <= std_logic_vector(to_unsigned(FRAME_HEIGHT, 16));
        frame_start  <= '1';
        wait until rising_edge(clk);
        frame_start  <= '0';

        wait until frame_done = '1';
        report "Frame render complete.";
        wait for 50 ns; wait until rising_edge(clk);

        -- ====================================================================
        -- 3. DUMP FRAMEBUFFER
        -- ====================================================================
        report "Taking over Avalon Bus and dumping DDR3 Memory to " & MEMORY_DUMP_FILE & "...";
        tb_takeover <= '1'; wait until rising_edge(clk);

        file_open(dump_file, MEMORY_DUMP_FILE, write_mode);
        dump_addr := DUMP_START_ADDR;
        while dump_addr < DUMP_END_ADDR loop
            read_memory(std_logic_vector(to_unsigned(dump_addr, 32)));

            hwrite(dump_line, mem_avm_readdata(127 downto 96));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(95 downto 64));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(63 downto 32));
            write(dump_line, string'(" "));
            hwrite(dump_line, mem_avm_readdata(31 downto 0));
            writeline(dump_file, dump_line);

            dump_addr := dump_addr + 16;
        end loop;
        file_close(dump_file);

        report "--- FRAME PROCESSOR TEST COMPLETE ---";
        std.env.stop;
    end process;

end architecture sim;
