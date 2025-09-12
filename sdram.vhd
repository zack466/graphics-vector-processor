library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

entity sdram_host is
    generic (
        -- Possible widths: 32, 64, 128, or 256
        DATA_WIDTH : integer := 128
    );
    port (
        -- Interfacing with Avalon MM
        clk             : in  std_logic;                        -- system clock
        reset           : in  std_logic;                        -- system reset
        read            : out std_logic;                        -- indicates read transaction
        write           : out std_logic;                        -- indicates write transaction
        address         : out std_logic_vector(31 downto 0);    -- address of transaction
        readdatavalid   : in  std_logic;                        -- indicates the readdata signal contains valid data
        readdata        : in  std_logic_vector(DATA_WIDTH-1 downto 0);          -- read data return
        writedata       : out std_logic_vector(DATA_WIDTH-1 downto 0);          -- write data for a transaction
        writeresponsevalid : in std_logic;
        byteenable      : out std_logic_vector(DATA_WIDTH/32 - 1 downto 0);     -- byte enables for each write lane
        waitrequest     : in  std_logic;                                        -- indicates need for additional cycles
                                                                                -- to complete a transaction

        -- Control signals
        do_read         : in   std_logic;
        do_write        : in   std_logic;
        in_address      : in   std_logic_vector(31 downto 0);
        in_data         : in   std_logic_vector(DATA_WIDTH-1 downto 0);
        out_data        : out  std_logic_vector(DATA_WIDTH-1 downto 0);
        write_complete  : out  std_logic;
        read_complete   : out  std_logic
    );

    constant NUM_BYTES : integer := DATA_WIDTH / 32;

end entity sdram_host;

architecture structural of sdram_host is

    type state is (
        idle,
        read_start,
        read_end,
        write_start,
        write_end
    );

    signal curr_state : state;
    signal next_state : state;
    
begin
    state_proc: process(curr_state, do_read, do_write, waitrequest, readdatavalid, writeresponsevalid)
    begin
        next_state <= curr_state;   -- retain current state by default
        case curr_state is
            when idle =>
                if do_read = '1' then
                   -- start a read transaction
                    next_state <= read_start;
                elsif do_write = '1' then
                    -- start a write transaction
                    next_state <= write_start;
                end if;
            when read_start =>
                if waitrequest = '1' then
                    -- Wait for request to go through
                    next_state <= read_start;
                elsif waitrequest = '0' and readdatavalid = '0' then
                    -- Now wait for data to return
                    next_state <= read_end;
                elsif waitrequest = '0' and readdatavalid = '1' then
                    -- Data is returned immediately
                    next_state <= idle;
                end if;
            when read_end =>
                if readdatavalid = '1' then
                    -- Wait until data is ready
                    next_state <= idle;
                end if;
            when write_start =>
                if waitrequest = '1' then
                    -- Wait for request to go through
                    next_state <= write_start;
                elsif waitrequest = '0' and writeresponsevalid = '0' then
                    -- wait for write to be acknowledged
                    next_state <= write_end;
                elsif waitrequest = '0' and writeresponsevalid = '1' then
                    -- write is immediate, go back to idle
                    next_state <= idle;
                end if;
            when write_end =>
                if writeresponsevalid = '1' then
                    -- write successful
                    next_state <= idle;
                end if;
        end case;
    end process state_proc;

    -- Combinatorial process computing the Avalon MM interface signals
    -- to perform reading/writing.
    output_proc: process(curr_state, in_address, in_data)
    begin
        address <= (others => '0');
        read <= '0';
        write <= '0';
        byteenable <= (others => '0');

        if curr_state = read_start then
            address <= in_address;
            read <= '1';
            byteenable(NUM_BYTES - 1 downto 0) <= (others => '1');
        elsif curr_state = write_start then
            address <= in_address;
            write <= '1';
            byteenable(NUM_BYTES - 1 downto 0) <= (others => '1');
            writedata <= in_data;
        end if;
    end process output_proc;

    -- If in reading state, once read complete, latch in data that was read
    read_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                out_data <= (others => '0');
                read_complete <= '0';
            elsif curr_state = idle then
                read_complete <= '0';
            elsif (curr_state = read_end or curr_state = read_start) and readdatavalid = '1' then
                out_data <= readdata;
                read_complete <= '1';
            end if;
        end if;
    end process read_proc;

    -- Output ready signal to signal if write as ended
    write_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                write_complete <= '0';
            elsif curr_state = idle then
                write_complete <= '0';
            elsif (curr_state = write_start or curr_state = write_end) and writeresponsevalid = '1' then
                write_complete <= '1';
            end if;
        end if;
    end process write_proc;
    
    -- Update state on rising clock edge
    clock_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                curr_state <= idle;
            else
                curr_state <= next_state;
            end if;
        end if;
    end process clock_proc;
    
end architecture structural;


library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use work.util.all;

-- This entity provides memory through a Avalon memory-mapped interface to a host.
-- This will provide a pipelined burst interface with a generic bit width.
entity sdram_agent is
    generic (
        DATA_WIDTH : integer := 128;    -- data bitwidth, can be: 32, 64, 128, or 256
        MEM_SIZE : integer := 256       -- size of this memory unit
    );
    port (
        -- Interfacing as Avalon MM agent
        clk             : in  std_logic;                        -- system clock
        reset           : in  std_logic;                        -- system reset
        read            : in  std_logic;                        -- indicates read transaction
        write           : in  std_logic;                        -- indicates write transaction
        address         : in  std_logic_vector(31 downto 0);    -- address of transaction
        readdatavalid   : out std_logic;                        -- indicates the readdata signal contains valid data
        readdata        : out std_logic_vector(DATA_WIDTH-1 downto 0);          -- read data return
        writedata       : in  std_logic_vector(DATA_WIDTH-1 downto 0);          -- write data for a transaction
        writeresponsevalid   : out std_logic;                                   -- indicates the write transaction is complete
        byteenable      : in  std_logic_vector(DATA_WIDTH/32 - 1 downto 0);     -- byte enables for each write lane
        waitrequest     : out std_logic                                         -- indicates need for additional cycles
                                                                                -- to complete a transaction
    );

    constant NUM_BYTES : integer := DATA_WIDTH / 32;

    constant LATENCY : integer := 2;

end entity sdram_agent;

architecture behavioral of sdram_agent is

    type state is (
        idle,
        read_start,
        read_end,
        write_start,
        write_end
    );

    signal curr_state : state;
    signal next_state : state;

    type memory is array (natural range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal data : memory(MEM_SIZE - 1 downto 0);
    signal counter : unsigned(2 downto 0);

    signal accessed_data : std_logic_vector(DATA_WIDTH-1 downto 0);

    signal transaction_done : std_logic;

begin
    waitrequest <= (read or write) and not transaction_done;

    state_proc: process(curr_state, read, write, counter)
    begin
        next_state <= curr_state;   -- retain current state by default
        case curr_state is
            when idle =>
                if read = '1' then
                    -- start a read transaction
                    next_state <= read_start;
                elsif write = '1' then
                    -- start a write transaction
                    next_state <= write_start;
                end if;
            when read_start =>
                if counter = 0 then
                    next_state <= read_end;
                end if;
            when read_end =>
                next_state <= idle;
            when write_start =>
                if counter = 0 then
                    next_state <= write_end;
                end if;
            when write_end =>
                next_state <= idle;
        end case;
    end process state_proc;

    output_proc: process(curr_state, accessed_data)
    begin
        transaction_done <= '0';
        readdatavalid <= '0';
        writeresponsevalid <= '0';
        readdata <= (others => 'X');
        if curr_state = read_start then
            null;
        elsif curr_state = write_start then
            null;
        elsif curr_state = read_end then
            transaction_done <= '1';
            readdatavalid <= '1';
            readdata <= accessed_data;
        elsif curr_state = write_end then
            transaction_done <= '1';
            writeresponsevalid <= '1';
        end if;
    end process output_proc;

    access_proc: process(clk)
    begin
        if rising_edge(clk) then
            if curr_state = read_start then
                accessed_data <= data(to_integer(unsigned(address)));
            elsif curr_state = write_start then
                accessed_data <= data(to_integer(unsigned(address)));
            elsif curr_state = write_end then
                data(to_integer(unsigned(address))) <= writedata;
            end if;
        end if;
    end process access_proc;


    clock_proc: process(clk)
        variable random : rng;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                curr_state <= idle;
                counter <= (others => '0');
            else
                -- When idle, randomize memory latency
                if next_state = idle then
                    counter <= unsigned(random.rand_slv(counter'length));
                else
                    -- When reading/writing, wait for counter clocks
                    -- until request is fulfilled
                    counter <= counter + 1;
                end if;
                curr_state <= next_state;
            end if;
        end if;
    end process clock_proc;

end architecture behavioral;
