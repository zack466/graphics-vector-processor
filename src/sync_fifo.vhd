--------------------------------------------------------------------------------
-- Entity: sync_fifo
--
-- PURPOSE:
--   General-purpose synchronous FIFO backed by on-chip M10K block RAM.  Acts
--   as an elastic buffer between any two pipeline stages that may not be ready
--   at the same cycle — for example, between the MCU command generator and the
--   Avalon burst bridge, or between the VRF write-data producer and the write
--   arbiter.  Using a FIFO here decouples producer and consumer timing without
--   requiring explicit handshake stalling logic in either endpoint.
--
-- USAGE:
--   Instantiate with DATA_WIDTH and ADDR_WIDTH generics sized to the payload
--   and the worst-case burst depth needed.  Drive wr_en to push; drive rd_en
--   to pop.  Check full before writing and empty before reading — the FIFO
--   silently drops writes when full and holds the tail value when empty.
--
--   dout is combinational from the current tail pointer, so it is valid on the
--   same cycle that empty goes low.  No extra read-latency pipeline stage is
--   needed by the consumer.
--
-- PORT DESCRIPTIONS:
--   clk      -- System clock.  All state updates are synchronous to the rising
--               edge.
--   reset    -- Synchronous active-high reset.  Clears head, tail, and count;
--               does NOT zero the RAM contents (unnecessary because count=0
--               prevents any stale data from being read).
--   wr_en    -- Assert for one cycle to push din onto the head.  Ignored when
--               full to prevent head pointer wrap-around corruption.
--   din      -- Write data; must be stable while wr_en is asserted.
--   rd_en    -- Assert for one cycle to advance the tail pointer (pop).
--               Ignored when empty.
--   dout     -- Combinational read output from the current tail address.
--               Valid whenever empty = '0'.
--   empty    -- High when the FIFO contains no valid entries.
--   full     -- High when the FIFO is at maximum capacity (2^ADDR_WIDTH entries).
--   count    -- Current number of valid entries; useful for throttle logic.
--
-- TIMING:
--   Write path: din is written to RAM and head advances on the rising edge
--               when wr_en='1' and not full.
--   Read path:  tail advances on the rising edge when rd_en='1' and not empty.
--               dout reflects the new tail combinationally one delta after the
--               clock edge (BRAM read is async from the registered address).
--   Simultaneous read+write: both head and tail advance; count is unchanged.
--               This case is handled explicitly to avoid double-counting.
--
-- GENERICS:
--   DATA_WIDTH -- Width of each FIFO entry in bits (default 128 = one vector).
--   ADDR_WIDTH -- log2 of the FIFO depth (default 6 => 64 entries).
--               Choosing a power-of-two depth allows the head/tail unsigned
--               counters to wrap naturally without a modulo comparison.
--------------------------------------------------------------------------------
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
    -- Force Quartus to infer M10K block RAM rather than MLAB or registers.
    -- Without this hint the synthesiser may choose a smaller/faster primitive
    -- that does not meet the capacity requirement for large FIFOs.
    attribute ramstyle of ram : signal is "M10K";

    -- head points to the next empty slot to write into.
    -- tail points to the oldest valid entry to read from.
    -- Both are ADDR_WIDTH-bit unsigned so they wrap automatically at 2^ADDR_WIDTH,
    -- which is exactly the array size — no explicit modulo logic is needed.
    signal head, tail : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
    -- r_count is a separate integer counter rather than a derived (head - tail)
    -- expression because the subtraction would require an extra comparator and
    -- would not simplify cleanly with the wrap-around semantics.
    signal r_count    : integer range 0 to (2**ADDR_WIDTH) := 0;
begin
    empty <= '1' when r_count = 0 else '0';
    full  <= '1' when r_count = (2**ADDR_WIDTH) else '0';
    count <= r_count;

    -- Combinational read output: expose the tail entry immediately so the
    -- consumer does not need to wait an extra cycle after asserting rd_en.
    -- This is safe because tail only changes on a clock edge (synchronous pop).
    dout <= ram(to_integer(tail));

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                head <= (others => '0');
                tail <= (others => '0');
                r_count <= 0;
            else
                -- Guard against overflow: ignore writes when already full so
                -- head does not lap tail and corrupt valid entries.
                if wr_en = '1' and r_count < (2**ADDR_WIDTH) then
                    ram(to_integer(head)) <= din;
                    head <= head + 1;
                end if;

                -- Guard against underflow: ignore reads when empty so tail
                -- does not advance past head into undefined data.
                if rd_en = '1' and r_count > 0 then
                    tail <= tail + 1;
                end if;

                -- Update count only when write and read are NOT both active.
                -- If both are valid simultaneously the FIFO depth is unchanged
                -- and neither branch fires, keeping r_count stable.  This
                -- avoids a +1/-1 pair that would be net-zero but could glitch.
                if (wr_en = '1' and r_count < (2**ADDR_WIDTH)) and not (rd_en = '1' and r_count > 0) then
                    r_count <= r_count + 1;
                elsif (rd_en = '1' and r_count > 0) and not (wr_en = '1' and r_count < (2**ADDR_WIDTH)) then
                    r_count <= r_count - 1;
                end if;
            end if;
        end if;
    end process;
end architecture;
