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

    signal latched_addr     : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal latched_len      : std_logic_vector(7 downto 0);
    signal burst_words_left : unsigned(7 downto 0);
begin

    -- RX Bypass (DDR3 -> Bridge -> MCU)
    rx_data  <= avm_readdata;
    rx_valid <= avm_readdatavalid;

    -- TX Combinational Mapping
    avm_write      <= tx_valid when state = AVM_WRITE_BURST else '0';
    avm_writedata  <= tx_data;
    avm_byteenable <= tx_byte_en when state = AVM_WRITE_BURST else (others => '1');
    avm_address    <= latched_addr;
    avm_burstcount <= latched_len;
    
    -- FIFO Pop mechanism mapping directly to Avalon Waitrequest
    tx_ready       <= not avm_waitrequest when state = AVM_WRITE_BURST else '0';
    
    avm_read       <= '1' when state = AVM_ISSUE_READ else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                cmd_ready <= '0';
            else
                cmd_ready <= '0';

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
                        -- Check valid and waitrequest to iterate through the burst
                        if tx_valid = '1' and avm_waitrequest = '0' then
                            if burst_words_left = 1 then
                                state <= IDLE;
                            else
                                burst_words_left <= burst_words_left - 1;
                            end if;
                        end if;

                    when AVM_ISSUE_READ =>
                        if avm_waitrequest = '0' then
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;
end architecture rtl;
