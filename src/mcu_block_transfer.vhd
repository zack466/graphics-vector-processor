library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity mcu_block_transfer is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128;
        REG_WIDTH  : integer := 4
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- Processor Control
        mem_op_valid      : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        dest_src_reg_idx  : in  std_logic_vector(REG_WIDTH-1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        -- Snooped Store Data from Execution Unit (S1 stage)
        mem_store_valid   : in  std_logic;
        mem_store_thread  : in  std_logic_vector(4 downto 0);
        mem_store_data    : in  vector_t;

        -- Avalon Burst Bridge Command Channel
        cmd_valid         : out std_logic;
        cmd_is_store      : out std_logic;
        cmd_addr          : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : out std_logic_vector(7 downto 0);
        cmd_ready         : in  std_logic;

        -- Avalon Burst Bridge TX Channel (Writes)
        tx_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        tx_byte_en        : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        tx_valid          : out std_logic;
        tx_ready          : in  std_logic
    );
end entity;

architecture rtl of mcu_block_transfer is

    type state_t is (IDLE, STORE_CMD, STORE_BURST);
    signal state : state_t := IDLE;

    -- 1024-bit warp output buffer (32 pixels, each 32 bits).
    type buffer_t is array(0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal warp_buffer : buffer_t;

    signal latched_base_addr : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal latched_dest_reg  : std_logic_vector(REG_WIDTH-1 downto 0);
    signal latched_exec_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal burst_count       : integer range 0 to 8 := 0;

begin

    -- Store Buffer Write Port (always listens to snooped data)
    process(clk)
    begin
        if rising_edge(clk) then
            if mem_store_valid = '1' then
                -- Pack RGBA components (assuming they are correctly converted to 0-255 by FPU FLOAT2FIX)
                -- W[7:0] & Z[7:0] & Y[7:0] & X[7:0]
                warp_buffer(to_integer(unsigned(mem_store_thread))) <= 
                    mem_store_data(3)(7 downto 0) & 
                    mem_store_data(2)(7 downto 0) & 
                    mem_store_data(1)(7 downto 0) & 
                    mem_store_data(0)(7 downto 0);
            end if;
        end if;
    end process;

    -- Main Control FSM
    process(clk)
        variable avm_word : std_logic_vector(127 downto 0);
        variable rx_idx : integer range 0 to 31;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                mem_stall <= '0';
                cmd_valid <= '0';
                tx_valid <= '0';
                burst_count <= 0;
            else
                case state is
                    when IDLE =>
                        if mem_op_valid = '1' then
                            mem_stall <= '1';
                            latched_base_addr <= base_addr;
                            latched_dest_reg <= dest_src_reg_idx;
                            latched_exec_mask <= exec_mask;
                            -- Data is already snooped and in warp_buffer because mem_op_valid 
                            -- is pulsed AFTER the barrel scheduler finishes the 32 threads.
                            state <= STORE_CMD;
                        else
                            mem_stall <= '0';
                        end if;

                    when STORE_CMD =>
                        cmd_valid <= '1';
                        cmd_is_store <= '1';
                        cmd_addr <= latched_base_addr;
                        cmd_burst_len <= std_logic_vector(to_unsigned(8, 8)); -- 8 128-bit beats = 32 pixels
                        if cmd_valid = '1' and cmd_ready = '1' then
                            cmd_valid <= '0';
                            burst_count <= 0;
                            tx_valid <= '1';
                            -- Drive first beat data combinationally
                            avm_word := warp_buffer(0+3) & warp_buffer(0+2) & warp_buffer(0+1) & warp_buffer(0+0);
                            tx_data <= avm_word;
                            
                            -- Build byte enable based on execution mask
                            for b in 0 to 3 loop
                                if latched_exec_mask(0+b) = '1' then
                                    tx_byte_en((b*4)+3 downto b*4) <= "1111";
                                else
                                    tx_byte_en((b*4)+3 downto b*4) <= "0000";
                                end if;
                            end loop;
                            
                            state <= STORE_BURST;
                        end if;

                    when STORE_BURST =>
                        if tx_valid = '1' and tx_ready = '1' then
                            if burst_count = 7 then
                                tx_valid <= '0';
                                mem_stall <= '0';
                                state <= IDLE;
                            else
                                burst_count <= burst_count + 1;
                                avm_word := warp_buffer((burst_count+1)*4+3) & 
                                            warp_buffer((burst_count+1)*4+2) & 
                                            warp_buffer((burst_count+1)*4+1) & 
                                            warp_buffer((burst_count+1)*4+0);
                                tx_data <= avm_word;
                                
                                -- Update byte enable for next beat
                                for b in 0 to 3 loop
                                    if latched_exec_mask(((burst_count+1)*4)+b) = '1' then
                                        tx_byte_en((b*4)+3 downto b*4) <= "1111";
                                    else
                                        tx_byte_en((b*4)+3 downto b*4) <= "0000";
                                    end if;
                                end loop;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
