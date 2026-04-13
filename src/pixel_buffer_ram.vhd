--------------------------------------------------------------------------------
-- Entity: pixel_buffer_ram
--
-- PURPOSE:
--   Mixed-width Simple Dual-Port RAM. Infers as parallel M10K blocks.
--   - Write Port: 32 bits wide, depth 32 (used by Warp threads).
--   - Read Port:  128 bits wide, depth 8  (used by MCU for 4-pixel bursting).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity pixel_buffer_ram is
    port (
        clk      : in  std_logic;

        -- ==========================================
        -- WRITE PORT (Warp Interface: 32-bit x 32)
        -- ==========================================
        we       : in  std_logic;
        wr_addr  : in  std_logic_vector(4 downto 0);
        wr_data  : in  word_t;

        -- ==========================================
        -- READ PORT (MCU Interface: 128-bit x 8)
        -- ==========================================
        rd_en    : in  std_logic;
        rd_addr  : in  std_logic_vector(2 downto 0);
        rd_data  : out std_logic_vector(127 downto 0)
    );
end entity pixel_buffer_ram;

architecture rtl of pixel_buffer_ram is

    -- Define arrays for threads: 0, 1, 2, and 3 within a 4-thread block.
    type ram_type is array (0 to 7) of word_t;
    signal ram0, ram1, ram2, ram3 : ram_type := (others => (others => '0'));

    -- Registered read address
    signal rd_addr_reg : std_logic_vector(2 downto 0) := "000";

begin

    process(clk)
        variable v_wr_idx : integer range 0 to 7;
    begin
        if rising_edge(clk) then
            v_wr_idx := to_integer(unsigned(wr_addr(4 downto 2)));

            -- Route the write to the correct parallel RAM bank
            if we = '1' then
                case wr_addr(1 downto 0) is
                    when "00" => ram0(v_wr_idx) <= wr_data;
                    when "01" => ram1(v_wr_idx) <= wr_data;
                    when "10" => ram2(v_wr_idx) <= wr_data;
                    when "11" => ram3(v_wr_idx) <= wr_data;
                    when others => null;
                end case;
            end if;

            -- Synchronous read pipeline, controlled by rd_en
            if rd_en = '1' then
                rd_addr_reg <= rd_addr;
            end if;
        end if;
    end process;

    -- Concatenate the 4 banks to form the 128-bit word. 
    -- Little-endian packing: Thread 0 is in [31:0], Thread 3 in [127:96].
    rd_data <= ram3(to_integer(unsigned(rd_addr_reg))) &
               ram2(to_integer(unsigned(rd_addr_reg))) &
               ram1(to_integer(unsigned(rd_addr_reg))) &
               ram0(to_integer(unsigned(rd_addr_reg)));

end architecture rtl;
