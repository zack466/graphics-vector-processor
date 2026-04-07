library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sync_fifo is
    generic (
        DATA_WIDTH : integer := 128;
        ADDR_WIDTH : integer := 6 -- Depth = 2^6 = 64
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        wr_en    : in  std_logic;
        din      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_en    : in  std_logic;
        dout     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        empty    : out std_logic;
        full     : out std_logic;
        count    : out integer range 0 to (2**ADDR_WIDTH)
    );
end entity;

architecture rtl of sync_fifo is
    type mem_t is array (0 to (2**ADDR_WIDTH)-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal ram : mem_t;
    attribute ramstyle : string;
    attribute ramstyle of ram : signal is "M10K";

    signal head, tail : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal r_count    : integer range 0 to (2**ADDR_WIDTH) := 0;
begin
    empty <= '1' when r_count = 0 else '0';
    full  <= '1' when r_count = (2**ADDR_WIDTH) else '0';
    count <= r_count;
    
    -- Combinational read output
    dout <= ram(to_integer(tail));

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                head <= (others => '0');
                tail <= (others => '0');
                r_count <= 0;
            else
                if wr_en = '1' and r_count < (2**ADDR_WIDTH) then
                    ram(to_integer(head)) <= din;
                    head <= head + 1;
                end if;
                
                if rd_en = '1' and r_count > 0 then
                    tail <= tail + 1;
                end if;

                if (wr_en = '1' and r_count < (2**ADDR_WIDTH)) and not (rd_en = '1' and r_count > 0) then
                    r_count <= r_count + 1;
                elsif (rd_en = '1' and r_count > 0) and not (wr_en = '1' and r_count < (2**ADDR_WIDTH)) then
                    r_count <= r_count - 1;
                end if;
            end if;
        end if;
    end process;
end architecture;
