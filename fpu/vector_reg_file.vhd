library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity vector_reg_file is
    generic (
        ADDR_WIDTH : integer := 7 -- 128 registers (32 threads * 4 vectors)
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic; -- Ignored for RAM inference
        
        -- ==========================================
        -- PORT A: FPU Math Pipeline
        -- (3 Dedicated Reads, 1 Dedicated Write)
        -- ==========================================
        rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs3_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs1_data     : out vector_t;
        rs2_data     : out vector_t;
        rs3_data     : out vector_t;
        
        rd_addr_A    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rd_data_A    : in  vector_t;
        write_mask_A : in  std_logic_vector(3 downto 0);
        we_A         : in  std_logic;

        -- ==========================================
        -- PORT B: Memory Controller Unit (MCU)
        -- (1 Dedicated Read, 1 Dedicated Write)
        -- ==========================================
        rd_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rd_data_B    : out vector_t;
        
        wr_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data_B    : in  vector_t;
        write_mask_B : in  std_logic_vector(3 downto 0);
        we_B         : in  std_logic
    );
end entity;

architecture rtl of vector_reg_file is

    -- Define the memory array type
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of vector_t;
    
    -- Replicate the RAM FOUR times to support 4 independent read ports.
    signal ram_bank_1 : ram_type;
    signal ram_bank_2 : ram_type;
    signal ram_bank_3 : ram_type;
    signal ram_bank_4 : ram_type;
    
    -- Explicitly tell Quartus synthesis to map these arrays to M10K blocks
    attribute ramstyle : string;
    attribute ramstyle of ram_bank_1 : signal is "M10K";
    attribute ramstyle of ram_bank_2 : signal is "M10K";
    attribute ramstyle of ram_bank_3 : signal is "M10K";
    attribute ramstyle of ram_bank_4 : signal is "M10K";

    -- Port B Address Multiplexers
    signal addr_b_1, addr_b_2, addr_b_3, addr_b_4 : std_logic_vector(ADDR_WIDTH-1 downto 0);

begin

    -- If the MCU is writing, hijack Port B's address. Otherwise, serve the standard reads.
    addr_b_1 <= wr_addr_B when we_B = '1' else rs1_addr;
    addr_b_2 <= wr_addr_B when we_B = '1' else rs2_addr;
    addr_b_3 <= wr_addr_B when we_B = '1' else rs3_addr;
    addr_b_4 <= wr_addr_B when we_B = '1' else rd_addr_B;

    process(clk)
    begin
        if rising_edge(clk) then
            
            -- ==========================================
            -- PORT A: FPU Pipeline Write
            -- ==========================================
            if we_A = '1' then
                for i in 0 to 3 loop
                    if write_mask_A(i) = '1' then
                        ram_bank_1(to_integer(unsigned(rd_addr_A)))(i) <= rd_data_A(i);
                        ram_bank_2(to_integer(unsigned(rd_addr_A)))(i) <= rd_data_A(i);
                        ram_bank_3(to_integer(unsigned(rd_addr_A)))(i) <= rd_data_A(i);
                        ram_bank_4(to_integer(unsigned(rd_addr_A)))(i) <= rd_data_A(i);
                    end if;
                end loop;
            end if;

            -- ==========================================
            -- PORT B: MCU Write & All Reads
            -- ==========================================
            if we_B = '1' then
                for i in 0 to 3 loop
                    if write_mask_B(i) = '1' then
                        ram_bank_1(to_integer(unsigned(addr_b_1)))(i) <= wr_data_B(i);
                        ram_bank_2(to_integer(unsigned(addr_b_2)))(i) <= wr_data_B(i);
                        ram_bank_3(to_integer(unsigned(addr_b_3)))(i) <= wr_data_B(i);
                        ram_bank_4(to_integer(unsigned(addr_b_4)))(i) <= wr_data_B(i);
                    end if;
                end loop;
            end if;
            
            -- Reads must be synchronous for block RAM inference
            rs1_data  <= ram_bank_1(to_integer(unsigned(addr_b_1)));
            rs2_data  <= ram_bank_2(to_integer(unsigned(addr_b_2)));
            rs3_data  <= ram_bank_3(to_integer(unsigned(addr_b_3)));
            rd_data_B <= ram_bank_4(to_integer(unsigned(addr_b_4)));
            
        end if;
    end process;

end architecture rtl;
