library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_avalon_host is
    generic (
        DATA_WIDTH            : integer := 128;
        ADDR_WIDTH            : integer := 32
    );
    port (
        -- System Signals
        clk   : in  std_logic;
        reset : in  std_logic;

        -- User-Side Interface
        usr_request_valid    : in  std_logic;
        usr_request_ready    : out std_logic;
        usr_request_is_write : in  std_logic;
        usr_request_address  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        usr_writedata        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        usr_byteenable       : in  std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
        usr_readdata         : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        usr_readdata_valid   : out std_logic;

        -- Avalon-MM Master Interface
        avm_address        : out std_logic_vector(ADDR_WIDTH - 1 downto 0);
        avm_read           : out std_logic;
        avm_write          : out std_logic;
        avm_waitrequest    : in  std_logic;
        avm_writedata      : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        avm_byteenable     : out std_logic_vector(DATA_WIDTH/8 - 1 downto 0);
        avm_readdata       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        avm_readdata_valid : in  std_logic
    );
end entity sdram_avalon_host;

architecture rtl of sdram_avalon_host is

    type state_t is (
        S_IDLE,
        S_CMD,
        S_WAIT_READ_DATA
    );

    signal current_state, next_state : state_t;

    -- Internal registers for transaction properties
    signal address_reg    : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal is_write_reg   : std_logic;
    signal writedata_reg  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal byteenable_reg : std_logic_vector(DATA_WIDTH/8 - 1 downto 0);

begin

    -- Combinatorial Logic for State Machine and Outputs
    fsm_comb_proc: process(all)
    begin
        -- Default assignments to prevent latches and define inactive states
        next_state          <= current_state;
        usr_request_ready   <= '0';
        usr_readdata_valid  <= '0';
        usr_readdata        <= (others => '0');
        avm_read            <= '0';
        avm_write           <= '0';
        avm_address         <= address_reg;
        avm_writedata       <= writedata_reg;
        avm_byteenable      <= byteenable_reg;

        case current_state is
            when S_IDLE =>
                usr_request_ready <= '1';           -- ready to take a write request
                if usr_request_valid = '1' then
                    next_state <= S_CMD;            -- go into the read/write state
                end if;

            when S_CMD =>
                -- Assert command and address until agent accepts (waitrequest = '0')
                if is_write_reg = '1' then
                    avm_write <= '1';
                else
                    avm_read <= '1';
                end if;

                if avm_waitrequest = '0' then
                    if is_write_reg = '1' then
                        -- Single write transaction completes when command is accepted.
                        next_state <= S_IDLE;
                    else
                        -- Read command accepted, now wait for data.
                        next_state <= S_WAIT_READ_DATA;
                    end if;
                end if;

            when S_WAIT_READ_DATA =>
                -- Wait for valid read data from the slave.
                if avm_readdata_valid = '1' then
                    usr_readdata_valid <= '1';
                    usr_readdata       <= avm_readdata;
                    next_state         <= S_IDLE;
                end if;

        end case;
    end process fsm_comb_proc;

    -- Registered Logic for State and Data Path
    fsm_reg_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                current_state  <= S_IDLE;
                is_write_reg   <= '0';
                address_reg    <= (others => '0');
                writedata_reg  <= (others => '0');
                byteenable_reg <= (others => '0');
            else
                current_state <= next_state;

                -- Latch user request when in IDLE and a valid request arrives.
                if current_state = S_IDLE and usr_request_valid = '1' then
                    is_write_reg   <= usr_request_is_write;
                    address_reg    <= usr_request_address;

                    -- For writes, latch the data and byteenable with the request.
                    if usr_request_is_write = '1' then
                        writedata_reg  <= usr_writedata;
                        byteenable_reg <= usr_byteenable;
                    end if;
                end if;
            end if;
        end if;
    end process fsm_reg_proc;

end architecture rtl;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sdram_avalon_agent is
    generic (
        DATA_WIDTH     : integer := 128;
        ADDR_WIDTH     : integer := 32;
        MEM_ADDR_WIDTH : integer := 8  -- Memory depth will be 2^8 = 256 words
    );
    port (
        -- System Signals
        clk   : in std_logic;
        reset : in std_logic;

        -- Avalon-MM Slave Interface
        avs_address        : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        avs_read           : in  std_logic;
        avs_write          : in  std_logic;
        avs_writedata      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        avs_readdata       : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        avs_readdata_valid : out std_logic;
        avs_waitrequest    : out std_logic
    );
end entity sdram_avalon_agent;

architecture fsm of sdram_avalon_agent is
    -- Ensure the modeled memory address width fits within the Avalon address bus
    constant ADDR_WORD_OFFSET : integer := integer(log2(real(DATA_WIDTH/8)));

    -- Memory configuration
    constant MEM_DEPTH : integer := 2**MEM_ADDR_WIDTH;
    type mem_array_t is array (0 to MEM_DEPTH - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal memory : mem_array_t;

    -- FSM state definition
    type state_t is (
        S_IDLE,
        S_PROCESS_DELAY,
        S_READ_DATA_VALID
    );
    signal current_state, next_state : state_t;

    -- Internal registers
    signal delay_counter : integer range 0 to 10;
    signal address_reg   : std_logic_vector(MEM_ADDR_WIDTH - 1 downto 0);
    signal writedata_reg : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal is_write_reg  : std_logic;

begin

    -- Combinatorial Process: State transitions and output logic
    fsm_comb_proc: process(all)
    begin
        -- Default assignments
        next_state         <= current_state;
        avs_waitrequest    <= '0';
        avs_readdata_valid <= '0';
        avs_readdata       <= (others => 'X'); -- Drive 'X' when not valid

        case current_state is
            when S_IDLE =>
                avs_waitrequest <= '0';
                if avs_read = '1' or avs_write = '1' then
                    next_state <= S_PROCESS_DELAY;
                end if;

            when S_PROCESS_DELAY =>
                avs_waitrequest <= '1';
                if delay_counter = 1 then
                    if is_write_reg = '1' then
                        -- Write completes, go back to idle
                        next_state <= S_IDLE;
                    else
                        -- Read delay is over, present data next cycle
                        next_state <= S_READ_DATA_VALID;
                    end if;
                end if;

            when S_READ_DATA_VALID =>
                avs_waitrequest    <= '0';
                avs_readdata_valid <= '1';
                avs_readdata       <= memory(to_integer(unsigned(address_reg)));
                -- Data is valid for one cycle, then return to idle
                next_state <= S_IDLE;

        end case;
    end process fsm_comb_proc;

    -- Registered Process: State updates and data path logic
    fsm_reg_proc: process(clk)
        -- Variables for random number generation (simulation only)
        variable seed1, seed2 : positive := 1;
        variable rand_real    : real;
        variable rand_delay   : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                current_state <= S_IDLE;
                delay_counter <= 0;
                address_reg   <= (others => '0');
                writedata_reg <= (others => '0');
                is_write_reg  <= '0';
                memory        <= (others => (others => '0'));
            else
                current_state <= next_state;

                -- Latch transaction details when starting
                if (current_state = S_IDLE) and (avs_read = '1' or avs_write = '1') then
                    -- Generate a random delay from 1 to 10 cycles
                    uniform(seed1, seed2, rand_real);
                    rand_delay := integer(trunc(rand_real * 10.0)) + 1;
                    delay_counter <= rand_delay;

                    -- Latch transaction properties
                    is_write_reg  <= avs_write;
                    address_reg   <= avs_address(MEM_ADDR_WIDTH + ADDR_WORD_OFFSET - 1 downto ADDR_WORD_OFFSET);
                    writedata_reg <= avs_writedata;
                end if;

                -- Decrement counter while in the delay state
                if current_state = S_PROCESS_DELAY and delay_counter > 0 then
                    delay_counter <= delay_counter - 1;
                end if;

                -- Perform the write operation upon completion of the delay
                if current_state = S_PROCESS_DELAY and delay_counter = 1 and is_write_reg = '1' then
                    memory(to_integer(unsigned(address_reg))) <= writedata_reg;
                end if;
            end if;
        end if;
    end process fsm_reg_proc;

end architecture fsm;
