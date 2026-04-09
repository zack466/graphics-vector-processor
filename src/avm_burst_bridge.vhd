--------------------------------------------------------------------------------
-- Entity: avm_burst_bridge
--
-- PURPOSE:
--   Protocol translation layer between the Memory Control Unit (MCU) and the
--   Cyclone V DDR3 hard memory controller, which exposes an Avalon-MM burst
--   master interface.  The MCU uses a simpler command/data stream interface
--   (commands in a FIFO, write data in a separate FIFO) that cannot directly
--   drive Avalon-MM without this bridge.
--
--   The bridge serialises commands one burst at a time: it accepts one command
--   per transaction and holds the Avalon bus until the burst completes.  This
--   keeps the bridge state machine simple and avoids out-of-order completion
--   issues between back-to-back bursts.
--
-- USAGE:
--   1. The MCU presents a command (cmd_valid, cmd_is_store, cmd_addr,
--      cmd_burst_len) and waits for cmd_ready.  cmd_ready is a one-cycle pulse
--      that signals the command has been latched; the MCU must NOT hold
--      cmd_valid for more than one cycle after cmd_ready fires.
--   2. For a STORE: the MCU fills tx_data/tx_byte_en/tx_valid one beat per
--      cycle; tx_ready (mirrored from ~avm_waitrequest) indicates whether the
--      current beat was accepted.  The bridge returns to IDLE after
--      burst_words_left reaches 1 and the last beat is accepted.
--   3. For a LOAD: no tx data is needed.  The bridge asserts avm_read and
--      holds it until avm_waitrequest deasserts.  Read data flows back to the
--      MCU via the rx_data/rx_valid bypass wires with zero additional latency.
--
-- PORT DESCRIPTIONS:
--   clk               -- System clock.
--   reset             -- Synchronous active-high reset; returns to IDLE.
--
--   cmd_valid         -- MCU asserts to present a new command.
--   cmd_is_store      -- '1' => write burst, '0' => read burst.
--   cmd_addr          -- Starting DDR3 word address for the transaction.
--   cmd_burst_len     -- Number of DATA_WIDTH-wide beats in the burst (1..255).
--   cmd_ready         -- One-cycle pulse: command latched, MCU may deassert.
--
--   tx_data           -- Write data for the current beat.
--   tx_byte_en        -- Byte-enable mask for the current beat.
--   tx_valid          -- MCU asserts when tx_data/tx_byte_en are valid.
--   tx_ready          -- Bridge asserts when the Avalon bus accepted the beat
--                        (i.e., ~avm_waitrequest while in AVM_WRITE_BURST).
--
--   rx_data           -- Read data returned directly from avm_readdata.
--   rx_valid          -- Mirrors avm_readdatavalid; valid for one cycle per
--                        returned beat.  The MCU must capture rx_data on every
--                        rx_valid pulse; there is no FIFO here.
--
--   avm_address       -- Burst start address, held constant for the entire
--                        burst (Avalon-MM burst protocol requirement).
--   avm_burstcount    -- Total beat count for the burst, also held constant.
--   avm_write         -- Asserted per-beat during AVM_WRITE_BURST when
--                        tx_valid is high.
--   avm_writedata     -- Write payload, wired directly from tx_data.
--   avm_byteenable    -- Byte enables; defaults to all-ones outside a write
--                        burst so the DDR3 controller sees a valid value.
--   avm_read          -- Asserted for the duration of AVM_ISSUE_READ until
--                        avm_waitrequest deasserts.
--   avm_readdata      -- Read payload from DDR3; bypassed directly to rx_data.
--   avm_readdatavalid -- DDR3 asserts when avm_readdata is valid; bypassed to
--                        rx_valid.
--   avm_waitrequest   -- DDR3 controller backpressure signal.  When high, the
--                        current bus transaction must be held (address, command,
--                        and data all frozen).
--
-- STATE MACHINE:
--   IDLE            -- Waiting for cmd_valid.  Latches command on arrival.
--   AVM_WRITE_BURST -- Streaming tx beats onto the Avalon bus one per cycle.
--                      Advances burst_words_left each time a beat is accepted
--                      (~waitrequest & tx_valid).  Returns to IDLE when the
--                      last beat (words_left=1) is accepted.
--   AVM_ISSUE_READ  -- Holds avm_read='1' until avm_waitrequest deasserts,
--                      which confirms the DDR3 controller accepted the read
--                      request.  Returns to IDLE immediately; read data arrives
--                      asynchronously via rx_data/rx_valid.
--
-- TIMING CONSTRAINTS:
--   avm_address and avm_burstcount are latched registers (latched_addr /
--   latched_len) so they are stable from the first cycle of a burst transaction
--   through its completion, satisfying the Avalon-MM burst master protocol.
--   Do not change cmd_addr or cmd_burst_len while a transaction is in progress.
--
-- GENERICS:
--   ADDR_WIDTH -- DDR3 address bus width in bits (default 32).
--   DATA_WIDTH -- Avalon data bus width in bits (default 128, matching one
--                 vector_t = four 32-bit words).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity avm_burst_bridge is
    generic (
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- Interface From MCU
        cmd_valid         : in  std_logic;
        cmd_is_store      : in  std_logic;
        cmd_addr          : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : in  std_logic_vector(7 downto 0);
        cmd_ready         : out std_logic;

        tx_data           : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        tx_byte_en        : in  std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        tx_valid          : in  std_logic;
        tx_ready          : out std_logic;

        rx_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        rx_valid          : out std_logic;

        -- Avalon-MM Master Interface (To DDR3)
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_byteenable    : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avm_read          : out std_logic;
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic
    );
end entity;

architecture rtl of avm_burst_bridge is
    type state_t is (IDLE, AVM_ISSUE_READ, AVM_WRITE_BURST);
    signal state : state_t;

    -- Registers to hold the burst parameters stable for the entire transaction.
    -- Avalon-MM burst protocol requires address and burstcount to be presented
    -- on the first beat and held unchanged until the burst completes.  Latching
    -- them here prevents any MCU changes to cmd_addr/cmd_burst_len from
    -- corrupting an in-flight burst.
    signal latched_addr     : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal latched_len      : std_logic_vector(7 downto 0);

    -- Counts down from cmd_burst_len to 1.  Using a down-counter (rather than
    -- an up-counter compared to latched_len) saves one comparator: we only need
    -- to check for =1, not =latched_len.
    signal burst_words_left : unsigned(7 downto 0);
begin

    -- Read data from DDR3 is wired straight through to the MCU with no
    -- buffering.  Adding a FIFO here would increase latency; the MCU is
    -- responsible for capturing every rx_valid pulse.
    rx_data  <= avm_readdata;
    rx_valid <= avm_readdatavalid;

    -- avm_write is gated by state so the DDR3 controller does not see spurious
    -- writes while the bridge is IDLE or issuing a read.
    avm_write      <= tx_valid when state = AVM_WRITE_BURST else '0';
    avm_writedata  <= tx_data;

    -- Default byte-enable to all-ones outside a write burst so the DDR3
    -- controller never sees an undefined byte-enable vector.
    avm_byteenable <= tx_byte_en when state = AVM_WRITE_BURST else (others => '1');

    -- Address and burst count are always driven from latched registers so they
    -- are stable regardless of what the MCU is presenting.
    avm_address    <= latched_addr;
    avm_burstcount <= latched_len;

    -- tx_ready directly mirrors the Avalon waitrequest inverse: a beat is
    -- consumed from the MCU's tx FIFO on exactly the same cycle the DDR3
    -- controller accepts it, ensuring the FIFO and the burst counter stay
    -- perfectly in step.  Outside a write burst tx_ready is forced low to
    -- prevent the MCU from draining its FIFO prematurely.
    tx_ready       <= not avm_waitrequest when state = AVM_WRITE_BURST else '0';

    -- avm_read must be held high until waitrequest deasserts; the state machine
    -- handles this by staying in AVM_ISSUE_READ until that condition is met.
    avm_read       <= '1' when state = AVM_ISSUE_READ else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                cmd_ready <= '0';
            else
                -- Default cmd_ready to '0' every cycle; it is pulsed high for
                -- exactly one cycle in the IDLE state when a command is taken.
                cmd_ready <= '0';

                case state is
                    when IDLE =>
                        if cmd_valid = '1' then
                            -- Latch the command parameters before leaving IDLE
                            -- so the MCU is free to change its outputs next cycle.
                            latched_addr     <= cmd_addr;
                            latched_len      <= cmd_burst_len;
                            burst_words_left <= unsigned(cmd_burst_len);
                            -- Pulse cmd_ready on the same cycle we latch the command
                            -- (registered output, so MCU sees it the NEXT cycle).
                            cmd_ready        <= '1';

                            if cmd_is_store = '1' then
                                state <= AVM_WRITE_BURST;
                            else
                                state <= AVM_ISSUE_READ;
                            end if;
                        end if;

                    when AVM_WRITE_BURST =>
                        -- A beat is successfully transferred when the MCU has
                        -- valid data AND the DDR3 controller is not stalling.
                        -- Checking both conditions prevents double-counting a
                        -- beat that is held by waitrequest.
                        if tx_valid = '1' and avm_waitrequest = '0' then
                            if burst_words_left = 1 then
                                -- Last beat accepted; burst is complete.
                                state <= IDLE;
                            else
                                burst_words_left <= burst_words_left - 1;
                            end if;
                        end if;

                    when AVM_ISSUE_READ =>
                        -- The DDR3 controller accepted the read request when
                        -- waitrequest deasserts.  We can return to IDLE
                        -- immediately; read data will arrive later via
                        -- avm_readdatavalid / rx_valid (no state needed).
                        if avm_waitrequest = '0' then
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;
end architecture rtl;
