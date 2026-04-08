library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity memory_unit is
    generic (
        WARP_SIZE  : integer := 32;
        ADDR_WIDTH : integer := 32;
        DATA_WIDTH : integer := 128;
        REG_WIDTH  : integer := 2
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Interface 1: Processor Control (From Issue/Decode)
        -- ==========================================
        mem_op_valid      : in  std_logic;
        is_store          : in  std_logic;
        base_addr         : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        offset_reg_idx    : in  std_logic_vector(REG_WIDTH-1 downto 0);
        dest_src_reg_idx  : in  std_logic_vector(REG_WIDTH-1 downto 0);
        exec_mask         : in  std_logic_vector(WARP_SIZE-1 downto 0);
        mem_stall         : out std_logic;

        -- ==========================================
        -- Interface 2: Vector Register File (Port B)
        -- ==========================================
        reg_read_addr     : out std_logic_vector(5 + REG_WIDTH - 1 downto 0); 
        reg_read_data     : in  vector_t; 
        reg_write_addr    : out std_logic_vector(5 + REG_WIDTH - 1 downto 0);
        reg_write_data    : out vector_t;
        reg_write_en      : out std_logic;

        -- ==========================================
        -- Interface 3: Avalon-MM Master (To External DDR3)
        -- ==========================================
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

architecture struct of memory_unit is

    -- ========================================================================
    -- Internal Interconnect Signals (MCU <-> Bridge)
    -- ========================================================================
    signal int_cmd_valid     : std_logic;
    signal int_cmd_is_store  : std_logic;
    signal int_cmd_addr      : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal int_cmd_burst_len : std_logic_vector(7 downto 0);
    signal int_cmd_ready     : std_logic;
    
    signal int_tx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_tx_byte_en    : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal int_tx_valid      : std_logic;
    signal int_tx_ready      : std_logic;
    
    signal int_rx_data       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal int_rx_valid      : std_logic;

begin

    -- ========================================================================
    -- INSTANTIATE: Scatter/Gather MCU
    -- ========================================================================
    u_mcu : entity work.mcu_scatter_gather
        generic map (
            WARP_SIZE  => WARP_SIZE,
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH,
            REG_WIDTH  => REG_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            -- Processor Control Interfaces
            mem_op_valid      => mem_op_valid,
            is_store          => is_store,
            base_addr         => base_addr,
            offset_reg_idx    => offset_reg_idx,
            dest_src_reg_idx  => dest_src_reg_idx,
            exec_mask         => exec_mask,
            mem_stall         => mem_stall,

            -- VRF Interfaces
            reg_read_addr     => reg_read_addr,
            reg_read_data     => reg_read_data,
            reg_write_addr    => reg_write_addr,
            reg_write_data    => reg_write_data,
            reg_write_en      => reg_write_en,

            -- Internal Bridge Interfaces
            cmd_valid         => int_cmd_valid,
            cmd_is_store      => int_cmd_is_store,
            cmd_addr          => int_cmd_addr,
            cmd_burst_len     => int_cmd_burst_len,
            cmd_ready         => int_cmd_ready,
            
            tx_data           => int_tx_data,
            tx_byte_en        => int_tx_byte_en,
            tx_valid          => int_tx_valid,
            tx_ready          => int_tx_ready,
            
            rx_data           => int_rx_data,
            rx_valid          => int_rx_valid
        );

    -- ========================================================================
    -- INSTANTIATE: Avalon Burst Bridge
    -- ========================================================================
    u_bridge : entity work.avm_burst_bridge
        generic map (
            ADDR_WIDTH => ADDR_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk               => clk,
            reset             => reset,

            -- Internal Bridge Interfaces
            cmd_valid         => int_cmd_valid,
            cmd_is_store      => int_cmd_is_store,
            cmd_addr          => int_cmd_addr,
            cmd_burst_len     => int_cmd_burst_len,
            cmd_ready         => int_cmd_ready,
            
            tx_data           => int_tx_data,
            tx_byte_en        => int_tx_byte_en,
            tx_valid          => int_tx_valid,
            tx_ready          => int_tx_ready,
            
            rx_data           => int_rx_data,
            rx_valid          => int_rx_valid,

            -- External Avalon-MM Master Interfaces
            avm_address       => avm_address,
            avm_burstcount    => avm_burstcount,
            avm_write         => avm_write,
            avm_writedata     => avm_writedata,
            avm_byteenable    => avm_byteenable,
            avm_read          => avm_read,
            avm_readdata      => avm_readdata,
            avm_readdatavalid => avm_readdatavalid,
            avm_waitrequest   => avm_waitrequest
        );

end architecture struct;
