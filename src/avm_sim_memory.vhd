library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity avm_sim_memory is
    generic (
        ADDR_WIDTH         : integer := 32;
        DATA_WIDTH         : integer := 128;
        MEM_WORDS          : integer := 1024;
        MAX_DELAY          : integer := 5;
        MAX_PENDING_READS  : integer := 4
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        avs_address       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        avs_burstcount    : in  std_logic_vector(7 downto 0);
        avs_write         : in  std_logic;
        avs_writedata     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avs_byteenable    : in  std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avs_read          : in  std_logic;
        avs_readdata      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avs_readdatavalid : out std_logic;
        avs_waitrequest   : out std_logic
    );
end entity;

architecture sim of avm_sim_memory is

    type ram_type is array (0 to MEM_WORDS-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    
    function init_ram return ram_type is
        variable temp : ram_type;
    begin
        for i in 0 to MEM_WORDS-1 loop
            temp(i) := std_logic_vector(to_unsigned(i, DATA_WIDTH));
        end loop;
        return temp;
    end function;
    
    signal ram : ram_type := init_ram;

    -- Internal state signals
    signal wait_req_int     : std_logic := '1';
    signal write_burst_left : integer := 0;
    signal write_addr       : unsigned(ADDR_WIDTH-1 downto 0);

    type pending_read_t is record
        addr       : unsigned(ADDR_WIDTH-1 downto 0);
        burst_left : integer;
        latency    : integer;
    end record;
    
    type read_fifo_t is array (0 to MAX_PENDING_READS-1) of pending_read_t;

begin

    avs_waitrequest <= wait_req_int;

    process
        variable seed1, seed2   : positive := 1;
        variable rand           : real;
        variable v_wait_counter : integer := 0;
        
        variable v_read_fifo    : read_fifo_t;
        variable v_read_head    : integer := 0;
        variable v_read_tail    : integer := 0;
        variable v_read_count   : integer := 0; 
        
        -- Variables for write handling
        variable target_idx     : integer;
        variable temp_word      : std_logic_vector(DATA_WIDTH-1 downto 0);
    begin
        wait until rising_edge(clk);
        
        -- ====================================================================
        -- ERROR CHECKING: Illegal Commands During Reset
        -- ====================================================================
        if reset = '1' then
            assert not (avs_write = '1' or avs_read = '1')
                report "ERROR: Master issued a command while the slave is in reset!"
                severity error;
                
            v_wait_counter    := 0;
            v_read_head       := 0;
            v_read_tail       := 0;
            v_read_count      := 0;
            wait_req_int      <= '1';
            write_burst_left  <= 0;
            avs_readdatavalid <= '0';
        else
            -- ====================================================================
            -- ERROR CHECKING: Simultaneous Read/Write Assertion
            -- ====================================================================
            assert not (avs_read = '1' and avs_write = '1')
                report "FATAL: Protocol Violation! Read and Write asserted simultaneously."
                severity failure;

            -------------------------------------------------------------------
            -- 1. DECREMENT WAIT DELAY
            -------------------------------------------------------------------
            if v_wait_counter > 0 then
                v_wait_counter := v_wait_counter - 1;
            end if;

            -------------------------------------------------------------------
            -- 2. READ DATA RETURN LOGIC 
            -------------------------------------------------------------------
            avs_readdatavalid <= '0'; 
            
            if v_read_count > 0 then
                if v_read_fifo(v_read_head).latency > 0 then
                    v_read_fifo(v_read_head).latency := v_read_fifo(v_read_head).latency - 1;
                else
                    uniform(seed1, seed2, rand);
                    if rand > 0.3 then 
                        avs_readdatavalid <= '1';
                        avs_readdata      <= ram(to_integer(v_read_fifo(v_read_head).addr) / (DATA_WIDTH/8) mod MEM_WORDS);
                        
                        -- LOG THE RETURNED READ
                        -- report "[AVM MEM READ RET] Addr: 0x" & to_hstring(v_read_fifo(v_read_head).addr) &
                        --        " | Data: 0x" & to_hstring(ram(to_integer(v_read_fifo(v_read_head).addr) / (DATA_WIDTH/8) mod MEM_WORDS)) severity note;
                        
                        v_read_fifo(v_read_head).addr       := v_read_fifo(v_read_head).addr + (DATA_WIDTH/8);
                        v_read_fifo(v_read_head).burst_left := v_read_fifo(v_read_head).burst_left - 1;
                        
                        if v_read_fifo(v_read_head).burst_left = 0 then
                            v_read_head  := (v_read_head + 1) mod MAX_PENDING_READS;
                            v_read_count := v_read_count - 1;
                        end if;
                    end if;
                end if;
            end if;

            -------------------------------------------------------------------
            -- 3. COMMAND ACCEPTANCE LOGIC
            -------------------------------------------------------------------
            if wait_req_int = '0' then
                
                -- [A] Handle Writes
                if avs_write = '1' then
                    
                    -- Determine the target index in the RAM array
                    if write_burst_left = 0 then
                        write_addr <= unsigned(avs_address);
                        write_burst_left <= to_integer(unsigned(avs_burstcount)) - 1;
                        target_idx := to_integer(unsigned(avs_address)) / (DATA_WIDTH/8) mod MEM_WORDS;
                        write_addr <= unsigned(avs_address) + (DATA_WIDTH/8);
                    else
                        target_idx := to_integer(write_addr) / (DATA_WIDTH/8) mod MEM_WORDS;
                        write_addr <= write_addr + (DATA_WIDTH/8);
                        write_burst_left <= write_burst_left - 1;
                    end if;

                    -- Fetch current word, apply byte enables, and write back
                    temp_word := ram(target_idx);
                    for b in 0 to (DATA_WIDTH/8)-1 loop
                        if avs_byteenable(b) = '1' then
                            temp_word((b*8)+7 downto b*8) := avs_writedata((b*8)+7 downto b*8);
                        end if;
                    end loop;
                    ram(target_idx) <= temp_word;

                    -- LOG THE WRITE
                    -- report "[AVM MEM WRITE] Addr: 0x" & to_hstring(to_unsigned(target_idx * (DATA_WIDTH/8), ADDR_WIDTH)) &
                    --        " | Data: 0x" & to_hstring(temp_word) severity note;

                    -- Randomize delay for next beat
                    uniform(seed1, seed2, rand);
                    v_wait_counter := integer(rand * real(MAX_DELAY));

                -- [B] Handle Reads
                elsif avs_read = '1' then
                    v_read_fifo(v_read_tail).addr       := unsigned(avs_address);
                    v_read_fifo(v_read_tail).burst_left := to_integer(unsigned(avs_burstcount));
                    
                    -- LOG THE READ REQUEST
                    -- report "[AVM MEM READ REQ] Addr: 0x" & to_hstring(unsigned(avs_address)) &
                    --        " | Burst Len: " & integer'image(to_integer(unsigned(avs_burstcount))) severity note;
                    
                    uniform(seed1, seed2, rand);
                    v_read_fifo(v_read_tail).latency    := integer(rand * real(MAX_DELAY)) + 2; 
                    
                    v_read_tail  := (v_read_tail + 1) mod MAX_PENDING_READS;
                    v_read_count := v_read_count + 1;

                    uniform(seed1, seed2, rand);
                    v_wait_counter := integer(rand * real(MAX_DELAY));
                end if;
            end if;

            -------------------------------------------------------------------
            -- 4. WAITREQUEST GENERATION
            -------------------------------------------------------------------
            if v_wait_counter > 0 or v_read_count >= MAX_PENDING_READS then
                wait_req_int <= '1';
            else
                wait_req_int <= '0';
            end if;

        end if;
    end process;
end architecture sim;
