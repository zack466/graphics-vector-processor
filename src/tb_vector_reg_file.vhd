library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity tb_vector_reg_file is
end entity tb_vector_reg_file;

architecture sim of tb_vector_reg_file is

    component vector_reg_file
        generic ( ADDR_WIDTH : integer := 7 );
        port (
            clk          : in  std_logic;
            reset        : in  std_logic;
            rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            rs3_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            rs1_data     : out vector_t;
            rs2_data     : out vector_t;
            rs3_data     : out vector_t;
            wr_addr_A    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            wr_data_A    : in  vector_t;
            write_mask_A : in  std_logic_vector(3 downto 0);
            we_A         : in  std_logic;
            rd_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            rd_data_B    : out vector_t;
            wr_addr_B    : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
            wr_data_B    : in  vector_t;
            write_mask_B : in  std_logic_vector(3 downto 0);
            we_B         : in  std_logic
        );
    end component;

    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';
    
    signal rs1_addr, rs2_addr, rs3_addr : std_logic_vector(6 downto 0) := (others => '0');
    signal rs1_data, rs2_data, rs3_data : vector_t;
    
    signal wr_addr_A    : std_logic_vector(6 downto 0) := (others => '0');
    signal wr_data_A    : vector_t := (others => (others => '0'));
    signal write_mask_A : std_logic_vector(3 downto 0) := "0000";
    signal we_A         : std_logic := '0';
    
    signal rd_addr_B    : std_logic_vector(6 downto 0) := (others => '0');
    signal rd_data_B    : vector_t;
    signal wr_addr_B    : std_logic_vector(6 downto 0) := (others => '0');
    signal wr_data_B    : vector_t := (others => (others => '0'));
    signal write_mask_B : std_logic_vector(3 downto 0) := "0000";
    signal we_B         : std_logic := '0';

    constant clk_period : time := 10 ns;

begin

    uut: vector_reg_file
        generic map ( ADDR_WIDTH => 7 )
        port map (
            clk => clk, reset => reset,
            rs1_addr => rs1_addr, rs2_addr => rs2_addr, rs3_addr => rs3_addr,
            rs1_data => rs1_data, rs2_data => rs2_data, rs3_data => rs3_data,
            wr_addr_A => wr_addr_A, wr_data_A => wr_data_A, write_mask_A => write_mask_A, we_A => we_A,
            rd_addr_B => rd_addr_B, rd_data_B => rd_data_B, wr_addr_B => wr_addr_B, wr_data_B => wr_data_B,
            write_mask_B => write_mask_B, we_B => we_B
        );

    clk_process :process
    begin
        clk <= '0'; wait for clk_period/2;
        clk <= '1'; wait for clk_period/2;
    end process;

    stim_proc: process
    begin
        -- Wait for global reset
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- TEST 1: PORT A MASK TESTING
        -- ====================================================================
        report ">> TEST 1A: Initialize Reg 1 (Port A) with Background Data";
        wr_addr_A <= "0000001";
        wr_data_A <= (x"99999999", x"99999999", x"99999999", x"99999999");
        write_mask_A <= "1111";
        we_A <= '1';
        wait until rising_edge(clk); -- Clock 1: Write is sampled by M10K
        
        report ">> TEST 1B: FPU Write (Port A) with Partial Mask";
        wr_data_A <= (x"11111111", x"22222222", x"33333333", x"44444444");
        -- "0101" maps to -> bit 3(w)=0, bit 2(z)=1, bit 1(y)=0, bit 0(x)=1
        write_mask_A <= "0101"; 
        wait until rising_edge(clk); -- Clock 2: Partial Write is sampled
        we_A <= '0';
        
        -- FIX: Wait for Port A write pipeline to drain (Arb Bus -> M10K RAM)
        wait until rising_edge(clk); 
        
        report ">> TEST 1C: Read and Verify Reg 1";
        rs1_addr <= "0000001";
        wait until rising_edge(clk); -- Read Address is clocked into M10K
        wait until rising_edge(clk); -- Data is fully stable

        assert rs1_data(0) = x"11111111" report "Reg 1 X-mask overwrite failed"    severity error;
        assert rs1_data(1) = x"99999999" report "Reg 1 Y-mask preservation failed" severity error;
        assert rs1_data(2) = x"33333333" report "Reg 1 Z-mask overwrite failed"    severity error;
        assert rs1_data(3) = x"99999999" report "Reg 1 W-mask preservation failed" severity error;
        

        -- ====================================================================
        -- TEST 2: PORT B MASK TESTING
        -- ====================================================================
        report ">> TEST 2A: Initialize Reg 2 (Port B) with Background Data";
        wr_addr_B <= "0000010";
        wr_data_B <= (x"88888888", x"88888888", x"88888888", x"88888888");
        write_mask_B <= "1111";
        we_B <= '1';
        wait until rising_edge(clk); -- Clock 1: Write is sampled

        report ">> TEST 2B: MCU Write (Port B) with Partial Mask";
        wr_data_B <= (x"AAAAAAAA", x"BBBBBBBB", x"CCCCCCCC", x"DDDDDDDD");
        -- "1010" maps to -> bit 3(w)=1, bit 2(z)=0, bit 1(y)=1, bit 0(x)=0
        write_mask_B <= "1010"; 
        wait until rising_edge(clk); -- Clock 2: Partial Write is sampled by FIFO
        we_B <= '0';
        
        -- FIX: Wait for Port B write pipeline to drain (FIFO -> Arb Bus -> M10K RAM)
        wait until rising_edge(clk); 
        wait until rising_edge(clk); 
        
        report ">> TEST 2C: Read and Verify Reg 2";
        rs2_addr <= "0000010";
        wait until rising_edge(clk); -- Read Address is clocked into M10K
        wait until rising_edge(clk); -- Data is fully stable

        assert rs2_data(0) = x"88888888" report "Reg 2 X-mask preservation failed" severity error;
        assert rs2_data(1) = x"BBBBBBBB" report "Reg 2 Y-mask overwrite failed"    severity error;
        assert rs2_data(2) = x"88888888" report "Reg 2 Z-mask preservation failed" severity error;
        assert rs2_data(3) = x"DDDDDDDD" report "Reg 2 W-mask overwrite failed"    severity error;


        -- ====================================================================
        -- TEST 3: SIMULTANEOUS MULTI-PORT STRESS TEST
        -- ====================================================================
        report ">> TEST 3A: Simultaneous Port A and Port B Write";
        wr_addr_A <= "0000011";
        wr_data_A <= (x"12345678", x"12345678", x"12345678", x"12345678");
        write_mask_A <= "1111";
        we_A <= '1';
        
        wr_addr_B <= "0000100";
        wr_data_B <= (x"87654321", x"87654321", x"87654321", x"87654321");
        write_mask_B <= "1111";
        we_B <= '1';
        
        wait until rising_edge(clk); -- Writes are sampled simultaneously
        we_A <= '0'; we_B <= '0';

        -- FIX: Wait for simultaneous writes to drain.
        -- Cycle 1: Port A writes to RAM, Port B pops to Arb Bus
        wait until rising_edge(clk);
        -- Cycle 2: Port B writes to RAM
        wait until rising_edge(clk);

        report ">> TEST 3B: Simultaneous 4-Port Read Verification";
        rs1_addr  <= "0000001";
        rs2_addr  <= "0000010";
        rs3_addr  <= "0000011";
        rd_addr_B <= "0000100";
        
        wait until rising_edge(clk); -- Read Addresses are clocked into M10K
        wait until rising_edge(clk); -- Data is fully stable

        assert rs1_data(0)  = x"11111111" report "Port 1 Read failed" severity error;
        assert rs2_data(1)  = x"BBBBBBBB" report "Port 2 Read failed" severity error;
        assert rs3_data(0)  = x"12345678" report "Port 3 Read failed" severity error;
        assert rd_data_B(0) = x"87654321" report "Port 4 Read failed" severity error;

        report ">> SIMULATION COMPLETE: All assertions passed synchronously!";
        std.env.stop;
    end process;

end architecture sim;
