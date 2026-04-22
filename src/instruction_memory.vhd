-- ============================================================================
-- FILE: instruction_memory.vhd
-- COMPONENT: Instruction Memory
-- ============================================================================
--
-- Single-port M10K block RAM used as the program ROM for the SIMT processor.
-- The IFU always has exclusive read access and the testbench/host has
-- exclusive write access (programming only happens before execution begins,
-- never concurrently).
--
-- Inputs:
--   clk      -- System clock.
--   we       -- Synchronous write enable. Assert to load one instruction word
--               per cycle.  Must be '0' during normal execution.
--   wr_addr  -- Word-indexed write address. Must be stable when we='1'.
--   wr_data  -- 32-bit instruction word to write.
--   rd_addr  -- Fetch address driven by the IFU program counter. Registered
--               internally since M10K RAM has 1 clock of read latency.
--
-- Outputs:
--   rd_data  -- 32-bit instruction word at the address registered on the
--               previous rising edge.
--
-- Timing Note / Usage:
--   - rd_data is valid ONE cycle after rd_addr is presented.
--   - The IFU compensates with a two-stage fetch pipeline:
--     - Cycle N  (FETCH_1): PC placed on rd_addr.
--     - Cycle N+1 (FETCH_2): rd_data is valid; forwarded to DECODE.
--
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity instruction_memory is
    generic (
        ADDR_WIDTH : integer := 8 -- 256 instructions max
    );
    port (
        clk      : in  std_logic; -- system clock

        -- ==========================================
        -- WRITE PORT (Programming Interface)
        -- Used by testbench/host to load the program
        -- before execution.
        -- ==========================================
        we       : in  std_logic; -- write enable (active high)
        wr_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data  : in  word_t;

        -- ==========================================
        -- READ PORT (Instruction Fetch Interface)
        -- Driven by the IFU program counter.
        -- rd_data is valid one cycle after rd_addr.
        -- ==========================================
        rd_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rd_data  : out word_t
    );
end entity instruction_memory;

architecture rtl of instruction_memory is

    -- 2^ADDR_WIDTH entries, each one 32-bit instruction word.
    -- Initialised to all-zeros so un-programmed locations produce a NOP-like
    -- value and do not cause undefined signal warnings in simulation.
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) of word_t;
    signal ram : ram_type := (others => (others => '0'));

    -- Registered copy of rd_addr.  The M10K read-data path is:
    --   rd_addr (combinational) -> [register] -> rd_addr_reg -> RAM output mux -> rd_data
    -- Quartus infers block RAM only when it sees this registered-address pattern.
    -- Without the register the tool infers MLAB or logic, which is slower and
    -- consumes more ALMs.
    signal rd_addr_reg : std_logic_vector(ADDR_WIDTH-1 downto 0);

begin

    process(clk)
    begin
        if rising_edge(clk) then
            -- Synchronous write: both address and data are stable before the
            -- rising edge; the write completes in a single cycle.
            if we = '1' then
                ram(to_integer(unsigned(wr_addr))) <= wr_data;
            end if;

            -- Register the read address every cycle
            rd_addr_reg <= rd_addr;
        end if;
    end process;

    -- Asynchronous (combinational) read from the REGISTERED address, inferred as block RAM
    rd_data <= ram(to_integer(unsigned(rd_addr_reg)));

end architecture rtl;
