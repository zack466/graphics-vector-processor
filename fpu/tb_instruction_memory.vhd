library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;

entity tb_instruction_memory is
end entity tb_instruction_memory;

architecture sim of tb_instruction_memory is

    constant CLK_PERIOD : time := 10 ns;

    -- Signals
    signal clk     : std_logic := '0';
    signal we      : std_logic := '0';
    signal wr_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal wr_data : word_t := (others => '0');
    signal rd_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_data : word_t;

    -- Prime stride for pseudo-random address generation
    constant STRIDE : integer := 137;

begin

    clk_process: process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    uut: entity work.instruction_memory
        generic map ( ADDR_WIDTH => 8 )
        port map (
            clk     => clk,
            we      => we,
            wr_addr => wr_addr,
            wr_data => wr_data,
            rd_addr => rd_addr,
            rd_data => rd_data
        );

    stim_proc: process
        variable expected_data : word_t;
        variable test_addr     : integer;
    begin
        wait until rising_edge(clk);

        -- ====================================================================
        -- PHASE 1: Write 256 Sequential Instructions
        -- ====================================================================
        report ">> PHASE 1: Writing 256 dummy instructions sequentially...";
        we <= '1';
        for i in 0 to 255 loop
            wr_addr <= std_logic_vector(to_unsigned(i, 8));
            -- Create a recognizable payload (e.g., Address * 1024 + 42)
            wr_data <= std_logic_vector(to_unsigned(i * 1024 + 42, 32)); 
            wait until rising_edge(clk);
        end loop;
        we <= '0';

        -- ====================================================================
        -- PHASE 2: Pseudo-Random Reads
        -- ====================================================================
        report ">> PHASE 2: Reading back in pseudo-random order...";
        for i in 0 to 255 loop
            -- Generate a pseudo-random address using the prime stride
            test_addr := (i * STRIDE) mod 256;
            rd_addr   <= std_logic_vector(to_unsigned(test_addr, 8));

            wait until rising_edge(clk);  -- Clock the address into the M10K block
            wait until falling_edge(clk); -- Wait for the data to stabilize
            
            -- Calculate what the payload SHOULD be
            expected_data := std_logic_vector(to_unsigned(test_addr * 1024 + 42, 32));
            
            assert rd_data = expected_data 
                report "Data mismatch at address " & integer'image(test_addr) & "!" severity error;
                
            wait until rising_edge(clk);
        end loop;

        report ">> SIMULATION COMPLETE: All 256 pseudo-random reads passed successfully!";
        std.env.stop;
    end process;

end architecture sim;
