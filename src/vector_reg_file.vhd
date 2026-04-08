library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

-- =========================================================================================
-- MODULE: VECTOR REGISTER FILE (M10K OPTIMIZED)
-- =========================================================================================
-- DESCRIPTION:
-- This module implements a highly-banked vector register file optimized for synthesis 
-- into Intel/Altera M10K block RAM. It stores 128-bit vectors (4x 32-bit words) and 
-- supports element-level write masking (X, Y, Z, W).
--
-- To support the massive read bandwidth required by a superscalar or vectorized FPU
-- without using pure logic registers (ALMs), the memory is physically replicated.
--
-- USAGE & ARBITRATION:
-- * Port A (FPU): Designed for the Math Pipeline. Has STRICT PRIORITY for writes.
-- * Port B (MCU): Designed for the Memory Controller. Has secondary write priority.
--   If Port A and Port B attempt to write on the exact same clock cycle, Port A 
--   wins. Port B's write is pushed to a FIFO and will automatically drain into the 
--   RAM on the next available clock cycle where Port A is not writing.
--
-- PIPELINE LATENCIES (CLOCK CYCLES):
-- * Read (Port A & B): 1 Cycle
--   Address is provided on clock N. Data is stable and available on clock N+1.
--
-- * Write (Port A - FPU): 2 Cycles
--   Write enable/data provided on clock N. Propagates through arbiter on clock N+1.
--   Physically written to M10K RAM on clock N+2. Data available for read on N+3.
--
-- * Write (Port B - MCU): 3 Cycles
--   Write enable/data provided on clock N. Pushed to FIFO on clock N+1.
--   Popped to arbiter on N+2. Written to RAM on N+3. Data available for read on N+4.
-- =========================================================================================

entity vector_reg_file is
    generic (
        ADDR_WIDTH : integer := 7 -- 128 standard registers by default
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic; 
        
    -- PORT A: FPU Math Pipeline
    -- Provides 3 simultaneous vector reads and 1 masked vector write
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
    -- Provides 1 vector read (for store instructions) and 1 vector write (for load instructions)
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
    -- ========================================================================
    -- M10K blocks natively support only 1 Read and 1 Write port (or 2 Reads).
    -- To achieve 4 simultaneous reads (rs1, rs2, rs3, rd_B), we must duplicate
    -- the exact same memory contents across 4 identical physical RAM banks.
    -- Furthermore, to support component masking without complex Read-Modify-Write
    -- logic, we split the 128-bit vector into four independent 32-bit arrays.
    -- Total: 4 Replicas * 4 Components (x,y,z,w) = 16 discrete M10K block arrays.
    -- ========================================================================
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of word_t;
    
    -- Replica 1 (Feeds rs1_data)
    signal ram_1_x, ram_1_y, ram_1_z, ram_1_w : ram_type := (others => (others => '0'));
    -- Replica 2 (Feeds rs2_data)
    signal ram_2_x, ram_2_y, ram_2_z, ram_2_w : ram_type := (others => (others => '0'));
    -- Replica 3 (Feeds rs3_data)
    signal ram_3_x, ram_3_y, ram_3_z, ram_3_w : ram_type := (others => (others => '0'));
    -- Replica 4 (Feeds rd_data_B)
    signal ram_4_x, ram_4_y, ram_4_z, ram_4_w : ram_type := (others => (others => '0'));
    
    -- Explicitly instruct the synthesis tool (Quartus) to map these to M10K hardware
    attribute ramstyle : string;
    attribute ramstyle of ram_1_x, ram_1_y, ram_1_z, ram_1_w : signal is "M10K";
    attribute ramstyle of ram_2_x, ram_2_y, ram_2_z, ram_2_w : signal is "M10K";
    attribute ramstyle of ram_3_x, ram_3_y, ram_3_z, ram_3_w : signal is "M10K";
    attribute ramstyle of ram_4_x, ram_4_y, ram_4_z, ram_4_w : signal is "M10K";
    
    -- ========================================================================
    -- 2. MCU WRITE COLLISION BUFFER (FIFO)
    -- ========================================================================
    -- Since M10K blocks only have 1 write port, we cannot write from Port A 
    -- and Port B simultaneously. This FIFO caches Port B writes if Port A is 
    -- currently using the unified write bus.
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
    -- The single pipeline register that feeds directly into the M10K write ports.
    -- ========================================================================
    signal unified_we   : std_logic;
    signal unified_addr : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal unified_data : vector_t;
    signal unified_mask : std_logic_vector(3 downto 0);

begin

    -- ========================================================================
    -- WRITE ARBITRATION & FIFO LOGIC
    -- Manages priorities between Port A (FPU) and Port B (MCU).
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
                -- Port B pushes to the FIFO automatically whenever it asserts WE
                v_push := (we_B = '1');
                
                -- We pop from the FIFO ONLY if there is data waiting AND Port A is inactive
                v_pop  := (we_A = '0' and fifo_count > 0);

                -- Enqueue Port B data
                if v_push then
                    fifo_addr(to_integer(fifo_head)) <= wr_addr_B;
                    fifo_data(to_integer(fifo_head)) <= wr_data_B;
                    fifo_mask(to_integer(fifo_head)) <= write_mask_B;
                    fifo_head <= fifo_head + 1;
                end if;

                -- Arbiter Routing
                if we_A = '1' then
                    -- Priority 1: Port A active. Route A to the Unified Bus directly.
                    unified_we   <= '1';
                    unified_addr <= rd_addr_A;
                    unified_data <= rd_data_A;
                    unified_mask <= write_mask_A;
                
                elsif v_pop then
                    -- Priority 2: Port A inactive, FIFO has data. Pop FIFO to Unified Bus.
                    unified_we   <= '1';
                    unified_addr <= fifo_addr(to_integer(fifo_tail));
                    unified_data <= fifo_data(to_integer(fifo_tail));
                    unified_mask <= fifo_mask(to_integer(fifo_tail));
                    fifo_tail <= fifo_tail + 1;
                else
                    -- Priority 3: Idle. Keep write disabled to prevent data corruption.
                    unified_we <= '0';
                end if;

                -- FIFO Depth Tracking
                if v_push and not v_pop then
                    fifo_count <= fifo_count + 1;
                elsif v_pop and not v_push then
                    fifo_count <= fifo_count - 1;
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- M10K PHYSICAL RAM INFERENCE
    -- Synchronous process mapping writes from the unified bus to all replicas,
    -- and reads from specific replicas to the output ports.
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            
            -- --- WRITE OPERATIONS ---
            -- Data is fanned out and written to ALL replicas simultaneously
            -- to ensure memory consistency. It is further gated by the write mask.


            -- X Component Blocks (Bit 0 of Mask)
            if unified_we = '1' and unified_mask(0) = '1' then
                ram_1_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_2_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_3_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
                ram_4_x(to_integer(unsigned(unified_addr))) <= unified_data(0);
            end if;
            
            -- Y Component Blocks (Bit 1 of Mask)
            if unified_we = '1' and unified_mask(1) = '1' then
                ram_1_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_2_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_3_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
                ram_4_y(to_integer(unsigned(unified_addr))) <= unified_data(1);
            end if;

            -- Z Component Blocks (Bit 2 of Mask)
            if unified_we = '1' and unified_mask(2) = '1' then
                ram_1_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_2_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_3_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
                ram_4_z(to_integer(unsigned(unified_addr))) <= unified_data(2);
            end if;

            -- W Component Blocks (Bit 3 of Mask)
            if unified_we = '1' and unified_mask(3) = '1' then
                ram_1_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_2_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_3_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
                ram_4_w(to_integer(unsigned(unified_addr))) <= unified_data(3);
            end if;
            
            -- --- READ OPERATIONS ---
            -- Each read port queries a discrete replica. 
            -- The components are immediately repacked into the `vector_t` tuples.

            -- Read Port A: Source 1 (Replica 1)
            rs1_data(0) <= ram_1_x(to_integer(unsigned(rs1_addr)));
            rs1_data(1) <= ram_1_y(to_integer(unsigned(rs1_addr)));
            rs1_data(2) <= ram_1_z(to_integer(unsigned(rs1_addr)));
            rs1_data(3) <= ram_1_w(to_integer(unsigned(rs1_addr)));

            -- Read Port A: Source 2 (Replica 2)
            rs2_data(0) <= ram_2_x(to_integer(unsigned(rs2_addr)));
            rs2_data(1) <= ram_2_y(to_integer(unsigned(rs2_addr)));
            rs2_data(2) <= ram_2_z(to_integer(unsigned(rs2_addr)));
            rs2_data(3) <= ram_2_w(to_integer(unsigned(rs2_addr)));

            -- Read Port A: Source 3 (Replica 3)
            rs3_data(0) <= ram_3_x(to_integer(unsigned(rs3_addr)));
            rs3_data(1) <= ram_3_y(to_integer(unsigned(rs3_addr)));
            rs3_data(2) <= ram_3_z(to_integer(unsigned(rs3_addr)));
            rs3_data(3) <= ram_3_w(to_integer(unsigned(rs3_addr)));

            -- Read Port B: MCU (Replica 4)
            rd_data_B(0) <= ram_4_x(to_integer(unsigned(rd_addr_B)));
            rd_data_B(1) <= ram_4_y(to_integer(unsigned(rd_addr_B)));
            rd_data_B(2) <= ram_4_z(to_integer(unsigned(rd_addr_B)));
            rd_data_B(3) <= ram_4_w(to_integer(unsigned(rd_addr_B)));
            
        end if;
    end process;

end architecture rtl;
