library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity instruction_memory is
    generic (
        ADDR_WIDTH : integer := 8 -- 256 instructions max
    );
    port (
        clk      : in  std_logic;
        
        -- ==========================================
        -- WRITE PORT (Programming Interface)
        -- ==========================================
        we       : in  std_logic;
        wr_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data  : in  word_t;
        
        -- ==========================================
        -- READ PORT (Instruction Fetch Interface)
        -- ==========================================
        rd_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rd_data  : out word_t
    );
end entity instruction_memory;

architecture rtl of instruction_memory is

    -- Define the memory array
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of word_t;
    signal ram : ram_type := (others => (others => '0'));
    
    -- Register to hold the read address (Mandatory for M10K inference)
    signal rd_addr_reg : std_logic_vector(ADDR_WIDTH-1 downto 0);

begin

    process(clk)
    begin
        if rising_edge(clk) then
            -- Synchronous Write
            if we = '1' then
                ram(to_integer(unsigned(wr_addr))) <= wr_data;
            end if;
            
            -- Synchronous Read Address Registration
            rd_addr_reg <= rd_addr;
        end if;
    end process;

    -- Continuous assignment from the registered address
    rd_data <= ram(to_integer(unsigned(rd_addr_reg)));

end architecture rtl;
