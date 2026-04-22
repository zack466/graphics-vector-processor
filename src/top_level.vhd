-- ============================================================================
-- FILE: top_level.vhd
-- COMPONENT: Top Level Frame Processor interface
--
-- The top-level design which drives the frame processor entity and interfaces
-- with 1) the Altera VIP Framebuffer II IP, 2) the DDR3 RAM on the system, and
-- 3) a JTAG host controller. Intended for use on the DE10-Nano, a Cyclone-V
-- SoC. Can be integrated into a SoC design using the Quartus Platform Designer
-- (previously Qsys).
--
-- Inputs:
--   - clk, reset: system clock/reset
--   - key_n: 2 bits of an active-low push-button switch from the board. Used
--            to control pause/resume. Key 0 is used to pause/resume, while
--            Key 1 is used to step frame-by-frame.
--   - avs_host_*: a 32-bit Avalon-MM slave interface, makes a set of control
--                 registers available to the host to write to through JTAG.
--                 Also allows direct write access to instruction memory so
--                 shader code can be loaded and modified at runtime.
--
--  Outputs:
--   - avm_fp_*: a 128-bit Avalon-MM master control that can read/write to the
--               system's 1 GB of SDRAM, used to write to the framebuffer.
--   - avm_vip_*: a 32-bit Avalon-MM master control that controls the Altera
--                VIP Framebuffer II IP, implements triple buffering using a
--                state machine.
--
--  Entities:
--   - frame_processor (u_fp): the core processor responsible for computing pixel
--                             values and writing them to RAM through the
--                             128-bit Avalon-MM interface. Is triggered by the
--                             frame_start signal, and returns by pulsing the
--                             frame_done signal.
--  State Machines:
--   - u_framebuffer: keeps frame processor in sync with the framebuffer through
--                    triple buffering. When unpaused, will continually trigger
--                    the frame processor to write to a buffer in memory, then
--                    notify the framebuffer IP that a new frame is available.
--                    Triple-buffering ensures no screen tearing.
--
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_level is
    port (
        clk                  : in  std_logic;  -- system clock
        reset                : in  std_logic;  -- system reset

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

    -- =========================================================================
    -- Altera VIP Framebuffer II controls/constants
    -- =========================================================================

    -- Full byte addresses for VIP START_ADDR writes. Only the top 16 bits are
    -- fed to the frame processor as the current framebuffer base address. The
    -- framebuffer state machine cycles through these framebuffers to implement
    -- triple buffering.
    constant BUF_0 : std_logic_vector(31 downto 0) := x"0000_0000";
    constant BUF_1 : std_logic_vector(31 downto 0) := x"1000_0000";
    constant BUF_2 : std_logic_vector(31 downto 0) := x"2000_0000";

    -- VIP register byte addresses (symbols-addressed)
    constant REG_CONTROL     : std_logic_vector(31 downto 0) := x"0000_0000";
    constant REG_FRAME_INFO  : std_logic_vector(31 downto 0) := x"0000_0014";
    constant REG_START_ADDR  : std_logic_vector(31 downto 0) := x"0000_0018";
    constant REG_READER_STAT : std_logic_vector(31 downto 0) := x"0000_001C";

    -- Frame info: 1024x768 progressive = (1024<<13) | 768 = 0x0080_0300
    constant FRAME_INFO_VAL  : std_logic_vector(31 downto 0) := x"0080_0300";

    -- VIP control master registered outputs (registered for timing closure)
    signal vip_addr_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal vip_wdata_r : std_logic_vector(31 downto 0) := (others => '0');
    signal vip_write_r : std_logic := '0';
    signal vip_read_r  : std_logic := '0';

    -- =========================================================================
    -- Host-writable registers
    -- =========================================================================
    signal pause_req   : std_logic := '0';  -- if a pause has been requested by the host
    signal step_req    : std_logic := '0';  -- if a step has been requested by the host
    signal resume_req  : std_logic := '0';  -- if a resume has been requested by the host
    signal paused      : std_logic := '0';  -- if the system is paused (not computing a frame)
    signal frame_w_reg : std_logic_vector(15 downto 0) := x"0400";  -- current frame width, 1024 default
    signal frame_h_reg : std_logic_vector(15 downto 0) := x"0300";  -- current frame width, 768  default
    signal time_ovr_en : std_logic := '0';                          -- timer overwrite enable
    signal time_ovr_val: std_logic_vector(31 downto 0) := (others => '0');  -- timer overwrite value

    -- IMEM programming path from host
    signal prog_we      : std_logic := '0';     -- write enable
    signal prog_wr_addr : std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Push Button debounce (active-low inputs)
    -- =========================================================================
    constant DEBOUNCE_COUNT  : integer = 1_000_000;  -- 10 ms debounce timer, assuming 50 MHz clock
    type dbn_cnt_t is array(0 to 1) of unsigned(19 downto 0);
    signal dbn_cnt           : dbn_cnt_t := (others => (others => '0'));    -- debounce count
    signal key_m1, key_sync  : std_logic_vector(1 downto 0) := "11";        -- sync DFFs
    signal key_stable        : std_logic_vector(1 downto 0) := "11";        -- debounced key
    signal key_stable_d      : std_logic_vector(1 downto 0) := "11";        -- debounced key (previous)
    signal key_press         : std_logic_vector(1 downto 0);                -- 1-cycle pulse on press

    -- =========================================================================
    -- Time counter (hardware-generated ms)
    -- =========================================================================
    signal tick_cnt    : unsigned(15 downto 0) := (others => '0');  -- clock divider
    signal time_ms_hw  : unsigned(31 downto 0) := (others => '0');  -- elapsed time in ms
    signal time_ms_out : std_logic_vector(31 downto 0);             -- elapsed time bits

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
        CS_INIT_SETUP, CS_INIT_EXEC,        -- VIP init: frame_info, start_addr, go
        CS_IDLE,                            -- Waiting to trigger a frame
        CS_DRAWING,                         -- frame_processor is busy
        CS_POLL_REQ, CS_POLL_CAP, CS_POLL_EVAL, -- waiting for framebuffer (polling loop)
        CS_QI_SETUP, CS_QI_EXEC,            -- Queue frame_info
        CS_QA_SETUP, CS_QA_EXEC,            -- Queue start_addr
        CS_ADVANCE
    );
    signal cstate : ctrl_state_t := CS_INIT_SETUP;

    signal init_step    : unsigned(1 downto 0) := "00"; -- current step of framebuffer initialization
    signal buf_idx      : unsigned(1 downto 0) := "00"; -- index of current draw buffer
    signal draw_buf     : std_logic_vector(31 downto 0) := BUF_0;   -- current draw buffer address
    signal poll_latched : std_logic_vector(31 downto 0) := (others => '0'); -- used in framebuffer polling loop

begin

    -- =========================================================================
    -- Input key synchronize + debounce + edge detect
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            -- async raw key inputs synchronized through two DFFs
            key_m1   <= key_n;
            key_sync <= key_m1;

            -- debounced (previous) key input
            key_stable_d <= key_stable;

            -- debounces both keys in parallel
            for i in 0 to 1 loop
                -- if input keys have changed, then count how many clocks they
                -- have been stable for. If held for long enough, then counts
                -- as a press and is shifted into key_stable.
                if key_sync(i) = key_stable(i) then
                    dbn_cnt(i) <= (others => '0');
                else
                    dbn_cnt(i) <= dbn_cnt(i) + 1;
                    if dbn_cnt(i) = to_unsigned(DEBOUNCE_COUNT, 20) then
                        key_stable(i) <= key_sync(i);
                        dbn_cnt(i)    <= (others => '0');
                    end if;
                end if;
            end loop;
        end if;
    end process;

    -- Press = stable went 1 -> 0 (active-low edge detection)
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
    -- Used as a uniform, passed into the frame processor so can be used in
    -- shaders that are time-dependent.
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
                -- If stepping frame-by-frame, increment time by ~16.67 ms (60
                -- fps frame time)
                if key_press(1) = '1' then
                    time_ms_hw <= time_ms_hw + to_unsigned(16, 32);
                end if;
            else
                -- If not paused, increase time using a clock divider
                if tick_cnt = to_unsigned(MS_TICKS - 1, 16) then
                    tick_cnt   <= (others => '0');
                    time_ms_hw <= time_ms_hw + 1;
                else
                    tick_cnt <= tick_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    time_ms_out <= std_logic_vector(time_ms_hw);  -- expose to JTAG interface

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
                -- default resolution
                frame_w_reg <= x"0400"; -- width of 1024
                frame_h_reg <= x"0300"; -- height of 768
            elsif avs_host_write = '1' then
                -- JTAG host is writing to a register
                addr := unsigned(avs_host_address);
                if addr(11 downto 10) = "00" then
                    -- Control/status/uniform region (addr < 0x400).
                    -- Directly writes to registers.
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
                    -- IMEM window (addr >= 0x400).
                    -- Forwards write signals to instruction memory RAM.
                    prog_we      <= '1';
                    prog_wr_addr <= avs_host_address(IMEM_ADDR_WIDTH+1 downto 2);
                    prog_wr_data <= avs_host_writedata;
                end if;
            end if;

            -- Simple read mux (combinational-style but registered for timing)
            if avs_host_read = '1' then
                -- JTAG host is reading from a register
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
    -- VIP Framebuffer II triple-buffering control FSM
    --
    -- Sequence each frame:
    --   1. Wait for permission to draw (not paused, or stepped)
    --   2. Pulse frame_start; wait for frame_done
    --   3. Poll VIP ready bit
    --   4. Write frame_info + start_addr to VIP
    --   5. Advance draw buffer and loop
    --
    -- See official Altera documentation for control registers and logic.
    -- https://docs.altera.com/r/docs/683416/22.1/video-and-image-processing-suite-user-guide/frame-buffer-ii-ip
    -- =========================================================================
    u_framebuffer: process(clk)
        variable step_triggered : std_logic;
    begin
        if rising_edge(clk) then
            step_triggered := '0';
            fp_frame_start <= '0';
            vip_write_r    <= '0';
            vip_read_r     <= '0';

            if reset = '1' then
                cstate      <= CS_INIT_SETUP;
                init_step   <= "00";
                buf_idx     <= "00";
                draw_buf    <= BUF_0;
            else
                -- Step allowed only while paused; key_press or host step_req
                if paused = '1' and (key_press(1) = '1' or step_req = '1') then
                    step_triggered := '1';
                end if;

                case cstate is
                    -- -----------------------------------------------------
                    -- VIP init: write Frame Info, Start Addr (BUF_0), then Go.
                    -- -----------------------------------------------------
                    when CS_INIT_SETUP =>
                        vip_write_r <= '1';
                        case to_integer(init_step) is
                            when 0 =>
                                vip_addr_r  <= REG_FRAME_INFO;
                                vip_wdata_r <= FRAME_INFO_VAL;
                            when 1 =>
                                vip_addr_r  <= REG_START_ADDR;
                                vip_wdata_r <= BUF_0;
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
                                buf_idx     <= "01";
                                draw_buf    <= BUF_1;
                                cstate      <= CS_IDLE;
                            else
                                init_step   <= init_step + 1;
                                cstate      <= CS_INIT_SETUP;
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
                        vip_wdata_r <= draw_buf;
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
                                buf_idx     <= "01";
                                draw_buf    <= BUF_1;
                            when 1 =>
                                buf_idx     <= "10";
                                draw_buf    <= BUF_2;
                            when others =>
                                buf_idx     <= "00";
                                draw_buf    <= BUF_0;
                        end case;
                        cstate <= CS_IDLE;
                end case;
            end if;
        end if;
    end process;

    -- Output registered VIP controls to the framebuffer IP
    avm_vip_address   <= vip_addr_r;
    avm_vip_writedata <= vip_wdata_r;
    avm_vip_write     <= vip_write_r;
    avm_vip_read      <= vip_read_r;

    -- =========================================================================
    -- Select current draw buffer's top-16 bits for frame_processor. Used to
    -- compute the right address to write to for each pixel.
    -- =========================================================================
    fp_fb_base <= draw_buf(31 downto 16);

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

            -- SDRAM interface
            avm_address       => avm_fp_address,
            avm_burstcount    => avm_fp_burstcount,
            avm_write         => avm_fp_write,
            avm_writedata     => avm_fp_writedata,
            avm_byteenable    => avm_fp_byteenable,
            avm_read          => avm_fp_read,
            avm_readdata      => avm_fp_readdata,
            avm_readdatavalid => avm_fp_readdatavalid,
            avm_waitrequest   => avm_fp_waitrequest,

            -- instruction memory write interface
            prog_we           => prog_we,
            prog_wr_addr      => prog_wr_addr,
            prog_wr_data      => prog_wr_data,

            -- Shader uniforms
            frame_width       => frame_w_reg,
            frame_height      => frame_h_reg,
            time_ms           => time_ms_out,

            -- procesor controls
            frame_start       => fp_frame_start,
            frame_done        => fp_frame_done,
            fb_base_addr      => fp_fb_base
        );

end architecture rtl;
