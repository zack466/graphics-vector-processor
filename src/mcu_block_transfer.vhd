-- ============================================================================
-- COMPONENT: mcu_block_transfer
-- ============================================================================
-- PURPOSE:
--   Memory Control Unit for warp-wide block stores. Serves as the pipeline
--   between the warp's M10K pixel buffer and the Avalon burst bridge.
--
--   Because the M10K RAM has a 1-cycle read latency, this MCU manages a 
--   1-cycle pipeline. It connects the Avalon `tx_ready` directly back to the 
--   RAM's `rd_en` signal. If the memory bridge stalls, the M10K read pipeline 
--   freezes holding the active word steady without losing data.
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity mcu_block_transfer is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- Processor Control
        pixel_buf_valid   : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        mem_stall         : out std_logic;

        -- Interface to warp_unit's pixel_buffer_ram (M10K)
        pixel_rd_en       : out std_logic;
        pixel_rd_addr     : out std_logic_vector(2 downto 0);
        pixel_rd_data     : in  std_logic_vector(DATA_WIDTH-1 downto 0);

        -- Avalon Burst Bridge Command Channel
        cmd_valid         : out std_logic;
        cmd_is_store      : out std_logic;
        cmd_addr          : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : out std_logic_vector(7 downto 0);
        cmd_ready         : in  std_logic;

        -- Avalon Burst Bridge TX Channel (Writes)
        tx_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        tx_byte_en        : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        tx_valid          : out std_logic;
        tx_ready          : in  std_logic
    );
end entity;

architecture rtl of mcu_block_transfer is

    type state_t is (IDLE, STORE_CMD, STORE_BURST);
    signal state : state_t := IDLE;

    signal latched_base_addr : std_logic_vector(ADDR_WIDTH-1 downto 0);
    
    signal cmd_valid_reg : std_logic := '0';
    signal tx_valid_reg  : std_logic := '0';

    -- tx_count: Number of beats accepted by the Avalon bridge.
    -- rd_count: Number of beats requested from the M10K RAM.
    signal tx_count : integer range 0 to 7 := 0;
    signal rd_count : integer range 0 to 7 := 0;

begin

    -- Output Command Mapping
    cmd_valid     <= cmd_valid_reg;
    cmd_is_store  <= '1';
    cmd_addr      <= latched_base_addr;
    cmd_burst_len <= std_logic_vector(to_unsigned(8, 8)); -- 8 beats = 32 pixels

    tx_valid      <= tx_valid_reg;
    tx_data       <= pixel_rd_data; -- 128-bit straight through from M10K

    -- ========================================================================
    -- PIPELINE CONTROL LOGIC
    -- ========================================================================
    
    -- RAM Read Enable: Asserted when we need to prefetch, or advance the burst pipeline.
    pixel_rd_en <= '1' when (state = IDLE and pixel_buf_valid = '1') else
                   '1' when (state = STORE_CMD and cmd_ready = '1' and cmd_valid_reg = '1') else
                   '1' when (state = STORE_BURST and tx_ready = '1' and tx_valid_reg = '1') else
                   '0';

    -- RAM Read Address: Combinational routing of the count to grab data 1-cycle early.
    process(state, rd_count, pixel_buf_valid)
    begin
        if state = IDLE and pixel_buf_valid = '1' then
            pixel_rd_addr <= "000"; -- Force fetch beat 0
        else
            pixel_rd_addr <= std_logic_vector(to_unsigned(rd_count, 3));
        end if;
    end process;

    -- ========================================================================
    -- BYTE ENABLE MULTIPLEXER
    -- ========================================================================
    tx_byte_en <= (others => '1');

    -- Stall the warp immediately on the same cycle valid is asserted, 
    -- and hold it until the FSM successfully returns to IDLE.
    mem_stall <= '0' when (state = IDLE and pixel_buf_valid = '0') else '1';

    -- ========================================================================
    -- FSM SEQUENTIAL LOGIC
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state         <= IDLE;
                cmd_valid_reg <= '0';
                tx_valid_reg  <= '0';
                tx_count      <= 0;
                rd_count      <= 0;
            else
                case state is
                    when IDLE =>
                        if pixel_buf_valid = '1' then
                            latched_base_addr <= base_addr;
                            
                            -- Initialize counters for burst
                            rd_count          <= 0;
                            tx_count          <= 0;
                            cmd_valid_reg     <= '1';
                            state             <= STORE_CMD;
                        end if;

                    when STORE_CMD =>
                        if cmd_ready = '1' and cmd_valid_reg = '1' then
                            cmd_valid_reg <= '0';
                            tx_valid_reg  <= '1';
                            -- Beat 0 is already latching inside the RAM this cycle.
                            -- Advance rd_count to fetch beat 1 next cycle.
                            rd_count      <= 1; 
                            state         <= STORE_BURST;
                        end if;

                    when STORE_BURST =>
                        -- Pipeline advances only if the Avalon bridge accepts the current beat
                        if tx_ready = '1' and tx_valid_reg = '1' then
                            if tx_count = 7 then
                                -- Burst complete
                                tx_valid_reg <= '0';
                                state        <= IDLE;
                            else
                                -- Advance TX beat
                                tx_count <= tx_count + 1;
                                -- Cap rd_count at 7 to prevent rolling over the RAM bound
                                if rd_count < 7 then
                                    rd_count <= rd_count + 1;
                                end if;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
