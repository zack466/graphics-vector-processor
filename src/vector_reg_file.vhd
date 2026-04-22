-- =========================================================================================
-- FILE: vector_reg_file.vhd
-- COMPONENT: Vector Register File (Port A only)
-- =========================================================================================
--
-- This module implements a highly-banked vector register file optimized for
-- synthesis into Intel/Altera M10K block RAM. It stores 128-bit vectors (4x
-- 32-bit words) and supports element-level write masking (X, Y, Z, W). To
-- support the read bandwidth required by the FPU (3 simultaneous reads)
-- without using pure logic registers (ALMs), the memory is physically
-- replicated.
--
-- Inputs:
--   clk          : system clock
--   reset        : system reset
--   rs1_addr     : register source 1 address
--   rs2_addr     : register source 2 address
--   rs3_addr     : register soruce 3 address
--   wr_addr_A    : write address for port A
--   wr_data_A    : write data for port A
--   write_mask_A : write mask for port A
--   we_A         : write-enable for port A
--
-- Outputs:
--   rs1_data     : output register 1
--   rs2_data     : output register 2
--   rs3_data     : output register 3
--
-- USAGE:
-- * Port A (FPU): 3 simultaneous vector reads (rs1, rs2, rs3) + 1 masked vector write.
--
-- PIPELINE LATENCIES (CLOCK CYCLES):
-- * Read : 1 Cycle
--   Address is provided on clock N. Data is stable and available on clock N+1.
--
-- * Write: 1 Cycle
--   Write enable/data provided on clock N. Physically written to M10K RAM on clock N+1.
--   Data available for read on clock N+2.
--
-- =========================================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity vector_reg_file is
    generic (
        ADDR_WIDTH : integer := 7 -- 128 standard registers by default
    );
    port (
        clk          : in  std_logic;   -- system clock
        reset        : in  std_logic;   -- system reset

        -- Provides 3 simultaneous vector reads
        rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs3_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs1_data     : out vector_t;
        rs2_data     : out vector_t;
        rs3_data     : out vector_t;

        -- Provides 1 masked vector write (port A)
        wr_addr_A    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data_A    : in  vector_t;
        write_mask_A : in  std_logic_vector(3 downto 0);
        we_A         : in  std_logic
    );
end entity;

architecture rtl of vector_reg_file is

    -- ========================================================================
    -- COMPONENT-SPLIT M10K REPLICAS
    -- ========================================================================
    -- M10K blocks natively support only 1 Read and 1 Write port (or 2 Reads).
    -- To achieve 3 simultaneous reads (rs1, rs2, rs3), we duplicate the exact
    -- same memory contents across 3 identical physical RAM banks.
    -- Furthermore, to support component masking without complex Read-Modify-Write
    -- logic, we split the 128-bit vector into four independent 32-bit arrays.
    -- Total: 3 Replicas * 4 Components (x,y,z,w) = 12 discrete M10K block arrays.
    -- ========================================================================
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of word_t;

    -- Replica 1 (Feeds rs1_data)
    signal ram_1_x, ram_1_y, ram_1_z, ram_1_w : ram_type := (others => (others => '0'));
    -- Replica 2 (Feeds rs2_data)
    signal ram_2_x, ram_2_y, ram_2_z, ram_2_w : ram_type := (others => (others => '0'));
    -- Replica 3 (Feeds rs3_data)
    signal ram_3_x, ram_3_y, ram_3_z, ram_3_w : ram_type := (others => (others => '0'));

    -- Explicitly instruct the synthesis tool (Quartus) to map these to M10K hardware
    attribute ramstyle : string;
    attribute ramstyle of ram_1_x, ram_1_y, ram_1_z, ram_1_w : signal is "M10K";
    attribute ramstyle of ram_2_x, ram_2_y, ram_2_z, ram_2_w : signal is "M10K";
    attribute ramstyle of ram_3_x, ram_3_y, ram_3_z, ram_3_w : signal is "M10K";

begin

    -- ========================================================================
    -- M10K PHYSICAL RAM INFERENCE
    -- Synchronous process mapping writes from Port A to all replicas,
    -- and reads from each replica to the corresponding output port.
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then

            -- --- WRITE OPERATIONS ---
            -- Data is fanned out and written to ALL replicas simultaneously
            -- to ensure memory consistency. It is further gated by the write mask.

            -- X Component Blocks (Bit 0 of Mask)
            if we_A = '1' and write_mask_A(0) = '1' then
                ram_1_x(to_integer(unsigned(wr_addr_A))) <= wr_data_A(0);
                ram_2_x(to_integer(unsigned(wr_addr_A))) <= wr_data_A(0);
                ram_3_x(to_integer(unsigned(wr_addr_A))) <= wr_data_A(0);
            end if;

            -- Y Component Blocks (Bit 1 of Mask)
            if we_A = '1' and write_mask_A(1) = '1' then
                ram_1_y(to_integer(unsigned(wr_addr_A))) <= wr_data_A(1);
                ram_2_y(to_integer(unsigned(wr_addr_A))) <= wr_data_A(1);
                ram_3_y(to_integer(unsigned(wr_addr_A))) <= wr_data_A(1);
            end if;

            -- Z Component Blocks (Bit 2 of Mask)
            if we_A = '1' and write_mask_A(2) = '1' then
                ram_1_z(to_integer(unsigned(wr_addr_A))) <= wr_data_A(2);
                ram_2_z(to_integer(unsigned(wr_addr_A))) <= wr_data_A(2);
                ram_3_z(to_integer(unsigned(wr_addr_A))) <= wr_data_A(2);
            end if;

            -- W Component Blocks (Bit 3 of Mask)
            if we_A = '1' and write_mask_A(3) = '1' then
                ram_1_w(to_integer(unsigned(wr_addr_A))) <= wr_data_A(3);
                ram_2_w(to_integer(unsigned(wr_addr_A))) <= wr_data_A(3);
                ram_3_w(to_integer(unsigned(wr_addr_A))) <= wr_data_A(3);
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

        end if;
    end process;

end architecture rtl;
