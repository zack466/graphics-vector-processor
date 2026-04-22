-- ============================================================================
-- FILE: avm_burst_bridge.vhd
-- COMPONENT: avm_burst_bridge
-- ============================================================================
--
-- Protocol translation layer between the MCU and the Cyclone V DDR3 hard
-- memory controller's Avalon-MM burst master interface. Serialises commands
-- one burst at a time, holding the Avalon bus until each burst completes.
--
-- Inputs:
--   clk               : System clock.
--   reset             : Synchronous active-high reset; returns FSM to IDLE.
--   cmd_valid         : MCU asserts to present a new command.
--   cmd_is_store      : '1' = write burst, '0' = read burst.
--   cmd_addr          : Starting DDR3 word address for the transaction.
--   cmd_burst_len     : Number of DATA_WIDTH-wide beats in the burst (1..255).
--   tx_data           : Write data for the current beat.
--   tx_byte_en        : Byte-enable mask for the current beat.
--   tx_valid          : MCU asserts when tx_data/tx_byte_en are valid.
--   avm_readdata      : Read payload from DDR3; bypassed directly to rx_data.
--   avm_readdatavalid : DDR3 asserts when avm_readdata is valid; bypassed to rx_valid.
--   avm_waitrequest   : DDR3 controller backpressure; freezes all bus outputs when high.
--
-- Outputs:
--   cmd_ready         : One-cycle pulse confirming the command was latched.
--   tx_ready          : Asserted when the Avalon bus accepted the current beat
--                       (~avm_waitrequest while in AVM_WRITE_BURST).
--   rx_data           : Read data wired directly from avm_readdata.
--   rx_valid          : Mirrors avm_readdatavalid. No RX FIFO; MCU must capture
--                       rx_data on every rx_valid pulse.
--   avm_address       : Burst start address, held constant for the entire burst.
--   avm_burstcount    : Total beat count, held constant for the entire burst.
--   avm_write         : Asserted per-beat during AVM_WRITE_BURST when tx_valid is high.
--   avm_writedata     : Write payload, wired directly from tx_data.
--   avm_byteenable    : Byte enables; defaults to all-ones outside a write burst.
--   avm_read          : Held high through AVM_ISSUE_READ until avm_waitrequest deasserts.
--
-- USAGE:
--   1. MCU presents a command (cmd_valid, cmd_is_store, cmd_addr, cmd_burst_len)
--      and waits for cmd_ready. cmd_ready pulses for one cycle to confirm the
--      command was latched; MCU must deassert cmd_valid after that cycle.
--   2. STORE: MCU streams tx_data/tx_byte_en/tx_valid one beat per cycle.
--      tx_ready mirrors ~avm_waitrequest. Bridge returns to IDLE after the
--      last beat is accepted.
--   3. LOAD: No tx data needed. Bridge asserts avm_read until avm_waitrequest
--      deasserts, then returns to IDLE. Read data flows back via rx_data/rx_valid
--      with no additional latency.
--
-- State machine:
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
-- ============================================================================
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

    -- Latched burst parameters; held stable from first beat through completion
    -- as required by the Avalon-MM burst master protocol.
    signal latched_addr     : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal latched_len      : std_logic_vector(7 downto 0);

    -- Down-counter; checking for =1 is cheaper than comparing against latched_len.
    signal burst_words_left : unsigned(7 downto 0);
begin

    -- RX path: straight-through bypass, no buffering.
    rx_data  <= avm_readdata;
    rx_valid <= avm_readdatavalid;

    -- Gate avm_write by state to suppress spurious writes during IDLE/reads.
    avm_write      <= tx_valid when state = AVM_WRITE_BURST else '0';
    avm_writedata  <= tx_data;

    -- Default byte-enable to all-ones outside a write burst.
    avm_byteenable <= tx_byte_en when state = AVM_WRITE_BURST else (others => '1');

    -- Address and burst count driven from latched registers to stay stable
    -- regardless of what the MCU is presenting.
    avm_address    <= latched_addr;
    avm_burstcount <= latched_len;

    -- tx_ready mirrors ~waitrequest so the MCU's FIFO and burst counter stay
    -- in step. Forced low outside a write burst to prevent premature draining.
    tx_ready       <= not avm_waitrequest when state = AVM_WRITE_BURST else '0';

    avm_read       <= '1' when state = AVM_ISSUE_READ else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                cmd_ready <= '0';
            else
                cmd_ready <= '0'; -- Default; pulsed high for one cycle when a command is latched.

                case state is
                    when IDLE =>
                        if cmd_valid = '1' then
                            latched_addr     <= cmd_addr;
                            latched_len      <= cmd_burst_len;
                            burst_words_left <= unsigned(cmd_burst_len);
                            cmd_ready        <= '1';

                            if cmd_is_store = '1' then
                                state <= AVM_WRITE_BURST;
                            else
                                state <= AVM_ISSUE_READ;
                            end if;
                        end if;

                    when AVM_WRITE_BURST =>
                        -- Beat accepted when MCU has valid data and DDR3 is not stalling.
                        if tx_valid = '1' and avm_waitrequest = '0' then
                            if burst_words_left = 1 then
                                state <= IDLE;
                            else
                                burst_words_left <= burst_words_left - 1;
                            end if;
                        end if;

                    when AVM_ISSUE_READ =>
                        -- Read request accepted when waitrequest deasserts; data
                        -- arrives later via rx_valid, no state needed.
                        if avm_waitrequest = '0' then
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;
end architecture rtl;
