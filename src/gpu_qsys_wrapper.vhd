library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity gpu_qsys_wrapper is
    generic (
        SYS_CLK_FREQ    : integer := 50_000_000; 
        
        -- Frame Processor Generics
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128;
        REG_WIDTH       : integer := 4;
        
        -- Wrapper Specific Generics
        SLAVE_ADDR_W    : integer := 12
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Avalon-MM Slave (Host Control via JTAG)
        -- ==========================================
        avs_address       : in  std_logic_vector(SLAVE_ADDR_W-1 downto 0);
        avs_read          : in  std_logic;
        avs_readdata      : out std_logic_vector(31 downto 0);
        avs_write         : in  std_logic;
        avs_writedata     : in  std_logic_vector(31 downto 0);
        avs_waitrequest   : out std_logic;

        -- ==========================================
        -- Hardware Sync & Interrupts
        -- ==========================================
        vsync_in          : in  std_logic;
        irq_out           : out std_logic;

        -- ==========================================
        -- Avalon-MM Master 1 (Burst DDR3 Pixel Data)
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
        -- Avalon-MM Master 2 (VIP Control Register)
        -- ==========================================
        vip_avm_address     : out std_logic_vector(31 downto 0);
        vip_avm_write       : out std_logic;
        vip_avm_writedata   : out std_logic_vector(31 downto 0);
        vip_avm_waitrequest : in  std_logic
    );
end entity gpu_qsys_wrapper;

architecture rtl of gpu_qsys_wrapper is

    -- CSR Registers
    signal reg_ctrl         : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_status       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_dimensions   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_time_ms      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_fb_addr_0    : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_fb_addr_1    : std_logic_vector(15 downto 0) := (others => '0');
    
    -- Internal GPU control signals
    signal int_frame_start  : std_logic := '0';
    signal int_frame_done   : std_logic;
    signal active_fb_index  : std_logic := '0'; 
    signal current_fb_base  : std_logic_vector(15 downto 0);

    -- Hardware Timekeeper
    signal ms_tick_counter  : integer range 0 to (SYS_CLK_FREQ / 1000) := 0;

    -- VSYNC Edge Detection
    signal vsync_d1, vsync_d2 : std_logic := '0';

    -- IMEM signals
    signal imem_we          : std_logic;

    -- VIP Synchronization FSM
    type swap_state_t is (IDLE, WRITE_VIP_ADDR, WAIT_VIP_ACK, START_NEXT_FRAME);
    signal swap_state   : swap_state_t := IDLE;
    signal swap_pending : std_logic := '0';

begin

    avs_waitrequest <= '0';

    -- ========================================================================
    -- Main Synchronous Process
    -- ========================================================================
    process(clk, reset)
    begin
        if reset = '1' then
            reg_ctrl        <= (others => '0');
            reg_status      <= (others => '0');
            reg_dimensions  <= (others => '0');
            reg_time_ms     <= (others => '0');
            reg_fb_addr_0   <= (others => '0');
            reg_fb_addr_1   <= (others => '0');
            
            int_frame_start <= '0';
            ms_tick_counter <= 0;
            swap_pending    <= '0';
            swap_state      <= IDLE;
            vip_avm_write   <= '0';
            
        elsif rising_edge(clk) then
            int_frame_start <= '0'; 
            imem_we         <= '0';

            -- --------------------------------------------------------
            -- 1. Hardware Timekeeper (1ms resolution)
            -- --------------------------------------------------------
            if ms_tick_counter >= (SYS_CLK_FREQ / 1000) - 1 then
                ms_tick_counter <= 0;
                reg_time_ms <= std_logic_vector(unsigned(reg_time_ms) + 1);
            else
                ms_tick_counter <= ms_tick_counter + 1;
            end if;

            -- --------------------------------------------------------
            -- 2. Frame Done Capture
            -- --------------------------------------------------------
            if int_frame_done = '1' then
                reg_status(0) <= '0'; -- Busy flat low
                reg_status(1) <= '1'; -- Frame done flag high
                swap_pending  <= '1'; -- Queue the VIP update for the next VSYNC
            end if;

            -- --------------------------------------------------------
            -- 3. Avalon-MM Slave Write Logic (JTAG Control)
            -- --------------------------------------------------------
            if avs_write = '1' then
                if avs_address(SLAVE_ADDR_W-1) = '0' then 
                    case avs_address(3 downto 0) is
                        when x"0" => 
                            reg_ctrl <= avs_writedata;
                            -- Manual software trigger
                            if avs_writedata(0) = '1' then 
                                int_frame_start <= '1';
                                reg_status(0)   <= '1'; 
                                reg_status(1)   <= '0'; 
                            end if;
                        when x"1" => 
                            if avs_writedata(1) = '1' then
                                reg_status(1) <= '0'; -- Clear done flag
                            end if;
                        when x"2" => reg_dimensions <= avs_writedata;
                        when x"4" => reg_fb_addr_0  <= avs_writedata(15 downto 0);
                        when x"5" => reg_fb_addr_1  <= avs_writedata(15 downto 0);
                        when others => null;
                    end case;
                else
                    imem_we <= '1';
                end if;
            end if;

            -- --------------------------------------------------------
            -- 4. Avalon-MM Slave Read Logic
            -- --------------------------------------------------------
            avs_readdata <= (others => '0');
            if avs_read = '1' then
                if avs_address(SLAVE_ADDR_W-1) = '0' then
                    case avs_address(3 downto 0) is
                        when x"0" => avs_readdata <= reg_ctrl;
                        when x"1" => avs_readdata <= reg_status;
                        when x"2" => avs_readdata <= reg_dimensions;
                        when x"3" => avs_readdata <= reg_time_ms;
                        when x"4" => avs_readdata(15 downto 0) <= reg_fb_addr_0;
                        when x"5" => avs_readdata(15 downto 0) <= reg_fb_addr_1;
                        when others => null;
                    end case;
                end if;
            end if;

            -- --------------------------------------------------------
            -- 5. VSYNC & VIP Hardware Swap FSM
            -- --------------------------------------------------------
            vsync_d1 <= vsync_in;
            vsync_d2 <= vsync_d1;

            case swap_state is
                when IDLE =>
                    vip_avm_write <= '0';
                    -- If Auto-Swap is enabled (reg_ctrl bit 1) AND GPU finished a frame
                    if reg_ctrl(1) = '1' and swap_pending = '1' then
                        -- Wait for VSYNC rising edge
                        if vsync_d1 = '1' and vsync_d2 = '0' then
                            swap_state <= WRITE_VIP_ADDR;
                        end if;
                    end if;

                when WRITE_VIP_ADDR =>
                    vip_avm_write <= '1';
                    
                    -- VIP Register 6 (Frame Start Address) -> 6 * 4 bytes = 0x18
                    vip_avm_address <= x"00000018"; 
                    
                    -- Write the address of the buffer we JUST finished drawing on.
                    -- Note: The upper 16 bits are zeroed out assuming a 32-bit SDRAM space. 
                    -- Adjust bit shifting here if your base address is structured differently.
                    if active_fb_index = '0' then
                        vip_avm_writedata <= x"0000" & reg_fb_addr_0;
                    else
                        vip_avm_writedata <= x"0000" & reg_fb_addr_1;
                    end if;
                    
                    swap_state <= WAIT_VIP_ACK;

                when WAIT_VIP_ACK =>
                    if vip_avm_waitrequest = '0' then
                        vip_avm_write <= '0';
                        -- VIP has latched the new address for its next read cycle.
                        -- Now flip our internal index to point to the alternate buffer.
                        active_fb_index <= not active_fb_index;
                        swap_state      <= START_NEXT_FRAME;
                    end if;

                when START_NEXT_FRAME =>
                    int_frame_start <= '1';     -- Tell GPU to draw the next frame
                    reg_status(0)   <= '1';     -- Mark GPU busy
                    reg_status(1)   <= '0';     -- Clear frame done flag
                    swap_pending    <= '0';     -- Clear pending flag
                    swap_state      <= IDLE;

            end case;

        end if;
    end process;

    -- Multiplex active framebuffer address routing to the GPU Core
    current_fb_base <= reg_fb_addr_1 when active_fb_index = '1' else reg_fb_addr_0;

    irq_out <= reg_status(1) and reg_ctrl(2);

    -- ========================================================================
    -- Core GPU Instantiation
    -- ========================================================================
    u_core : entity work.frame_processor
        generic map (
            PC_WIDTH        => PC_WIDTH,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => WARP_SIZE,
            ADDR_WIDTH      => ADDR_WIDTH,
            DATA_WIDTH      => DATA_WIDTH,
            REG_WIDTH       => REG_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,
            
            avm_address       => avm_address,
            avm_burstcount    => avm_burstcount,
            avm_write         => avm_write,
            avm_writedata     => avm_writedata,
            avm_byteenable    => avm_byteenable,
            avm_read          => avm_read,
            avm_readdata      => avm_readdata,
            avm_readdatavalid => avm_readdatavalid,
            avm_waitrequest   => avm_waitrequest,

            prog_we           => imem_we,
            prog_wr_addr      => avs_address(IMEM_ADDR_WIDTH-1 downto 0),
            prog_wr_data      => avs_writedata,

            frame_start       => int_frame_start,
            frame_width       => reg_dimensions(31 downto 16),
            frame_height      => reg_dimensions(15 downto 0),
            time_ms           => reg_time_ms,
            frame_done        => int_frame_done,
            fb_base_addr      => current_fb_base
        );

end architecture rtl;
