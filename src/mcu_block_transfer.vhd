-- ============================================================================
-- COMPONENT: mcu_block_transfer
-- ============================================================================
-- PURPOSE:
--   Memory Control Unit for warp-wide block stores.  Accepts a pre-packed
--   1024-bit pixel buffer (32 × 32-bit RGBA pixels, supplied by warp_unit
--   after all 32 threads have been issued), then emits exactly 8 sequential
--   128-bit Avalon burst write beats to the avm_burst_bridge.
--
--   Pixel packing (snoop logic) is NOT done here — it is the caller's
--   responsibility to pack W[7:0] & Z[7:0] & Y[7:0] & X[7:0] per thread
--   and concatenate them into the flat 1024-bit pixel_buf_data vector before
--   asserting pixel_buf_valid.
--
-- FLAT BUFFER LAYOUT:
--   pixel_buf_data[i*32+31 : i*32] = packed 32-bit pixel for thread i
--   Beat k carries pixels 4k..4k+3:
--     tx_data = pixel(4k+3) & pixel(4k+2) & pixel(4k+1) & pixel(4k+0)
--   This places thread 0 in tx_data[31:0] and thread 3 in tx_data[127:96]
--   (little-endian thread ordering within each 128-bit Avalon word).
--
-- HANDSHAKE PROTOCOL:
--   1. Caller ensures pixel_buf_data, base_addr, exec_mask are stable.
--   2. Caller asserts pixel_buf_valid for exactly ONE clock cycle.
--   3. MCU asserts mem_stall on the same cycle (combinational) and latches
--      all inputs.
--   4. MCU issues a STORE command to the bridge (8-beat burst) via cmd/tx
--      channels, applying exec_mask as byte-enable per thread.
--   5. MCU deasserts mem_stall when the last beat is accepted by the bridge.
--
-- BYTE ENABLE MAPPING:
--   exec_mask bit i = '1' → thread i's 4 bytes all enabled ("1111").
--   exec_mask bit i = '0' → thread i's 4 bytes all disabled ("0000").
--   Beat k covers threads 4k..4k+3, so tx_byte_en[b*4+3:b*4] is set from
--   exec_mask[(k*4)+b] for b in 0..3.
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
        pixel_buf_valid   : in  std_logic;  -- 1-cycle pulse: buffer is filled, start burst
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        -- Pre-packed pixel buffer (from warp_unit pixel snoop buffer)
        -- pixel_buf_data[i*32+31 : i*32] = packed 32-bit pixel for thread i
        pixel_buf_data    : in  std_logic_vector(1023 downto 0);

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

    -- Internal latched copies of inputs (held stable during multi-cycle burst)
    type buffer_t is array(0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal latched_buf       : buffer_t;
    signal latched_base_addr : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal latched_exec_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal burst_count       : integer range 0 to 8 := 0;

begin

    -- Main Control FSM
    process(clk)
        variable avm_word : std_logic_vector(127 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state       <= IDLE;
                mem_stall   <= '0';
                cmd_valid   <= '0';
                tx_valid    <= '0';
                burst_count <= 0;
            else
                case state is
                    when IDLE =>
                        if pixel_buf_valid = '1' then
                            mem_stall        <= '1';
                            latched_base_addr <= base_addr;
                            latched_exec_mask <= exec_mask;
                            -- Unpack flat pixel_buf_data into per-thread array.
                            -- pixel_buf_data[i*32+31 : i*32] = thread i's packed pixel.
                            for i in 0 to WARP_SIZE-1 loop
                                latched_buf(i) <= pixel_buf_data(i*32+31 downto i*32);
                            end loop;
                            state <= STORE_CMD;
                        else
                            mem_stall <= '0';
                        end if;

                    when STORE_CMD =>
                        cmd_valid     <= '1';
                        cmd_is_store  <= '1';
                        cmd_addr      <= latched_base_addr;
                        cmd_burst_len <= std_logic_vector(to_unsigned(8, 8)); -- 8 beats = 32 pixels
                        if cmd_valid = '1' and cmd_ready = '1' then
                            cmd_valid   <= '0';
                            burst_count <= 0;
                            tx_valid    <= '1';
                            -- Drive first beat: pixels 0..3
                            avm_word := latched_buf(3) & latched_buf(2) & latched_buf(1) & latched_buf(0);
                            tx_data  <= avm_word;
                            -- Byte enables for threads 0..3
                            for b in 0 to 3 loop
                                if latched_exec_mask(b) = '1' then
                                    tx_byte_en((b*4)+3 downto b*4) <= "1111";
                                else
                                    tx_byte_en((b*4)+3 downto b*4) <= "0000";
                                end if;
                            end loop;
                            state <= STORE_BURST;
                        end if;

                    when STORE_BURST =>
                        if tx_valid = '1' and tx_ready = '1' then
                            if burst_count = 7 then
                                -- All 8 beats done
                                tx_valid  <= '0';
                                mem_stall <= '0';
                                state     <= IDLE;
                            else
                                burst_count <= burst_count + 1;
                                -- Drive next beat: pixels (burst_count+1)*4 .. (burst_count+1)*4+3
                                avm_word := latched_buf((burst_count+1)*4+3) &
                                            latched_buf((burst_count+1)*4+2) &
                                            latched_buf((burst_count+1)*4+1) &
                                            latched_buf((burst_count+1)*4+0);
                                tx_data <= avm_word;
                                -- Byte enables for next group of 4 threads
                                for b in 0 to 3 loop
                                    if latched_exec_mask(((burst_count+1)*4)+b) = '1' then
                                        tx_byte_en((b*4)+3 downto b*4) <= "1111";
                                    else
                                        tx_byte_en((b*4)+3 downto b*4) <= "0000";
                                    end if;
                                end loop;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
