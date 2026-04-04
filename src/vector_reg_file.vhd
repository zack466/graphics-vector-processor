library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity vector_reg_file is
    generic (
        ADDR_WIDTH : integer := 7 
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic; 
        
        -- PORT A: FPU Math Pipeline
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

        -- PORT B: Memory Controller Unit (MCU)
        rd_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rd_data_B    : out vector_t;
        
        wr_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data_B    : in  vector_t;
        write_mask_B : in  std_logic_vector(3 downto 0);
        we_B         : in  std_logic
    );
end entity;

architecture rtl of vector_reg_file is

    -- ========================================================================
    -- 1. COMPONENT-SPLIT M10K REPLICAS
    -- We split the 128-bit vector into four independent 32-bit (word_t) arrays.
    -- 4 Replicas * 4 Components = 16 discrete M10K blocks.
    -- ========================================================================
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of word_t;
    
    signal ram_1_x, ram_1_y, ram_1_z, ram_1_w : ram_type;
    signal ram_2_x, ram_2_y, ram_2_z, ram_2_w : ram_type;
    signal ram_3_x, ram_3_y, ram_3_z, ram_3_w : ram_type;
    signal ram_4_x, ram_4_y, ram_4_z, ram_4_w : ram_type;
    
    attribute ramstyle : string;
    attribute ramstyle of ram_1_x, ram_1_y, ram_1_z, ram_1_w : signal is "M10K";
    attribute ramstyle of ram_2_x, ram_2_y, ram_2_z, ram_2_w : signal is "M10K";
    attribute ramstyle of ram_3_x, ram_3_y, ram_3_z, ram_3_w : signal is "M10K";
    attribute ramstyle of ram_4_x, ram_4_y, ram_4_z, ram_4_w : signal is "M10K";
    
    -- ========================================================================
    -- 2. MCU WRITE COLLISION BUFFER (FIFO)
    -- ========================================================================
    type fifo_addr_array is array(0 to 63) of std_logic_vector(ADDR_WIDTH-1 downto 0);
    type fifo_data_array is array(0 to 63) of vector_t;
    type fifo_mask_array is array(0 to 63) of std_logic_vector(3 downto 0);
    
    signal fifo_addr : fifo_addr_array;
    signal fifo_data : fifo_data_array;
    signal fifo_mask : fifo_mask_array;
    
    signal fifo_head  : unsigned(5 downto 0) := (others => '0');
    signal fifo_tail  : unsigned(5 downto 0) := (others => '0');
    signal fifo_count : unsigned(6 downto 0) := (others => '0');

    -- ========================================================================
    -- 3. UNIFIED WRITE BUS
    -- ========================================================================
    signal unified_we   : std_logic;
    signal unified_addr : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal unified_data : vector_t;
    signal unified_mask : std_logic_vector(3 downto 0);

begin

    -- ========================================================================
    -- WRITE ARBITRATION & FIFO LOGIC
    -- ========================================================================
    process(clk)
        variable v_push : boolean;
        variable v_pop  : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                fifo_head  <= (others => '0');
                fifo_tail  <= (others => '0');
                fifo_count <= (others => '0');
                unified_we <= '0';
            else
                v_push := (we_B = '1');
                v_pop  := (we_A = '0' and fifo_count > 0);

                if v_push then
                    fifo_addr(to_integer(fifo_head)) <= wr_addr_B;
                    fifo_data(to_integer(fifo_head)) <= wr_data_B;
                    fifo_mask(to_integer(fifo_head)) <= write_mask_B;
                    fifo_head <= fifo_head + 1;
                end if;

                if we_A = '1' then
                    unified_we   <= '1';
                    unified_addr <= rd_addr_A;
                    unified_data <= rd_data_A;
                    unified_mask <= write_mask_A;
                
                elsif v_pop then
                    unified_we   <= '1';
                    unified_addr <= fifo_addr(to_integer(fifo_tail));
                    unified_data <= fifo_data(to_integer(fifo_tail));
                    unified_mask <= fifo_mask(to_integer(fifo_tail));
                    fifo_tail <= fifo_tail + 1;
                else
                    unified_we <= '0';
                end if;

                if v_push and not v_pop then
                    fifo_count <= fifo_count + 1;
                elsif v_pop and not v_push then
                    fifo_count <= fifo_count - 1;
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- M10K PHYSICAL RAM INFERENCE (No Byte Enables, No Read-Modify-Write)
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            
            -- X Component Blocks
            if unified_we = '1' and unified_mask(0) = '1' then
                ram_1_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_2_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_3_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_4_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
            end if;
            
            -- Y Component Blocks
            if unified_we = '1' and unified_mask(1) = '1' then
                ram_1_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_2_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_3_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_4_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
            end if;

            -- Z Component Blocks
            if unified_we = '1' and unified_mask(2) = '1' then
                ram_1_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_2_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_3_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_4_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
            end if;

            -- W Component Blocks
            if unified_we = '1' and unified_mask(3) = '1' then
                ram_1_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_2_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_3_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_4_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
            end if;
            
            -- DEDICATED READS (Automatically reconstructed into vector_t tuples)
            rs1_data(0) <= ram_1_x(to_integer(unsigned(rs1_addr)));
            rs1_data(1) <= ram_1_y(to_integer(unsigned(rs1_addr)));
            rs1_data(2) <= ram_1_z(to_integer(unsigned(rs1_addr)));
            rs1_data(3) <= ram_1_w(to_integer(unsigned(rs1_addr)));

            rs2_data(0) <= ram_2_x(to_integer(unsigned(rs2_addr)));
            rs2_data(1) <= ram_2_y(to_integer(unsigned(rs2_addr)));
            rs2_data(2) <= ram_2_z(to_integer(unsigned(rs2_addr)));
            rs2_data(3) <= ram_2_w(to_integer(unsigned(rs2_addr)));

            rs3_data(0) <= ram_3_x(to_integer(unsigned(rs3_addr)));
            rs3_data(1) <= ram_3_y(to_integer(unsigned(rs3_addr)));
            rs3_data(2) <= ram_3_z(to_integer(unsigned(rs3_addr)));
            rs3_data(3) <= ram_3_w(to_integer(unsigned(rs3_addr)));

            rd_data_B(0) <= ram_4_x(to_integer(unsigned(rd_addr_B)));
            rd_data_B(1) <= ram_4_y(to_integer(unsigned(rd_addr_B)));
            rd_data_B(2) <= ram_4_z(to_integer(unsigned(rd_addr_B)));
            rd_data_B(3) <= ram_4_w(to_integer(unsigned(rd_addr_B)));
            
        end if;
    end process;

end architecture rtl;
