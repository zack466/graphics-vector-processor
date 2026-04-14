-- ============================================================================
-- FILE: tb_gpu_qsys_wrapper.vhd
-- ============================================================================
-- PURPOSE:
--   Automated regression testbench for the full Qsys GPU wrapper.
--   1. Initializes CSRs and loads instructions via Avalon-MM Slave.
--   2. Starts the system with Auto-Swap and IRQ enabled.
--   3. Generates simulated VSYNC pulses.
--   4. Traps the irq_out signal on frame completion.
--   5. Takes over the Avalon-MM master bus to dump DDR3 to frame_X.hex.
--
-- USAGE (GHDL):
--   ghdl -i *.vhd
--   ghdl -m tb_gpu_qsys_wrapper
--   ./tb_gpu_qsys_wrapper -gPROGRAM_FILE=program.hex -gNUM_FRAMES=5
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.textio.all;

entity tb_gpu_qsys_wrapper is
    generic (
        PROGRAM_FILE    : string  := "program.hex";
        FRAME_WIDTH     : integer := 32;
        FRAME_HEIGHT    : integer := 32;
        NUM_FRAMES      : integer := 4
    );
end entity tb_gpu_qsys_wrapper;

architecture sim of tb_gpu_qsys_wrapper is

    -- GPU Generics
    constant SYS_CLK_FREQ    : integer := 50_000_000;
    constant PC_WIDTH        : integer := 16;
    constant IMEM_ADDR_WIDTH : integer := 8;
    constant WARP_SIZE       : integer := 32;
    constant ADDR_WIDTH      : integer := 32;
    constant DATA_WIDTH      : integer := 128;
    constant SLAVE_ADDR_W    : integer := 12;

    constant CLK_PERIOD      : time := 20 ns; -- 50 MHz
    constant VSYNC_PERIOD    : time := 1 ms;  -- Sped up for simulation

    -- Memory sizing for Double Buffering
    -- 4 bytes per pixel. 16 bytes (128 bits) per memory word.
    -- fb_base_addr is the UPPER 16 bits of the DDR3 byte address (a "page" number).
    -- The GPU computes: pixel_addr = (fb_base_addr << 16) + warp_offset*4
    -- So page 0 → 0x00000000, page 1 → 0x00010000, etc.
    constant FB_SIZE_BYTES   : integer := FRAME_WIDTH * FRAME_HEIGHT * 4;
    constant FB_0_PAGE       : integer := 0;  -- CSR value written for FB0
    constant FB_1_PAGE       : integer := 1;  -- CSR value written for FB1
    constant FB_0_ADDR       : integer := FB_0_PAGE * 65536; -- = 0x00000000
    constant FB_1_ADDR       : integer := FB_1_PAGE * 65536; -- = 0x00010000

    -- SIM_MEM_WORDS must cover the last byte of FB1 (page 1 start + one frame)
    constant SIM_MEM_WORDS   : integer := (FB_1_ADDR + FB_SIZE_BYTES) / (DATA_WIDTH / 8);

    -- Global Signals
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Host to Wrapper (Avalon Slave)
    signal host_avs_address     : std_logic_vector(SLAVE_ADDR_W-1 downto 0) := (others => '0');
    signal host_avs_read        : std_logic := '0';
    signal host_avs_readdata    : std_logic_vector(31 downto 0);
    signal host_avs_write       : std_logic := '0';
    signal host_avs_writedata   : std_logic_vector(31 downto 0) := (others => '0');
    signal host_avs_waitrequest : std_logic;

    -- Wrapper to Memory (Avalon Master)
    signal wrap_avm_address       : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal wrap_avm_burstcount    : std_logic_vector(7 downto 0);
    signal wrap_avm_write         : std_logic;
    signal wrap_avm_writedata     : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal wrap_avm_byteenable    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal wrap_avm_read          : std_logic;

    -- Wrapper to VIP (Dummy Target)
    signal vip_avm_address        : std_logic_vector(31 downto 0);
    signal vip_avm_write          : std_logic;
    signal vip_avm_writedata      : std_logic_vector(31 downto 0);
    signal vip_avm_waitrequest    : std_logic := '0'; -- Always ready in sim

    -- Sync and Interrupts
    signal vsync_in : std_logic := '0';
    signal irq_out  : std_logic;

    -- Testbench Backdoor to Memory
    signal tb_takeover            : std_logic := '0';
    signal tb_avm_address         : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal tb_avm_burstcount      : std_logic_vector(7 downto 0) := "00000001";
    signal tb_avm_read            : std_logic := '0';

    -- Physical Memory Interface (Mux output)
    signal mem_avm_address        : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal mem_avm_burstcount     : std_logic_vector(7 downto 0);
    signal mem_avm_write          : std_logic;
    signal mem_avm_writedata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_byteenable     : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal mem_avm_read           : std_logic;
    signal mem_avm_readdata       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_avm_readdatavalid  : std_logic;
    signal mem_avm_waitrequest    : std_logic;

begin

    -- Clock Generation
    clk <= not clk after CLK_PERIOD / 2;

    -- VSYNC Generation
    process
    begin
        wait for VSYNC_PERIOD;
        vsync_in <= '1';
        wait for CLK_PERIOD * 5;
        vsync_in <= '0';
    end process;

    -- ========================================================================
    -- Bus Multiplexer (GPU normal operation vs TB Backdoor Readback)
    -- ========================================================================
    mem_avm_address    <= tb_avm_address    when tb_takeover = '1' else wrap_avm_address;
    mem_avm_burstcount <= tb_avm_burstcount when tb_takeover = '1' else wrap_avm_burstcount;
    mem_avm_write      <= '0'               when tb_takeover = '1' else wrap_avm_write;
    mem_avm_writedata  <= (others => '0')   when tb_takeover = '1' else wrap_avm_writedata;
    mem_avm_byteenable <= (others => '1')   when tb_takeover = '1' else wrap_avm_byteenable;
    mem_avm_read       <= tb_avm_read       when tb_takeover = '1' else wrap_avm_read;

    -- ========================================================================
    -- DUT: GPU Qsys Wrapper
    -- ========================================================================
    u_dut : entity work.gpu_qsys_wrapper
        generic map (
            SYS_CLK_FREQ    => SYS_CLK_FREQ,
            PC_WIDTH        => PC_WIDTH,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => WARP_SIZE,
            ADDR_WIDTH      => ADDR_WIDTH,
            DATA_WIDTH      => DATA_WIDTH,
            SLAVE_ADDR_W    => SLAVE_ADDR_W
        )
        port map (
            clk                 => clk,
            reset               => reset,
            avs_address         => host_avs_address,
            avs_read            => host_avs_read,
            avs_readdata        => host_avs_readdata,
            avs_write           => host_avs_write,
            avs_writedata       => host_avs_writedata,
            avs_waitrequest     => host_avs_waitrequest,
            vsync_in            => vsync_in,
            irq_out             => irq_out,
            avm_address         => wrap_avm_address,
            avm_burstcount      => wrap_avm_burstcount,
            avm_write           => wrap_avm_write,
            avm_writedata       => wrap_avm_writedata,
            avm_byteenable      => wrap_avm_byteenable,
            avm_read            => wrap_avm_read,
            avm_readdata        => mem_avm_readdata,
            avm_readdatavalid   => mem_avm_readdatavalid,
            avm_waitrequest     => mem_avm_waitrequest,
            vip_avm_address     => vip_avm_address,
            vip_avm_write       => vip_avm_write,
            vip_avm_writedata   => vip_avm_writedata,
            vip_avm_waitrequest => vip_avm_waitrequest
        );

    -- ========================================================================
    -- Simulated DDR3
    -- ========================================================================
    u_memory : entity work.avm_sim_memory
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH,
            MEM_WORDS  => SIM_MEM_WORDS
        )
        port map (
            clk               => clk,
            reset             => reset,
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
    -- Main Stimulus Process
    -- ========================================================================
    p_main : process

        -- Procedure to simulate Avalon-MM Host Write
        procedure avm_write_word(
            addr : in integer;
            data : in std_logic_vector(31 downto 0)) is
        begin
            host_avs_address   <= std_logic_vector(to_unsigned(addr, SLAVE_ADDR_W));
            host_avs_writedata <= data;
            host_avs_write     <= '1';
            wait until rising_edge(clk);
            host_avs_write     <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Procedure to backdoor read one 128-bit word from memory
        procedure read_memory(addr : std_logic_vector(31 downto 0)) is
        begin
            tb_avm_address <= addr; tb_avm_read <= '1';
            wait until rising_edge(clk);
            while mem_avm_waitrequest = '1' loop wait until rising_edge(clk); end loop;
            tb_avm_read <= '0';
            while mem_avm_readdatavalid = '0' loop wait until rising_edge(clk); end loop;
            wait until rising_edge(clk);
        end procedure;

        -- Variables
        file     prog_file : text;
        variable prog_line : line;
        variable prog_word : std_logic_vector(31 downto 0);
        variable good      : boolean;
        variable rom_ptr   : integer := 0;

        file     dump_file : text;
        variable dump_line : line;
        variable dump_addr : integer;
        variable base_addr : integer;
        -- file_name removed: use inline string expressions to avoid fixed-width string issues

    begin
        for i in 1 to 10 loop wait until rising_edge(clk); end loop; reset <= '0';
        for i in 1 to 10 loop wait until rising_edge(clk); end loop;
        report "--- STARTING QSYS WRAPPER TEST ---";

        -- ====================================================================
        -- 1. LOAD SHADER PROGRAM
        -- ====================================================================
        report "Loading instructions via AVM Slave...";
        file_open(prog_file, PROGRAM_FILE, read_mode);
        
        rom_ptr := 2048; 
        
        while not endfile(prog_file) loop
            readline(prog_file, prog_line);
            hread(prog_line, prog_word, good);
            if good then
                avm_write_word(rom_ptr, prog_word);
                rom_ptr := rom_ptr + 1;
            end if;
        end loop;
        file_close(prog_file);

        -- ====================================================================
        -- 2. CONFIGURE REGISTERS
        -- ====================================================================
        report "Configuring Dimensions and Buffers...";
        
        -- Dimensions (Word Addr 0x02). Packed 16-bit Width / Height
        avm_write_word(16#02#, std_logic_vector(to_unsigned(FRAME_WIDTH, 16)) & 
                               std_logic_vector(to_unsigned(FRAME_HEIGHT, 16)));
        
        -- Framebuffer 0 Base (Word Addr 0x04) — write page number, not byte address
        avm_write_word(16#04#, std_logic_vector(to_unsigned(FB_0_PAGE, 32)));

        -- Framebuffer 1 Base (Word Addr 0x05) — write page number, not byte address
        avm_write_word(16#05#, std_logic_vector(to_unsigned(FB_1_PAGE, 32)));

        -- Control Register (Word Addr 0x00)
        -- Bit 0 = Start, Bit 1 = Auto-Swap, Bit 2 = Enable IRQ
        -- Write 0x07 to start the engine, enable swap, and enable IRQ on completion.
        report "Triggering execution...";
        avm_write_word(16#00#, x"00000007");
        
        -- Clear start bit (0x06 remains to keep Auto-Swap and IRQ active)
        avm_write_word(16#00#, x"00000006");

        -- ====================================================================
        -- 3. RENDER & DUMP LOOP
        -- ====================================================================
        for i in 0 to NUM_FRAMES - 1 loop
            
            report "Waiting for frame " & integer'image(i) & " to complete...";
            
            -- Wait for the GPU to assert IRQ indicating the backbuffer is done
            wait until rising_edge(irq_out);
            report "Frame " & integer'image(i) & " computed. Waiting for VSYNC to flip...";

            -- The wrapper waits for VSYNC to flip active index. 
            -- Once irq_out goes low, we know the wrapper flipped it and cleared the status flag.
            wait until falling_edge(irq_out);
            
            -- Take over the bus
            tb_takeover <= '1';
            wait until rising_edge(clk);

            -- Determine which buffer the GPU *just* finished writing to
            if (i mod 2) = 0 then
                base_addr := FB_0_ADDR;
            else
                base_addr := FB_1_ADDR;
            end if;

            report "Dumping memory to frame_" & integer'image(i) & ".hex";

            file_open(dump_file, "frame_" & integer'image(i) & ".hex", write_mode);
            dump_addr := base_addr;
            
            -- Loop through the memory footprint of one frame
            while dump_addr < base_addr + FB_SIZE_BYTES loop
                read_memory(std_logic_vector(to_unsigned(dump_addr, 32)));

                hwrite(dump_line, mem_avm_readdata(127 downto 96));
                write(dump_line, string'(" "));
                hwrite(dump_line, mem_avm_readdata(95 downto 64));
                write(dump_line, string'(" "));
                hwrite(dump_line, mem_avm_readdata(63 downto 32));
                write(dump_line, string'(" "));
                hwrite(dump_line, mem_avm_readdata(31 downto 0));
                writeline(dump_file, dump_line);

                -- Increment by 16 bytes (128 bits) per memory read
                dump_addr := dump_addr + 16;
            end loop;
            
            file_close(dump_file);

            -- Release bus back to GPU so it can render the next frame
            tb_takeover <= '0';
            wait until rising_edge(clk);
            
        end loop;

        report "--- TESTBENCH COMPLETE ---";
        std.env.stop;
    end process;

end architecture sim;
