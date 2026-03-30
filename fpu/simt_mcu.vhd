library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Assuming this contains vector_t, word_t, and related types
use work.vector_types_pkg.all;

entity simt_mcu is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Processor Control
        -- ==========================================
        mem_op_valid      : in  std_logic;
        is_store          : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0); 
        offset_reg_idx    : in  std_logic_vector(1 downto 0);
        dest_src_reg_idx  : in  std_logic_vector(1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        
        mem_stall         : out std_logic;

        -- ==========================================
        -- Register File Access (Port B - MCU Dedicated)
        -- ==========================================
        reg_read_addr     : out std_logic_vector(6 downto 0); 
        reg_read_data     : in  vector_t; 
        
        reg_write_addr    : out std_logic_vector(6 downto 0);
        reg_write_data    : out vector_t;
        reg_write_en      : out std_logic;

        -- ==========================================
        -- Interface to AVM Burst Master
        -- ==========================================
        cmd_valid         : out std_logic;
        cmd_is_store      : out std_logic;
        cmd_addr          : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : out std_logic_vector(7 downto 0);
        cmd_ready         : in  std_logic;
        
        wr_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        wr_valid          : out std_logic;
        wr_ready          : in  std_logic;
        
        rd_data           : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_valid          : in  std_logic
    );
end entity;

architecture rtl of simt_mcu is

    type state_t is (
        IDLE, 
        GATHER_REQ, 
        GATHER_ACK, 
        FIND_UNSERVED, 
        COALESCE_EVAL, 
        DISPATCH, 
        HANDLE_WRITE,
        HANDLE_READ,
        FINISH
    );
    signal state : state_t;

    -- Internal Storage for the 32 Threads
    type addr_array_t is array (0 to WARP_SIZE-1) of unsigned(ADDR_WIDTH-1 downto 0);
    type data_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    
    signal thread_addrs  : addr_array_t;
    signal thread_data   : data_array_t;
    signal thread_served : std_logic_vector(WARP_SIZE-1 downto 0);
    
    -- Counters and Trackers
    signal req_idx       : integer range 0 to WARP_SIZE;
    signal ack_idx       : integer range 0 to WARP_SIZE;
    signal scan_idx      : integer range 0 to WARP_SIZE;
    
    -- Burst Tracking
    signal burst_base_addr : unsigned(ADDR_WIDTH-1 downto 0);
    signal burst_start_idx : integer range 0 to WARP_SIZE;
    signal burst_len       : integer range 0 to WARP_SIZE + 1;
    signal words_handled   : integer range 0 to WARP_SIZE;

begin

    process(clk)
        variable next_idx  : integer;
        variable target_th : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state        <= IDLE;
                mem_stall    <= '0';
                cmd_valid    <= '0';
                reg_write_en <= '0';
                wr_valid     <= '0';
            else
                
                -- Default strobes
                reg_write_en <= '0';
                cmd_valid    <= '0';
                wr_valid     <= '0';

                case state is
                
                    -- ========================================================
                    when IDLE =>
                        if mem_op_valid = '1' then
                            mem_stall <= '1'; 
                            req_idx   <= 0;
                            ack_idx   <= 0;
                            -- Invert EXEC mask: Disabled threads are marked as "already served"
                            thread_served <= not exec_mask; 
                            state         <= GATHER_REQ;
                        else
                            mem_stall <= '0';
                        end if;

                    -- ========================================================
                    -- PIPELINED GATHER: Requesting data from RegFile
                    -- ========================================================
                    when GATHER_REQ =>
                        if req_idx < WARP_SIZE then
                            -- Read the Offset Register (or Store Data Register)
                            -- In a real design with 1 MCU read port, you might need 2 passes if storing.
                            -- For this implementation, we assume offset is in X, store data is in Y,Z,A.
                            reg_read_addr <= std_logic_vector(to_unsigned(req_idx, 5)) & offset_reg_idx;
                            req_idx <= req_idx + 1;
                        end if;
                        
                        -- The ACK phase runs 1 cycle behind the REQ phase to account for RAM latency
                        state <= GATHER_ACK;

                    when GATHER_ACK =>
                        -- Calculate the final memory address: Base + Offset
                        -- (Assuming offset is a 32-bit integer in the X coordinate)
                        thread_addrs(ack_idx) <= unsigned(base_addr) + unsigned(reg_read_data(0));
                        
                        -- Flatten the vector into a 128-bit word for the Avalon bus
                        thread_data(ack_idx) <= reg_read_data(3) & reg_read_data(2) & reg_read_data(1) & reg_read_data(0);
                        
                        ack_idx <= ack_idx + 1;
                        
                        -- Loop back to REQ, or move on if done
                        if ack_idx = WARP_SIZE - 1 then
                            scan_idx <= 0;
                            state    <= FIND_UNSERVED;
                        else
                            state <= GATHER_REQ;
                        end if;

                    -- ========================================================
                    -- COALESCING ENGINE: Find next unserved thread
                    -- ========================================================
                    when FIND_UNSERVED =>
                        if thread_served(scan_idx) = '0' then
                            burst_base_addr <= thread_addrs(scan_idx);
                            burst_start_idx <= scan_idx;
                            burst_len       <= 1;
                            state           <= COALESCE_EVAL;
                        else
                            if scan_idx = WARP_SIZE - 1 then
                                state <= FINISH; -- All active threads have been served
                            else
                                scan_idx <= scan_idx + 1;
                            end if;
                        end if;

                    -- ========================================================
                    -- COALESCING ENGINE: Check if sequential thread is contiguous
                    -- ========================================================
                    when COALESCE_EVAL =>
                        next_idx := burst_start_idx + burst_len;
                        
                        if next_idx >= WARP_SIZE then
                            -- End of the warp reached
                            state <= DISPATCH;
                            
                        elsif thread_served(next_idx) = '1' then
                            -- Divergence: The next thread is inactive or was part of a previous burst
                            state <= DISPATCH;
                            
                        elsif thread_addrs(next_idx) = burst_base_addr + (burst_len * 16) then
                            -- CONTIGUOUS! 16 bytes (128 bits) exactly.
                            -- Increment burst length and loop in this state to check the next one.
                            burst_len <= burst_len + 1;
                            
                        else
                            -- Divergence: Thread is active, but address is random/non-contiguous
                            state <= DISPATCH;
                        end if;

                    -- ========================================================
                    -- AVALON DISPATCH
                    -- ========================================================
                    when DISPATCH =>
                        cmd_valid     <= '1';
                        cmd_addr      <= std_logic_vector(burst_base_addr);
                        cmd_burst_len <= std_logic_vector(to_unsigned(burst_len, 8));
                        cmd_is_store  <= is_store;
                        
                        if cmd_ready = '1' then
                            words_handled <= 0;
                            if is_store = '1' then
                                state <= HANDLE_WRITE;
                            else
                                state <= HANDLE_READ;
                            end if;
                        end if;

                    -- ========================================================
                    -- AVALON WRITE (Scatter)
                    -- ========================================================
                    when HANDLE_WRITE =>
                        target_th := burst_start_idx + words_handled;
                        
                        wr_valid <= '1';
                        wr_data  <= thread_data(target_th);
                        
                        if wr_ready = '1' then
                            -- Data successfully written to the bus
                            thread_served(target_th) <= '1';
                            words_handled <= words_handled + 1;
                            
                            if words_handled = burst_len - 1 then
                                -- Burst complete. Go back and find the next unserved thread.
                                wr_valid <= '0';
                                scan_idx <= 0;
                                state    <= FIND_UNSERVED;
                            end if;
                        end if;

                    -- ========================================================
                    -- AVALON READ (Gather)
                    -- ========================================================
                    when HANDLE_READ =>
                        if rd_valid = '1' then
                            target_th := burst_start_idx + words_handled;
                            
                            -- Route incoming 128-bit data directly to the FPU Register File
                            reg_write_en   <= '1';
                            reg_write_addr <= std_logic_vector(to_unsigned(target_th, 5)) & dest_src_reg_idx;
                            
                            -- Unflatten the 128-bit word into the vector_t format
                            reg_write_data(0) <= rd_data(31 downto 0);
                            reg_write_data(1) <= rd_data(63 downto 32);
                            reg_write_data(2) <= rd_data(95 downto 64);
                            reg_write_data(3) <= rd_data(127 downto 96);
                            
                            thread_served(target_th) <= '1';
                            words_handled <= words_handled + 1;
                            
                            if words_handled = burst_len - 1 then
                                -- Burst complete. Find the next unserved thread.
                                scan_idx <= 0;
                                state    <= FIND_UNSERVED;
                            end if;
                        end if;

                    -- ========================================================
                    when FINISH =>
                        mem_stall <= '0'; -- Wake up the FPU pipeline!
                        state     <= IDLE;
                        
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
