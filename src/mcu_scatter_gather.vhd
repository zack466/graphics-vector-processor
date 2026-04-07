library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

-- =========================================================================================
-- MODULE: DECOUPLED SCATTER/GATHER MEMORY CONTROLLER (MCU)
-- =========================================================================================
-- DESCRIPTION:
-- This unit manages burst memory reads and writes between a 32-thread Vector Register 
-- File (VRF) and an external Avalon-MM bridge. It utilizes a Decoupled Architecture 
-- consisting of three internal FIFO buffers (Command, Write Data, and Load Tracking) 
-- to completely isolate the rigid timing of the processor pipeline from the unpredictable 
-- stall behavior (waitrequests) of external DDR3 memory.
--
-- ARCHITECTURE & FIFO BEHAVIOR:
-- 1. Frontend (State Machine): 
--    Scans the processor's active thread mask, calculates physical memory addresses by 
--    adding the base address to thread-specific offsets, and coalesces contiguous addresses 
--    (stride-1) into single burst commands. It blasts these commands and associated write 
--    data into the FIFOs at maximum clock speed.
-- 2. Middle (M10K FIFOs): 
--    Acts as an elastic buffer. Because they map to FPGA block RAM (M10K), they consume 
--    virtually zero ALMs. They gracefully absorb Avalon bus stalls without requiring complex 
--    pipeline skid buffers.
-- 3. Backend (Asynchronous Receiver): 
--    Listens for returning DDR3 read data. Because the frontend processor drops 'mem_stall' 
--    early and moves on, this receiver uses the "Load Tracking FIFO" to remember which 
--    destination register and thread index the incoming data belongs to.
--
-- EXACT CLOCK TIMINGS & LATENCIES:
-- * VRF Read Latency: STRICTLY 2 CYCLES.
--   - Cycle N:   MCU asserts `reg_read_addr`.
--   - Cycle N+1: VRF registers the address internally (M10K synchronous read requirement).
--   - Cycle N+2: Data is stable on `reg_read_data`. The MCU pushes this to the WDATA FIFO.
-- * Mem_Stall Behavior (Store): 
--   Drops immediately after the last VRF data word is pushed into the WDATA FIFO. The 
--   external bridge may still be writing to DDR3 in the background.
-- * Mem_Stall Behavior (Load): 
--   Drops immediately after the burst commands are pushed into the Command FIFO. The 
--   processor resumes execution WHILE memory is fetched. (Note: CPU scoreboarding or 
--   dependency checking must handle read-after-write hazards).
--
-- USAGE INSTRUCTIONS:
-- 1. Assert `base_addr`, `offset_reg_idx`, `dest_src_reg_idx`, `exec_mask`, and `is_store`.
-- 2. Pulse `mem_op_valid` high for EXACTLY 1 cycle.
-- 3. Wait for `mem_stall` to transition from '1' to '0'.
-- =========================================================================================

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

        -- AXI-Stream-Like Interface to External Bridge
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
    type state_t is (IDLE, GATHER_ADDR, FIND_UNSERVED, COALESCE_EVAL, DISPATCH, FETCH_WDATA, FINISH);
    signal state : state_t;

    type addr_array_t is array (0 to WARP_SIZE-1) of unsigned(ADDR_WIDTH-1 downto 0);
    signal thread_addrs  : addr_array_t;
    signal thread_served : std_logic_vector(WARP_SIZE-1 downto 0);
    
    signal req_idx, ack_idx, scan_idx : integer range 0 to WARP_SIZE;
    
    signal burst_base_addr : unsigned(ADDR_WIDTH-1 downto 0);
    signal burst_start_idx : integer range 0 to WARP_SIZE;
    signal burst_len       : integer range 0 to WARP_SIZE + 1;
    
    -- WDATA Pipeline Signals
    signal words_issued : integer range 0 to WARP_SIZE;
    signal words_pushed : integer range 0 to WARP_SIZE;
    
    -- Used to track the 2-cycle M10K read latency
    signal read_active_q1, read_active_q2 : std_logic;

    -- FIFO Signals
    signal cmd_din, cmd_dout       : std_logic_vector(ADDR_WIDTH + 8 downto 0); 
    signal cmd_wr_en, cmd_empty, cmd_full : std_logic;
    
    -- WIDENED to 18 bits: [dest_src(2) | len(8) | start_idx(8)]
    -- Rationale: The state machine moves on immediately after issuing a load. 
    -- We must latch the destination register index here so the async RX process 
    -- knows where to route the data when it finally returns cycles/memory-stalls later.
    signal track_din, track_dout   : std_logic_vector(17 downto 0); 
    signal track_wr_en, track_empty, track_full : std_logic;
    signal track_rd_en : std_logic;
    
    signal wdata_din               : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal wdata_wr_en, wdata_empty: std_logic;
    signal wdata_count             : integer range 0 to 64;
    signal wdata_space             : integer range 0 to 64;

    -- RX Signals
    signal rx_words_handled : integer range 0 to WARP_SIZE;
begin

    -- Standard vector graphics processors always write full 128-bit words
    tx_byte_en <= (others => '1');

    -- ========================================================================
    -- FIFO INSTANTIATIONS
    -- ========================================================================
    u_cmd_fifo : entity work.sync_fifo
        generic map( DATA_WIDTH => ADDR_WIDTH + 9, ADDR_WIDTH => 5 ) 
        port map( clk => clk, reset => reset, wr_en => cmd_wr_en, din => cmd_din, 
                  rd_en => cmd_ready and not cmd_empty, dout => cmd_dout, empty => cmd_empty, full => cmd_full, count => open );

    u_track_fifo : entity work.sync_fifo
        generic map( DATA_WIDTH => 18, ADDR_WIDTH => 5 ) 
        port map( clk => clk, reset => reset, wr_en => track_wr_en, din => track_din, 
                  rd_en => track_rd_en, dout => track_dout, empty => track_empty, full => track_full, count => open );

    u_wdata_fifo : entity work.sync_fifo
        generic map( DATA_WIDTH => DATA_WIDTH, ADDR_WIDTH => 6 ) 
        port map( clk => clk, reset => reset, wr_en => wdata_wr_en, din => wdata_din, 
                  rd_en => tx_ready and not wdata_empty, dout => tx_data, empty => wdata_empty, full => open, 
                  count => wdata_count ); 
                  
    -- Rationale: We calculate remaining space dynamically to ensure the state machine 
    -- never issues a burst fetch that would overflow the WDATA FIFO if the Avalon 
    -- bridge is currently stalled via waitrequest.
    wdata_space <= 64 - wdata_count; 

    -- Bridge Interface Mapping (Direct FIFO pops)
    cmd_valid     <= not cmd_empty;
    cmd_is_store  <= cmd_dout(ADDR_WIDTH + 8);
    cmd_burst_len <= cmd_dout(ADDR_WIDTH + 7 downto ADDR_WIDTH);
    cmd_addr      <= cmd_dout(ADDR_WIDTH - 1 downto 0);
    
    tx_valid      <= not wdata_empty;

    -- ========================================================================
    -- RX (LOAD RETURN) PROCESS (Asynchronous to Frontend State Machine)
    -- ========================================================================
    -- Rationale: Isolates incoming DDR3 data handling from instruction dispatch.
    -- This allows the processor to fetch the next instructions while waiting.
    process(clk)
        variable v_dest_src    : std_logic_vector(1 downto 0);
        variable v_track_len   : integer;
        variable v_track_start : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                rx_words_handled <= 0;
                reg_write_en <= '0';
                track_rd_en <= '0';
            else
                reg_write_en <= '0';
                track_rd_en <= '0';

                if rx_valid = '1' and track_empty = '0' then
                    -- Extract the latched context from the tracking FIFO
                    v_dest_src    := track_dout(17 downto 16);
                    v_track_len   := to_integer(unsigned(track_dout(15 downto 8)));
                    v_track_start := to_integer(unsigned(track_dout(7 downto 0)));

                    -- Write directly to VRF Port B. The VRF's internal collision 
                    -- FIFO handles arbitration if Port A is currently writing.
                    reg_write_en   <= '1'; 
                    reg_write_addr <= std_logic_vector(to_unsigned(v_track_start + rx_words_handled, 5)) & v_dest_src;
                    reg_write_data(0) <= rx_data(31 downto 0);   reg_write_data(1) <= rx_data(63 downto 32);
                    reg_write_data(2) <= rx_data(95 downto 64);  reg_write_data(3) <= rx_data(127 downto 96);
                    
                    if rx_words_handled = v_track_len - 1 then
                        rx_words_handled <= 0;
                        track_rd_en <= '1'; -- Burst complete, pop the tracking token
                    else
                        rx_words_handled <= rx_words_handled + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- DISPATCH STATE MACHINE (Frontend Coalescer)
    -- ========================================================================
    process(clk)
        variable next_idx : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                mem_stall <= '0'; cmd_wr_en <= '0'; track_wr_en <= '0'; wdata_wr_en <= '0';
                read_active_q1 <= '0'; read_active_q2 <= '0';
            else
                -- Default strobes
                cmd_wr_en <= '0'; track_wr_en <= '0'; wdata_wr_en <= '0';

                case state is
                    when IDLE =>
                        if mem_op_valid = '1' then
                            mem_stall <= '1'; req_idx <= 0; ack_idx <= 0;
                            -- Pre-load execution mask: inactive threads are marked as "served"
                            thread_served <= not exec_mask; 
                            read_active_q1 <= '0'; read_active_q2 <= '0';
                            state <= GATHER_ADDR;
                        end if;

                    when GATHER_ADDR =>
                        -- Pipeline Phase 1: Request offsets from VRF
                        if req_idx < WARP_SIZE then
                            reg_read_addr <= std_logic_vector(to_unsigned(req_idx, 5)) & offset_reg_idx;
                            req_idx <= req_idx + 1;
                        end if;
                        -- Pipeline Phase 2: Calculate absolute physical addresses
                        if req_idx >= 2 or ack_idx > 0 then
                            if ack_idx < WARP_SIZE then
                                thread_addrs(ack_idx) <= unsigned(base_addr) + unsigned(reg_read_data(0));
                                ack_idx <= ack_idx + 1;
                            end if;
                        end if;
                        
                        if ack_idx = WARP_SIZE then
                            scan_idx <= 0; state <= FIND_UNSERVED;
                        end if;

                    when FIND_UNSERVED =>
                        -- Scan for the lowest unserved active thread to act as the burst base
                        if scan_idx = WARP_SIZE then
                            state <= FINISH;
                        elsif thread_served(scan_idx) = '0' then
                            burst_base_addr <= thread_addrs(scan_idx);
                            burst_start_idx <= scan_idx; burst_len <= 1;
                            state <= COALESCE_EVAL;
                        else
                            scan_idx <= scan_idx + 1;
                        end if;

                    when COALESCE_EVAL =>
                        -- Lookahead to determine if the next thread is contiguous (+16 bytes)
                        next_idx := burst_start_idx + burst_len;
                        
                        -- Rationale: VHDL does not short-circuit boolean 'and'. If next_idx >= WARP_SIZE 
                        -- is evaluated in the same line as thread_served(next_idx), it causes an 
                        -- out-of-bounds simulation crash. They must be evaluated sequentially.
                        if next_idx < WARP_SIZE and thread_served(next_idx) = '0' and 
                           thread_addrs(next_idx) = burst_base_addr + to_unsigned(burst_len * 16, ADDR_WIDTH) then
                            burst_len <= burst_len + 1;
                        else
                            state <= DISPATCH;
                        end if;

                    when DISPATCH =>
                        -- Rationale: Throttle dispatch if FIFOs lack capacity. This prevents 
                        -- dropping commands during heavy DDR3 contention.
                        if cmd_full = '0' and track_full = '0' and wdata_space >= burst_len then
                            cmd_din <= is_store & std_logic_vector(to_unsigned(burst_len, 8)) & std_logic_vector(burst_base_addr);
                            cmd_wr_en <= '1';

                            -- Mark the coalesced chunk as served
                            for i in 0 to WARP_SIZE - 1 loop
                                if i >= burst_start_idx and i < burst_start_idx + burst_len then
                                    thread_served(i) <= '1';
                                end if;
                            end loop;

                            if is_store = '1' then
                                words_issued <= 0; words_pushed <= 0;
                                state <= FETCH_WDATA;
                            else
                                -- Append latched dest_src_reg_idx to the tracking token for Load instructions
                                track_din <= dest_src_reg_idx & std_logic_vector(to_unsigned(burst_len, 8)) & std_logic_vector(to_unsigned(burst_start_idx, 8));
                                track_wr_en <= '1';
                                scan_idx <= 0; state <= FIND_UNSERVED;
                            end if;
                        end if;

                    when FETCH_WDATA =>
                        -- -----------------------------------------------------------
                        -- 2-CYCLE VRF PIPELINE TRACKING
                        -- -----------------------------------------------------------
                        
                        -- Stage 1: Issue VRF Address (Cycle N)
                        if words_issued < burst_len then
                            reg_read_addr <= std_logic_vector(to_unsigned(burst_start_idx + words_issued, 5)) & dest_src_reg_idx;
                            words_issued <= words_issued + 1;
                            read_active_q1 <= '1';
                        else
                            read_active_q1 <= '0';
                        end if;

                        -- Stage 2: Wait for M10K RAM internal registration (Cycle N+1)
                        read_active_q2 <= read_active_q1;

                        -- Stage 3: Data is stable on bus, push to FIFO (Cycle N+2)
                        if read_active_q2 = '1' then
                            -- Re-pack the 4 distinct M10K component banks into a 128-bit vector
                            wdata_din <= reg_read_data(3) & reg_read_data(2) & reg_read_data(1) & reg_read_data(0);
                            wdata_wr_en <= '1';
                            
                            if words_pushed = burst_len - 1 then
                                scan_idx <= 0; state <= FIND_UNSERVED;
                            end if;
                            words_pushed <= words_pushed + 1;
                        end if;

                    when FINISH => 
                        -- Rationale: Drop mem_stall immediately once FIFOs are loaded.
                        -- We do not wait for the async RX tracking FIFO to empty.
                        mem_stall <= '0'; state <= IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
