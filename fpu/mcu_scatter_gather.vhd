library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity mcu_scatter_gather is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- Processor Control
        mem_op_valid      : in  std_logic;
        is_store          : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0); 
        offset_reg_idx    : in  std_logic_vector(1 downto 0);
        dest_src_reg_idx  : in  std_logic_vector(1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        -- VRF Port B Access
        reg_read_addr     : out std_logic_vector(6 downto 0); 
        reg_read_data     : in  vector_t; 
        reg_write_addr    : out std_logic_vector(6 downto 0);
        reg_write_data    : out vector_t;
        reg_write_en      : out std_logic;

        -- Internal Bridge Interface (To Avalon Master)
        cmd_valid         : out std_logic;
        cmd_is_store      : out std_logic;
        cmd_addr          : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : out std_logic_vector(7 downto 0);
        cmd_ready         : in  std_logic;
        
        tx_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        tx_byte_en        : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        tx_valid          : out std_logic;
        tx_ready          : in  std_logic;
        
        rx_data           : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        rx_valid          : in  std_logic
    );
end entity;

architecture rtl of mcu_scatter_gather is
    type state_t is (IDLE, GATHER_ADDR, GATHER_DATA, FIND_UNSERVED, COALESCE_EVAL, DISPATCH, HANDLE_WRITE, FINISH);
    signal state : state_t;

    type addr_array_t is array (0 to WARP_SIZE-1) of unsigned(ADDR_WIDTH-1 downto 0);
    type data_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    
    signal thread_addrs  : addr_array_t;
    signal thread_data   : data_array_t;
    signal thread_served : std_logic_vector(WARP_SIZE-1 downto 0);
    signal req_idx       : integer range 0 to WARP_SIZE;
    signal ack_idx       : integer range 0 to WARP_SIZE;
    signal scan_idx      : integer range 0 to WARP_SIZE;
    
    signal burst_base_addr : unsigned(ADDR_WIDTH-1 downto 0);
    signal burst_start_idx : integer range 0 to WARP_SIZE;
    signal burst_len       : integer range 0 to WARP_SIZE + 1;
    signal words_handled   : integer range 0 to WARP_SIZE;
    
    -- Custom Record for the Read Tracking FIFO
    -- This allows the asynchronous receiver to know which thread gets the incoming read data
    type read_ctx_t is record
        start_idx : integer range 0 to WARP_SIZE;
        len       : integer range 0 to WARP_SIZE;
    end record;
    type read_fifo_array_t is array (0 to 15) of read_ctx_t;

begin

    -- MCU always writes full 128-bit words, so byte enable is tied high
    tx_byte_en <= (others => '1');

    -- This state machine sequentially iterates through each thread's
    -- read/write request, coalescing them if possible, and then sends/receives
    -- pipelined bursts of memory accesses through a bridge to an avalon memory
    -- unit backed by DDR3 RAM.
    process(clk)
        -- FIFO Variables are used so they update instantaneously in the same clock cycle,
        -- preventing race conditions when concurrent pushes and pops occur.
        variable v_fifo       : read_fifo_array_t;
        variable v_fifo_head  : integer range 0 to 15 := 0;
        variable v_fifo_tail  : integer range 0 to 15 := 0;
        variable v_fifo_count : integer range 0 to 16 := 0;
        
        variable rx_words_handled : integer range 0 to WARP_SIZE := 0;
        variable target_th_rx     : integer range 0 to WARP_SIZE;
        
        -- Combinational variables used for immediate array indexing without inferred registers
        variable next_idx     : integer;
        variable target_th_tx : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                mem_stall <= '0'; reg_write_en <= '0'; cmd_valid <= '0'; tx_valid <= '0';
                
                v_fifo_head := 0; v_fifo_tail := 0;
                v_fifo_count := 0;
                rx_words_handled := 0;
            else
                -- report "MCU state: " & to_string(state);
                reg_write_en <= '0';
                cmd_valid <= '0'; tx_valid <= '0'; 

                -- ============================================================
                -- BLOCK 1: ASYNCHRONOUS RECEIVER LOGIC
                -- Identifies incoming pipelined data and writes to the VRF
                -- ============================================================
                if rx_valid = '1' then
                    if v_fifo_count > 0 then
                        target_th_rx := v_fifo(v_fifo_head).start_idx + rx_words_handled;
                        reg_write_en <= '1'; 
                        reg_write_addr <= std_logic_vector(to_unsigned(target_th_rx, 5)) & dest_src_reg_idx;
                        
                        -- Pack 128-bit AVM bus word into 4x32-bit Vector Register elements
                        reg_write_data(0) <= rx_data(31 downto 0);   reg_write_data(1) <= rx_data(63 downto 32);
                        reg_write_data(2) <= rx_data(95 downto 64);  reg_write_data(3) <= rx_data(127 downto 96);
                        
                        -- Pop from the tracking FIFO once the burst length is fully satisfied
                        if rx_words_handled = v_fifo(v_fifo_head).len - 1 then
                            rx_words_handled := 0;
                            v_fifo_count := v_fifo_count - 1;
                            if v_fifo_head = 15 then v_fifo_head := 0; else v_fifo_head := v_fifo_head + 1; end if;
                        else
                            rx_words_handled := rx_words_handled + 1;
                        end if;
                    end if;
                end if;

                -- ============================================================
                -- BLOCK 2: DISPATCH STATE MACHINE
                -- Evaluates 32 memory threads and coalesces them into AVM bursts
                -- ============================================================
                case state is
                
                    -- Wait for valid operation, then immediately freeze the processor pipeline
                    when IDLE =>
                        if mem_op_valid = '1' then
                            mem_stall <= '1';
                            req_idx <= 0; ack_idx <= 0;
                            -- Pre-load the thread mask. Inactive threads are marked as "served" so they are skipped.
                            thread_served <= not exec_mask; 
                            state <= GATHER_ADDR;
                        else
                            mem_stall <= '0';
                        end if;

                    -- Fetch base offsets from the VRF for all 32 threads sequentially
                    when GATHER_ADDR =>
                        if req_idx < WARP_SIZE then
                            reg_read_addr <= std_logic_vector(to_unsigned(req_idx, 5)) & offset_reg_idx;
                            req_idx <= req_idx + 1;
                        end if;
                        
                        -- The VRF has a 1-cycle read latency, so the ack pointer lags behind the req pointer
                        if req_idx >= 2 or ack_idx > 0 then
                            if ack_idx < WARP_SIZE then
                                thread_addrs(ack_idx) <= unsigned(base_addr) + unsigned(reg_read_data(0));
                                ack_idx <= ack_idx + 1;
                            end if;
                        end if;
                        
                        -- Wait for ack_idx to hit 32, guaranteeing the last element is safely stored
                        if ack_idx = WARP_SIZE then
                            req_idx <= 0;
                            ack_idx <= 0;
                            if is_store = '1' then state <= GATHER_DATA; else scan_idx <= 0; state <= FIND_UNSERVED; end if;
                        end if;

                    -- Fetch source data from the VRF (Only runs on Store instructions)
                    when GATHER_DATA =>
                        if req_idx < WARP_SIZE then
                            reg_read_addr <= std_logic_vector(to_unsigned(req_idx, 5)) & dest_src_reg_idx;
                            req_idx <= req_idx + 1;
                        end if;
                        
                        if req_idx >= 2 or ack_idx > 0 then
                            if ack_idx < WARP_SIZE then
                                thread_data(ack_idx) <= reg_read_data(3) & reg_read_data(2) & reg_read_data(1) & reg_read_data(0);
                                ack_idx <= ack_idx + 1;
                            end if;
                        end if;
                        
                        if ack_idx = WARP_SIZE then
                            scan_idx <= 0;
                            state <= FIND_UNSERVED;
                        end if;

                    -- Scan the bitmask to find the next active, unserved thread to act as the burst base
                    when FIND_UNSERVED =>
                        if thread_served(scan_idx) = '0' then
                            burst_base_addr <= thread_addrs(scan_idx);
                            burst_start_idx <= scan_idx; burst_len <= 1;
                            state <= COALESCE_EVAL;
                        else
                            if scan_idx = WARP_SIZE - 1 then state <= FINISH;
                            else scan_idx <= scan_idx + 1; end if;
                        end if;

                    -- Check if sequential threads have contiguous addresses (+16 bytes) to bundle them
                    when COALESCE_EVAL =>
                        next_idx := burst_start_idx + burst_len;
                        
                        -- Array bounds checks must be separated to prevent fatal elaboration errors
                        if next_idx >= WARP_SIZE then
                            state <= DISPATCH;
                        elsif thread_served(next_idx) = '1' then
                            state <= DISPATCH;
                        elsif thread_addrs(next_idx) = burst_base_addr + to_unsigned(burst_len * 16, ADDR_WIDTH) then
                            burst_len <= burst_len + 1;
                            state <= COALESCE_EVAL;
                        else
                            state <= DISPATCH;
                        end if;

                    -- Issue the generated command to the Avalon-MM Burst Bridge
                    when DISPATCH =>
                        cmd_addr <= std_logic_vector(burst_base_addr);
                        cmd_burst_len <= std_logic_vector(to_unsigned(burst_len, 8)); 
                        cmd_is_store <= is_store;
                        
                        if is_store = '1' then
                            cmd_valid <= '1';
                            if cmd_ready = '1' then
                                words_handled <= 0;
                                state <= HANDLE_WRITE;
                            end if;
                        else
                            -- Always hold cmd_valid high once in DISPATCH to satisfy the multicycle handshake.
                            -- Only restrict the actual acceptance (cmd_ready) with the FIFO check to prevent race conditions.
                            cmd_valid <= '1'; 
                            
                            if v_fifo_count < 16 then 
                                if cmd_ready = '1' then
                                    for i in 0 to WARP_SIZE - 1 loop
                                        if i >= burst_start_idx and i < burst_start_idx + burst_len then
                                            thread_served(i) <= '1';
                                        end if;
                                    end loop;
                                    
                                    -- Push the read request to the tracking FIFO so the receiver knows where to route it
                                    v_fifo(v_fifo_tail).start_idx := burst_start_idx;
                                    v_fifo(v_fifo_tail).len := burst_len;
                                    v_fifo_count := v_fifo_count + 1;
                                    if v_fifo_tail = 15 then v_fifo_tail := 0; else v_fifo_tail := v_fifo_tail + 1; end if;
                                    
                                    scan_idx <= 0;
                                    state <= FIND_UNSERVED;
                                end if;
                            end if;
                        end if;

                    -- Stream coalesced data words to the Avalon bus (Only runs on Store instructions)
                    when HANDLE_WRITE =>
                        target_th_tx := burst_start_idx + words_handled;
                        
                        -- Default assignment: output the current word
                        tx_valid <= '1'; tx_data <= thread_data(target_th_tx);
                        
                        -- Ensure tx_valid is physically asserted on the bus before assuming the bridge consumed the data.
                        -- This prevents skipping the first word due to 1-cycle signal assignment delays.
                        if tx_valid = '1' and tx_ready = '1' then
                            thread_served(target_th_tx) <= '1';
                            words_handled <= words_handled + 1;
                            report "Writing data: " & to_hstring(tx_data);
                            
                            if words_handled = burst_len - 1 then
                                tx_valid <= '0';
                                scan_idx <= 0; state <= FIND_UNSERVED;
                            else
                                -- 1-cycle pipeline lookahead: If the transfer was successful, preemptively place 
                                -- the next word on the bus for the next clock cycle. This prevents duplicated words
                                -- when the memory controller randomly stalls.
                                tx_data <= thread_data(target_th_tx + 1);
                            end if;
                        end if;

                    -- Wait for all pending reads in the tracking FIFO to return before un-stalling the processor
                    when FINISH => 
                        if is_store = '1' or v_fifo_count = 0 then
                            mem_stall <= '0';
                            state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
