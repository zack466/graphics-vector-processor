-- ============================================================================
-- FILE: top_level.vhd
-- Top-level that wires frame_processor to the VIP Frame Buffer II via a
-- triple-buffer control FSM, plus a JTAG-writable register file for IMEM
-- programming and uniforms.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_level is
    port (
        clk                  : in  std_logic;
        reset                : in  std_logic;

        -- Push buttons (active-low on DE10-nano)
        key_n                : in  std_logic_vector(1 downto 0);

        -- =====================================================================
        -- Avalon-MM Master: frame_processor to DDR3 (128-bit burst)
        -- =====================================================================
        avm_fp_address       : out std_logic_vector(31 downto 0);
        avm_fp_burstcount    : out std_logic_vector(7 downto 0);
        avm_fp_write         : out std_logic;
        avm_fp_writedata     : out std_logic_vector(127 downto 0);
        avm_fp_byteenable    : out std_logic_vector(15 downto 0);
        avm_fp_read          : out std_logic;
        avm_fp_readdata      : in  std_logic_vector(127 downto 0);
        avm_fp_readdatavalid : in  std_logic;
        avm_fp_waitrequest   : in  std_logic;

        -- =====================================================================
        -- Avalon-MM Master: control FSM to VIP Frame Buffer II control port
        -- (byte-addressed; registers at 0x00, 0x14, 0x18, 0x1C)
        -- =====================================================================
        avm_vip_address      : out std_logic_vector(31 downto 0);
        avm_vip_write        : out std_logic;
        avm_vip_writedata    : out std_logic_vector(31 downto 0);
        avm_vip_read         : out std_logic;
        avm_vip_readdata     : in  std_logic_vector(31 downto 0);
        avm_vip_waitrequest  : in  std_logic;

        -- =====================================================================
        -- Avalon-MM Slave: JTAG host interface
        -- Byte-addressed. Word (4-byte) aligned accesses.
        -- =====================================================================
        avs_host_address     : in  std_logic_vector(11 downto 0);  -- 4 KB
        avs_host_write       : in  std_logic;
        avs_host_writedata   : in  std_logic_vector(31 downto 0);
        avs_host_read        : in  std_logic;
        avs_host_readdata    : out std_logic_vector(31 downto 0);
        avs_host_waitrequest : out std_logic
    );
end entity top_level;

architecture rtl of top_level is

    -- =========================================================================
    -- Register map (byte addresses within the JTAG slave window)
    -- =========================================================================
    --   0x000        CONTROL    [0]=pause_req, [1]=step_req (w1c/self-clearing)
    --   0x004        STATUS     [0]=paused,    [1]=running, [7:4]=state
    --   0x008        FRAME_W    (16-bit, lower half)
    --   0x00C        FRAME_H    (16-bit, lower half)
    --   0x010        TIME_MS    (32-bit; read = live counter; write = override)
    --   0x014        TIME_CTRL  [0]=write-enable override from bit above
    --   0x400..0x7FC IMEM       (1024 words = 4 KB window; low IMEM_ADDR_WIDTH used)
    -- =========================================================================

    constant IMEM_ADDR_WIDTH : integer := 8;  -- Match frame_processor default
    constant MS_TICKS        : integer := 50_000;  -- 50 MHz => 50000 cycles / ms

    -- Buffer addresses (top 16 bits; bytes addresses are these << 16)
    constant BUF_0_TOP : std_logic_vector(15 downto 0) := x"3000";
    constant BUF_1_TOP : std_logic_vector(15 downto 0) := x"3040";
    constant BUF_2_TOP : std_logic_vector(15 downto 0) := x"3080";

    -- Full byte addresses for VIP START_ADDR writes
    constant BUF_0_FULL : std_logic_vector(31 downto 0) := x"3000_0000";
    constant BUF_1_FULL : std_logic_vector(31 downto 0) := x"3040_0000";
    constant BUF_2_FULL : std_logic_vector(31 downto 0) := x"3080_0000";

    -- VIP register byte addresses (symbols-addressed)
    constant REG_CONTROL     : std_logic_vector(31 downto 0) := x"0000_0000";
    constant REG_FRAME_INFO  : std_logic_vector(31 downto 0) := x"0000_0014";
    constant REG_START_ADDR  : std_logic_vector(31 downto 0) := x"0000_0018";
    constant REG_READER_STAT : std_logic_vector(31 downto 0) := x"0000_001C";

    -- Frame info: 1024x768 progressive = (1024<<13) | 768 = 0x0080_0300
    constant FRAME_INFO_VAL  : std_logic_vector(31 downto 0) := x"0080_0300";

    -- =========================================================================
    -- Host-writable registers
    -- =========================================================================
    signal pause_req   : std_logic := '0';
    signal step_req    : std_logic := '0';
    signal resume_req  : std_logic := '0';
    signal paused      : std_logic := '0';  -- current pause state
    signal frame_w_reg : std_logic_vector(15 downto 0) := x"0400";  -- 1024 default
    signal frame_h_reg : std_logic_vector(15 downto 0) := x"0300";  -- 768  default
    signal time_ovr_en : std_logic := '0';
    signal time_ovr_val: std_logic_vector(31 downto 0) := (others => '0');

    -- IMEM programming path from host
    signal prog_we      : std_logic := '0';
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Button debounce (active-low inputs)
    -- =========================================================================
    signal key_m1, key_sync : std_logic_vector(1 downto 0) := "11";
    type dbn_cnt_t is array(0 to 1) of unsigned(19 downto 0);
    signal dbn_cnt   : dbn_cnt_t := (others => (others => '0'));
    signal key_stable: std_logic_vector(1 downto 0) := "11";
    signal key_stable_d : std_logic_vector(1 downto 0) := "11";
    signal key_press : std_logic_vector(1 downto 0);  -- 1-cycle pulse on press

    -- =========================================================================
    -- Time counter (hardware-generated ms)
    -- =========================================================================
    signal tick_cnt    : unsigned(15 downto 0) := (others => '0');
    signal time_ms_hw  : unsigned(31 downto 0) := (others => '0');
    signal time_ms_out : std_logic_vector(31 downto 0);

    -- =========================================================================
    -- Frame processor interface
    -- =========================================================================
    signal fp_frame_start : std_logic := '0';
    signal fp_frame_done  : std_logic;
    signal fp_fb_base     : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- Triple-buffer control FSM
    -- =========================================================================
    type ctrl_state_t is (
        CS_INIT_SETUP, CS_INIT_EXEC,    -- VIP init: frame_info, start_addr, go
        CS_IDLE,                         -- Waiting to trigger a frame
        CS_DRAWING,                      -- frame_processor is busy
        CS_POLL_REQ, CS_POLL_CAP, CS_POLL_EVAL,
        CS_QI_SETUP, CS_QI_EXEC,        -- Queue frame_info
        CS_QA_SETUP, CS_QA_EXEC,        -- Queue start_addr
        CS_ADVANCE
    );
    signal cstate : ctrl_state_t := CS_INIT_SETUP;

    signal init_step   : unsigned(1 downto 0) := "00";
    signal buf_idx     : unsigned(1 downto 0) := "00";
    signal draw_buf_full : std_logic_vector(31 downto 0) := BUF_0_FULL;
    signal draw_buf_top  : std_logic_vector(15 downto 0) := BUF_0_TOP;
    signal poll_latched  : std_logic_vector(31 downto 0) := (others => '0');

    -- VIP control master registered outputs (registered for timing closure)
    signal vip_addr_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal vip_wdata_r : std_logic_vector(31 downto 0) := (others => '0');
    signal vip_write_r : std_logic := '0';
    signal vip_read_r  : std_logic := '0';

begin

    -- =========================================================================
    -- Key synchronize + debounce + edge detect
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            key_m1   <= key_n;
            key_sync <= key_m1;
            key_stable_d <= key_stable;

            for i in 0 to 1 loop
                if key_sync(i) = key_stable(i) then
                    dbn_cnt(i) <= (others => '0');
                else
                    dbn_cnt(i) <= dbn_cnt(i) + 1;
                    if dbn_cnt(i) = to_unsigned(1_000_000, 20) then
                        key_stable(i) <= key_sync(i);
                        dbn_cnt(i)    <= (others => '0');
                    end if;
                end if;
            end loop;
        end if;
    end process;

    -- Press = stable went 1 -> 0 (active-low)
    key_press(0) <= key_stable_d(0) and not key_stable(0);
    key_press(1) <= key_stable_d(1) and not key_stable(1);

    -- =========================================================================
    -- Pause state: KEY[0] toggles pause, KEY[1] is single step
    -- Host can also force pause/unpause (set by JTAG write)
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                paused <= '0';
            elsif key_press(0) = '1' then
                paused <= not paused;
            elsif pause_req = '1' then
                paused <= '1';
            elsif resume_req = '1' then
                paused <= '0';
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Time counter: 1ms tick, pausable, steppable, host-overridable
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                tick_cnt   <= (others => '0');
                time_ms_hw <= (others => '0');
            elsif time_ovr_en = '1' then
                time_ms_hw <= unsigned(time_ovr_val);
                tick_cnt   <= (others => '0');
            elsif paused = '1' then
                if key_press(1) = '1' then
                    -- Step by ~16.67 ms (60 fps frame time)
                    time_ms_hw <= time_ms_hw + to_unsigned(16, 32);
                    -- Note: integer ms; if you want fractional, use a 16.16 fixed-point counter
                end if;
            else
                if tick_cnt = to_unsigned(MS_TICKS - 1, 16) then
                    tick_cnt   <= (others => '0');
                    time_ms_hw <= time_ms_hw + 1;
                else
                    tick_cnt <= tick_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    time_ms_out <= std_logic_vector(time_ms_hw);

    -- =========================================================================
    -- JTAG slave: register file and IMEM programming window
    -- Single-cycle access; no back-pressure needed for simple writes.
    -- =========================================================================
    avs_host_waitrequest <= '0';

    process(clk)
        variable addr : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            -- Defaults (self-clearing pulses)
            prog_we     <= '0';
            step_req    <= '0';
            pause_req   <= '0';
            resume_req  <= '0';
            time_ovr_en <= '0';

            if reset = '1' then
                frame_w_reg <= x"0400";
                frame_h_reg <= x"0300";
            elsif avs_host_write = '1' then
                addr := unsigned(avs_host_address);
                if addr(11 downto 10) = "00" then
                    -- Control/status/uniform region
                    case to_integer(addr(9 downto 2)) is
                        when 0 =>  -- CONTROL
                            -- [0]=pause, [1]=resume, [2]=step
                            if avs_host_writedata(0) = '1' then
                                pause_req <= '1';
                            end if;
                            if avs_host_writedata(1) = '1' then
                                resume_req <= '1';
                            end if;
                            step_req <= avs_host_writedata(2);
                        when 2 =>  -- FRAME_W (addr 0x008)
                            frame_w_reg <= avs_host_writedata(15 downto 0);
                        when 3 =>  -- FRAME_H (addr 0x00C)
                            frame_h_reg <= avs_host_writedata(15 downto 0);
                        when 4 =>  -- TIME_MS (addr 0x010) — write overrides
                            time_ovr_val <= avs_host_writedata;
                            time_ovr_en  <= '1';
                        when others => null;
                    end case;
                else
                    -- IMEM window (addr >= 0x400)
                    prog_we      <= '1';
                    prog_wr_addr <= avs_host_address(IMEM_ADDR_WIDTH+1 downto 2);
                    prog_wr_data <= avs_host_writedata;
                end if;
            end if;

            -- Simple read mux (combinational-style but registered for timing)
            if avs_host_read = '1' then
                case to_integer(unsigned(avs_host_address(9 downto 2))) is
                    when 1 =>  -- STATUS (0x004)
                        avs_host_readdata <= (0 => paused,
                                              1 => not paused,
                                              others => '0');
                    when 2 =>  -- FRAME_W
                        avs_host_readdata <= x"0000" & frame_w_reg;
                    when 3 =>  -- FRAME_H
                        avs_host_readdata <= x"0000" & frame_h_reg;
                    when 4 =>  -- TIME_MS
                        avs_host_readdata <= time_ms_out;
                    when others =>
                        avs_host_readdata <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Select current draw buffer's top-16 bits for frame_processor
    -- =========================================================================
    fp_fb_base <= draw_buf_top;

    -- =========================================================================
    -- Triple-buffer control FSM
    -- Sequence each frame:
    --   1. Wait for permission to draw (not paused, or stepped)
    --   2. Pulse frame_start; wait for frame_done
    --   3. Poll VIP ready bit
    --   4. Write frame_info + start_addr to VIP
    --   5. Advance draw buffer and loop
    -- =========================================================================
    process(clk)
        variable step_triggered : std_logic;
    begin
        if rising_edge(clk) then
            step_triggered := '0';
            fp_frame_start <= '0';
            vip_write_r    <= '0';
            vip_read_r     <= '0';

            if reset = '1' then
                cstate         <= CS_INIT_SETUP;
                init_step      <= "00";
                buf_idx        <= "00";
                draw_buf_full  <= BUF_0_FULL;
                draw_buf_top   <= BUF_0_TOP;
            else
                -- Step allowed only while paused; key_press or host step_req
                if paused = '1' and (key_press(1) = '1' or step_req = '1') then
                    step_triggered := '1';
                end if;

                case cstate is
                    -- -----------------------------------------------------
                    -- VIP init: write Frame Info, Start Addr (BUF_0), then Go.
                    -- We do NOT draw to BUF_0 first — the VIP will just show
                    -- whatever's in DDR (likely garbage) for one frame until
                    -- our first real frame is queued. Acceptable trade-off.
                    -- If you want a clean init, pre-clear BUF_0 (see notes).
                    -- -----------------------------------------------------
                    when CS_INIT_SETUP =>
                        vip_write_r <= '1';
                        case to_integer(init_step) is
                            when 0 =>
                                vip_addr_r  <= REG_FRAME_INFO;
                                vip_wdata_r <= FRAME_INFO_VAL;
                            when 1 =>
                                vip_addr_r  <= REG_START_ADDR;
                                vip_wdata_r <= BUF_0_FULL;
                            when 2 =>
                                vip_addr_r  <= REG_CONTROL;
                                vip_wdata_r <= x"0000_0001";  -- Go
                            when others =>
                                vip_write_r <= '0';
                        end case;
                        cstate <= CS_INIT_EXEC;

                    when CS_INIT_EXEC =>
                        vip_write_r <= '1';
                        if avm_vip_waitrequest = '0' then
                            vip_write_r <= '0';
                            if init_step = "10" then
                                -- VIP is running BUF_0. Next draw: BUF_1.
                                buf_idx       <= "01";
                                draw_buf_full <= BUF_1_FULL;
                                draw_buf_top  <= BUF_1_TOP;
                                cstate        <= CS_IDLE;
                            else
                                init_step <= init_step + 1;
                                cstate    <= CS_INIT_SETUP;
                            end if;
                        end if;

                    -- -----------------------------------------------------
                    -- IDLE: decide whether to draw the next frame
                    -- -----------------------------------------------------
                    when CS_IDLE =>
                        if paused = '0' or step_triggered = '1' then
                            fp_frame_start <= '1';
                            cstate         <= CS_DRAWING;
                        end if;

                    when CS_DRAWING =>
                        if fp_frame_done = '1' then
                            cstate <= CS_POLL_REQ;
                        end if;

                    -- -----------------------------------------------------
                    -- Poll VIP ready (bit 26 of reader status)
                    -- -----------------------------------------------------
                    when CS_POLL_REQ =>
                        vip_read_r <= '1';
                        vip_addr_r <= REG_READER_STAT;
                        cstate     <= CS_POLL_CAP;

                    when CS_POLL_CAP =>
                        vip_read_r <= '1';
                        if avm_vip_waitrequest = '0' then
                            poll_latched <= avm_vip_readdata;
                            vip_read_r   <= '0';
                            cstate       <= CS_POLL_EVAL;
                        end if;

                    when CS_POLL_EVAL =>
                        if poll_latched(26) = '1' then
                            cstate <= CS_QI_SETUP;
                        else
                            cstate <= CS_POLL_REQ;
                        end if;

                    -- -----------------------------------------------------
                    -- Queue this frame: Frame Info, then Start Addr
                    -- -----------------------------------------------------
                    when CS_QI_SETUP =>
                        vip_write_r <= '1';
                        vip_addr_r  <= REG_FRAME_INFO;
                        vip_wdata_r <= FRAME_INFO_VAL;
                        cstate      <= CS_QI_EXEC;

                    when CS_QI_EXEC =>
                        vip_write_r <= '1';
                        if avm_vip_waitrequest = '0' then
                            vip_write_r <= '0';
                            cstate      <= CS_QA_SETUP;
                        end if;

                    when CS_QA_SETUP =>
                        vip_write_r <= '1';
                        vip_addr_r  <= REG_START_ADDR;
                        vip_wdata_r <= draw_buf_full;
                        cstate      <= CS_QA_EXEC;

                    when CS_QA_EXEC =>
                        vip_write_r <= '1';
                        if avm_vip_waitrequest = '0' then
                            vip_write_r <= '0';
                            cstate      <= CS_ADVANCE;
                        end if;

                    -- -----------------------------------------------------
                    -- Rotate to next buffer
                    -- -----------------------------------------------------
                    when CS_ADVANCE =>
                        case to_integer(buf_idx) is
                            when 0 =>
                                buf_idx       <= "01";
                                draw_buf_full <= BUF_1_FULL;
                                draw_buf_top  <= BUF_1_TOP;
                            when 1 =>
                                buf_idx       <= "10";
                                draw_buf_full <= BUF_2_FULL;
                                draw_buf_top  <= BUF_2_TOP;
                            when others =>
                                buf_idx       <= "00";
                                draw_buf_full <= BUF_0_FULL;
                                draw_buf_top  <= BUF_0_TOP;
                        end case;
                        cstate <= CS_IDLE;
                end case;
            end if;
        end if;
    end process;

    avm_vip_address   <= vip_addr_r;
    avm_vip_writedata <= vip_wdata_r;
    avm_vip_write     <= vip_write_r;
    avm_vip_read      <= vip_read_r;

    -- =========================================================================
    -- Frame processor instantiation
    -- =========================================================================
    u_fp : entity work.frame_processor
        generic map (
            PC_WIDTH        => 16,
            IMEM_ADDR_WIDTH => IMEM_ADDR_WIDTH,
            WARP_SIZE       => 32,
            ADDR_WIDTH      => 32,
            DATA_WIDTH      => 128,
            REG_WIDTH       => 4
        )
        port map (
            clk               => clk,
            reset             => reset,
            avm_address       => avm_fp_address,
            avm_burstcount    => avm_fp_burstcount,
            avm_write         => avm_fp_write,
            avm_writedata     => avm_fp_writedata,
            avm_byteenable    => avm_fp_byteenable,
            avm_read          => avm_fp_read,
            avm_readdata      => avm_fp_readdata,
            avm_readdatavalid => avm_fp_readdatavalid,
            avm_waitrequest   => avm_fp_waitrequest,
            prog_we           => prog_we,
            prog_wr_addr      => prog_wr_addr,
            prog_wr_data      => prog_wr_data,
            frame_start       => fp_frame_start,
            frame_width       => frame_w_reg,
            frame_height      => frame_h_reg,
            time_ms           => time_ms_out,
            frame_done        => fp_frame_done,
            fb_base_addr      => fp_fb_base
        );

end architecture rtl;
