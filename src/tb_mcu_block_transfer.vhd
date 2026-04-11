library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_mcu_block_transfer is
end entity;

architecture sim of tb_mcu_block_transfer is
    constant WARP_SIZE  : integer := 32;
    constant ADDR_WIDTH : integer := 32;
    constant DATA_WIDTH : integer := 128;
    constant CLK_PERIOD : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- MCU Control Signals
    signal mem_op_valid     : std_logic := '0';
    signal base_addr        : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
    signal dest_src_reg_idx : std_logic_vector(3 downto 0) := "0001";
    signal exec_mask        : std_logic_vector(WARP_SIZE-1 downto 0) := (others => '1');
    signal mem_stall        : std_logic;

    -- Snooped Store Data
    signal mem_store_valid  : std_logic := '0';
    signal mem_store_thread : std_logic_vector(4 downto 0) := (others => '0');
    signal mem_store_data   : vector_t := (others => (others => '0'));

    -- Avalon Bridge Command
    signal cmd_valid        : std_logic;
    signal cmd_is_store     : std_logic;
    signal cmd_addr         : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal cmd_burst_len    : std_logic_vector(7 downto 0);
    signal cmd_ready        : std_logic := '0';

    -- Avalon Bridge TX
    signal tx_data          : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal tx_byte_en       : std_logic_vector((DATA_WIDTH/8)-1 downto 0);
    signal tx_valid         : std_logic;
    signal tx_ready         : std_logic := '0';

begin
    clk <= not clk after CLK_PERIOD / 2;

    u_mcu : entity work.mcu_block_transfer
        port map (
            clk => clk, reset => reset,
            mem_op_valid => mem_op_valid,
            base_addr => base_addr, dest_src_reg_idx => dest_src_reg_idx,
            exec_mask => exec_mask,
            mem_stall => mem_stall,
            mem_store_valid => mem_store_valid, mem_store_thread => mem_store_thread, mem_store_data => mem_store_data,
            cmd_valid => cmd_valid, cmd_is_store => cmd_is_store, cmd_addr => cmd_addr,
            cmd_burst_len => cmd_burst_len, cmd_ready => cmd_ready,
            tx_data => tx_data, tx_byte_en => tx_byte_en, tx_valid => tx_valid, tx_ready => tx_ready
        );

    process
    begin
        -- Reset
        wait for 2 * CLK_PERIOD;
        reset <= '0';
        wait for CLK_PERIOD;

        -- Test Block Store:
        -- Step 1: simulate the execution unit snooping 32 threads (this happens
        -- while the barrel scheduler issues threads 0-31 during EXEC_WAIT).
        -- mem_op_valid is only pulsed AFTER all snoop data is in the buffer,
        -- matching the actual processor flow.
        for i in 0 to 31 loop
            wait until rising_edge(clk);
            mem_store_valid <= '1';
            mem_store_thread <= std_logic_vector(to_unsigned(i, 5));
            -- Pixel data: lower 8 bits of each 32-bit XYZW component
            mem_store_data(0) <= std_logic_vector(to_unsigned(i * 4 + 0, 32)); -- X
            mem_store_data(1) <= std_logic_vector(to_unsigned(i * 4 + 1, 32)); -- Y
            mem_store_data(2) <= std_logic_vector(to_unsigned(i * 4 + 2, 32)); -- Z
            mem_store_data(3) <= std_logic_vector(to_unsigned(i * 4 + 3, 32)); -- W
        end loop;
        wait until rising_edge(clk);
        mem_store_valid <= '0';
        report "Finished feeding store data";

        -- Step 2: pulse mem_op_valid to trigger the block transfer.
        -- The MCU latches base_addr and exec_mask on this cycle, then immediately
        -- asserts mem_stall and transitions to STORE_CMD.
        base_addr <= x"00001000";
        mem_op_valid <= '1';
        wait until rising_edge(clk);
        mem_op_valid <= '0';

        -- Verify that command is issued to the bridge
        report "Waiting for cmd_valid...";
        wait until cmd_valid = '1';
        report "Got cmd_valid!";
        cmd_ready <= '1';
        wait until rising_edge(clk);
        cmd_ready <= '0';

        -- Verify that 8 TX beats are pushed to the bridge
        report "Waiting for tx beats...";
        for i in 0 to 7 loop
            if tx_valid = '0' then
                wait until tx_valid = '1';
            end if;
            report "Got tx_valid beat " & integer'image(i);
            tx_ready <= '1';
            wait until rising_edge(clk);
            tx_ready <= '0';
        end loop;

        for i in 0 to 5 loop
            wait until rising_edge(clk);
        end loop;

        assert mem_stall = '0' report "Mem stall not deasserted" severity failure;

        -- Finish
        report "Simulation Completed Successfully." severity note;
        std.env.stop;
    end process;
end architecture sim;
