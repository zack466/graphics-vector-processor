--------------------------------------------------------------------------------
-- Entity: instruction_memory
--
-- PURPOSE:
--   Single-port M10K block RAM used as the program ROM for the SIMT processor.
--   Separating instruction storage from the general register file keeps the
--   fetch path simple and avoids structural hazards: the IFU always has
--   exclusive read access and the testbench/host has exclusive write access
--   (programming only happens before execution begins, never concurrently).
--
-- USAGE:
--   1. Program phase: drive we='1' and walk wr_addr from 0 to N-1, presenting
--      each 32-bit instruction word on wr_data.  The processor must be held in
--      reset during this phase to prevent spurious fetches.
--   2. Execute phase: de-assert we and release reset.  The IFU drives rd_addr
--      (the program counter) and reads rd_data one cycle later due to the
--      registered-address latency (see timing note below).
--
-- PORT DESCRIPTIONS:
--   clk      -- System clock.  Both read-address registration and write are
--               synchronous to the rising edge.
--   we       -- Synchronous write enable.  Assert to load one instruction word
--               per cycle.  Must be '0' during normal execution.
--   wr_addr  -- Byte-indexed (actually word-indexed here) write address.
--               Must be stable when we='1'.
--   wr_data  -- 32-bit instruction word to write.  Type word_t from
--               vector_types_pkg so callers do not need a cast.
--   rd_addr  -- Fetch address driven by the IFU program counter.  Registered
--               internally; see timing note.
--   rd_data  -- 32-bit instruction word at the address registered on the
--               previous rising edge.
--
-- TIMING / LATENCY:
--   M10K block RAMs on Cyclone V require a registered read address to meet
--   timing at the target frequency — an async (combinational) read address
--   would fail to be inferred as BRAM and would fall back to slower MLABs or
--   distributed registers, wasting area and potentially missing timing.
--
--   Consequence: rd_data is valid ONE cycle after rd_addr is presented.
--   The IFU compensates with a two-stage fetch pipeline:
--       Cycle N  (FETCH_1): PC placed on rd_addr.
--       Cycle N+1 (FETCH_2): rd_data is valid; forwarded to DECODE.
--
-- GENERICS:
--   ADDR_WIDTH -- log2 of the instruction count (default 8 => 256 words =
--                 1 KB of program space).  Increase if more instructions are
--                 needed; each extra bit doubles program memory.
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
        clk      : in  std_logic;

        -- ==========================================
        -- WRITE PORT (Programming Interface)
        -- Used by testbench/host to load the program
        -- before execution.  Tie we='0' at runtime.
        -- ==========================================
        we       : in  std_logic;
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
    -- consumes more fabric.
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

            -- Register the read address every cycle regardless of we.  This
            -- creates the one-cycle pipeline stage required by M10K inference
            -- and also breaks any long combinational path from the PC adder
            -- through the address bus.
            rd_addr_reg <= rd_addr;
        end if;
    end process;

    -- Asynchronous (combinational) read from the REGISTERED address.
    -- Together with the synchronous address register above this matches
    -- the "registered-address, async-output" M10K read mode.
    rd_data <= ram(to_integer(unsigned(rd_addr_reg)));

end architecture rtl;
