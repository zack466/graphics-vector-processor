-- ============================================================================
-- FILE: pixel_buffer_ram.vhd
-- COMPONENT: pixel_buffer_ram
-- ============================================================================
--
-- Mixed-width Simple Dual-Port RAM, inferred as parallel M10K blocks.
-- The write port is 32-bit wide to match individual warp thread writes;
-- the read port is 128-bit wide to match the MCU's 4-pixel burst output.
--
-- Inputs:
--   clk      : System clock.
--   we       : Write enable for the warp write port.
--   wr_addr  : 5-bit write address. Bits [4:2] select the row (0-7);
--              bits [1:0] select the 32-bit bank (ram0..ram3).
--   wr_data  : 32-bit write data from a warp thread.
--   rd_en    : Read enable; gates the address register for the read port.
--   rd_addr  : 3-bit read address selecting one 128-bit row (0-7).
--
-- Outputs:
--   rd_data  : 128-bit read data, valid one cycle after rd_addr is registered.
--              Packed little-endian: Thread 0 in [31:0], Thread 3 in [127:96].
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity pixel_buffer_ram is
    port (
        clk      : in  std_logic;
        -- Write Port (Warp Interface: 32-bit x 32)
        we       : in  std_logic;
        wr_addr  : in  std_logic_vector(4 downto 0);
        wr_data  : in  word_t;
        -- Read Port (MCU Interface: 128-bit x 8)
        rd_en    : in  std_logic;
        rd_addr  : in  std_logic_vector(2 downto 0);
        rd_data  : out std_logic_vector(127 downto 0)
    );
end entity pixel_buffer_ram;

architecture rtl of pixel_buffer_ram is
    -- Four parallel 32-bit banks; concatenated on read to form one 128-bit word.
    -- Each bank holds 8 rows, addressed by wr_addr[4:2] / rd_addr.
    type ram_type is array (0 to 7) of word_t;
    signal ram0, ram1, ram2, ram3 : ram_type := (others => (others => '0'));

    signal rd_addr_reg : std_logic_vector(2 downto 0) := "000";
begin
    process(clk)
        variable v_wr_idx : integer range 0 to 7;
    begin
        if rising_edge(clk) then
            v_wr_idx := to_integer(unsigned(wr_addr(4 downto 2)));

            -- wr_addr[1:0] selects the 32-bit bank within the 128-bit row.
            if we = '1' then
                case wr_addr(1 downto 0) is
                    when "00" => ram0(v_wr_idx) <= wr_data;
                    when "01" => ram1(v_wr_idx) <= wr_data;
                    when "10" => ram2(v_wr_idx) <= wr_data;
                    when "11" => ram3(v_wr_idx) <= wr_data;
                    when others => null;
                end case;
            end if;

            -- Gate the read address register behind rd_en so the MCU controls
            -- when the pipeline advances (matches mcu_block_transfer rd_en logic).
            if rd_en = '1' then
                rd_addr_reg <= rd_addr;
            end if;
        end if;
    end process;

    -- Concatenate banks into a 128-bit word.
    -- Little-endian: Thread 0 in [31:0], Thread 3 in [127:96].
    rd_data <= ram3(to_integer(unsigned(rd_addr_reg))) &
               ram2(to_integer(unsigned(rd_addr_reg))) &
               ram1(to_integer(unsigned(rd_addr_reg))) &
               ram0(to_integer(unsigned(rd_addr_reg)));
end architecture rtl;
