------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 May 09      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity Core is
    generic (
        ADDR_WIDTH : integer := 32;     -- width of the memory address bus
        DATA_WIDTH : integer := 32      -- width of the memory data bus
    );
    port (
        clock       : in  std_logic;    -- system clock
        reset       : in  std_logic;    -- system reset
        trigger     : in  std_logic;    -- start computation (from idle)

        -- Avalon Host User Interface for memory access
        usr_request_valid    : out std_logic;   -- request a memory transaction
        usr_request_ready    : in  std_logic;   -- memory is ready for a request
        usr_request_is_write : out std_logic;   -- '1' for write, '0' for read
        usr_request_address  : out std_logic_vector(ADDR_WIDTH - 1 downto 0); -- address for transaction
        usr_writedata        : out std_logic_vector(DATA_WIDTH - 1 downto 0); -- data to write
        usr_byteenable       : out std_logic_vector(DATA_WIDTH/8 - 1 downto 0); -- byte enables for write
        usr_readdata         : in  std_logic_vector(DATA_WIDTH - 1 downto 0); -- data read from memory
        usr_readdata_valid   : in  std_logic;   -- indicates usr_readdata is valid

        -- Debug output
        instruction_out      : out std_logic_vector(DATA_WIDTH - 1 downto 0) -- currently executing instruction
    );
end Core;

architecture rtl of Core is

    -- Constants
    constant INSTRUCTION_WIDTH : integer := 32;
    constant NUM_REGS          : integer := 16;

    -- State machine definition
    type state_t is (
        S_IDLE,
        S_FETCH_REQUEST,
        S_FETCH_WAIT,
        S_EXECUTE
    );

    -- State signals
    signal current_state : state_t; -- current state of the FSM
    signal next_state    : state_t; -- next state of the FSM

    -- Core registers
    signal instruction_pointer : unsigned(ADDR_WIDTH - 1 downto 0);                -- holds the address of the next instruction
    signal instruction_register: std_logic_vector(INSTRUCTION_WIDTH - 1 downto 0); -- holds the fetched instruction

    -- The register file is declared for future expansion.
    type register_file_t is array (0 to NUM_REGS - 1) of std_logic_vector(INSTRUCTION_WIDTH - 1 downto 0);
    signal register_file       : register_file_t;                                  -- general purpose registers

begin

    -- Combinatorial process for FSM next-state logic and outputs
    fsm_comb_proc: process(all)
    begin
        -- Default assignments to prevent latches
        next_state           <= current_state;
        usr_request_valid    <= '0';
        usr_request_is_write <= '0'; -- we only do reads for now
        usr_request_address  <= (others => '0');
        usr_writedata        <= (others => '0'); -- not used
        usr_byteenable       <= (others => '1'); -- not used, but set to all '1's as a safe default
        instruction_out      <= instruction_register; -- output current instruction by default

        case current_state is
            when S_IDLE =>
                -- Wait for the trigger signal to start execution
                if trigger = '1' then
                    next_state <= S_FETCH_REQUEST;
                end if;

            when S_FETCH_REQUEST =>
                -- Request to read the instruction from memory at the IP address
                usr_request_valid   <= '1';
                usr_request_address <= std_logic_vector(instruction_pointer);

                -- When the memory system is ready, move to wait for the data
                if usr_request_ready = '1' then
                    next_state <= S_FETCH_WAIT;
                end if;

            when S_FETCH_WAIT =>
                -- Wait for the memory system to provide the instruction data
                if usr_readdata_valid = '1' then
                    -- Once data is valid, we can execute it in the next cycle
                    next_state <= S_EXECUTE;
                end if;

            when S_EXECUTE =>
                -- In a real CPU, decoding and execution would happen here.
                -- For now, we just move to fetch the next instruction.
                -- TODO: wait for execution unit to finish (send done signal)
                next_state <= S_FETCH_REQUEST;

        end case;
    end process fsm_comb_proc;

    -- Synchronous process for FSM state and core register updates
    fsm_reg_proc: process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                -- Reset all state elements to a known state
                current_state        <= S_IDLE;
                instruction_pointer  <= (others => '0');
                instruction_register <= (others => '0');
            else
                -- Update the state on each clock edge
                current_state <= next_state;

                -- Update registers based on FSM state transitions
                if current_state = S_IDLE and trigger = '1' then
                    -- When triggered, reset the instruction pointer to start from address 0
                    instruction_pointer <= (others => '0');
                end if;

                if current_state = S_FETCH_WAIT and usr_readdata_valid = '1' then
                    -- When instruction data arrives, latch it into the instruction register
                    -- and increment the instruction pointer for the next fetch.
                    instruction_register <= usr_readdata;
                    instruction_pointer  <= instruction_pointer + to_unsigned(DATA_WIDTH / 8, ADDR_WIDTH);
                end if;

                -- In the S_EXECUTE state, the instruction in instruction_register would be
                -- decoded and executed, potentially updating the register_file or
                -- instruction_pointer (for jumps/branches).
            end if;
        end if;
    end process fsm_reg_proc;

end rtl;
