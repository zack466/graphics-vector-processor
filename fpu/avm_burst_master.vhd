library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity avm_burst_master is
    generic (
        DATA_WIDTH : integer := 128;
        ADDR_WIDTH : integer := 32
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Internal Interface (To SIMT MCU)
        -- ==========================================
        cmd_valid         : in  std_logic;
        cmd_is_store      : in  std_logic;
        cmd_addr          : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        cmd_burst_len     : in  std_logic_vector(7 downto 0);
        cmd_ready         : out std_logic; -- High when ready to accept a new command

        -- Write Data Stream (From SIMT MCU)
        wr_data           : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        wr_valid          : in  std_logic;
        wr_ready          : out std_logic;

        -- Read Data Stream (To SIMT MCU)
        rd_data           : out std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_valid          : out std_logic;

        -- ==========================================
        -- External Interface (Avalon-MM)
        -- ==========================================
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_read          : out std_logic;
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic
    );
end entity;
