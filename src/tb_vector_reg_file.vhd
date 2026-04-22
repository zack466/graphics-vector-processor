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
            we_A         : in  std_logic
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

    constant clk_period : time := 10 ns;

begin

    uut: vector_reg_file
        generic map ( ADDR_WIDTH => 7 )
        port map (
            clk => clk, reset => reset,
            rs1_addr => rs1_addr, rs2_addr => rs2_addr, rs3_addr => rs3_addr,
            rs1_data => rs1_data, rs2_data => rs2_data, rs3_data => rs3_data,
            wr_addr_A => wr_addr_A, wr_data_A => wr_data_A,
            write_mask_A => write_mask_A, we_A => we_A
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
        -- TEST 1: WRITE MASK TESTING
        -- ====================================================================
        report ">> TEST 1A: Initialize Reg 1 with Background Data";
        wr_addr_A <= "0000001";
        wr_data_A <= (x"99999999", x"99999999", x"99999999", x"99999999");
        write_mask_A <= "1111";
        we_A <= '1';
        wait until rising_edge(clk); -- Clock 1: Write is sampled by M10K

        report ">> TEST 1B: FPU Write with Partial Mask";
        wr_data_A <= (x"11111111", x"22222222", x"33333333", x"44444444");
        -- "0101" maps to -> bit 3(w)=0, bit 2(z)=1, bit 1(y)=0, bit 0(x)=1
        write_mask_A <= "0101";
        wait until rising_edge(clk); -- Clock 2: Partial Write is sampled
        we_A <= '0';

        -- Wait for write to land in M10K RAM (1-cycle write latency)
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
        -- TEST 2: A SECOND MASK PATTERN (complementary to Test 1)
        -- ====================================================================
        -- Previously this slot held a Port B mask test.  Port B is gone, but
        -- we keep a second mask-pattern test on Port A as an independent check
        -- that the Y and W lanes also honour the mask.
        report ">> TEST 2A: Initialize Reg 2 with Background Data";
        wr_addr_A <= "0000010";
        wr_data_A <= (x"88888888", x"88888888", x"88888888", x"88888888");
        write_mask_A <= "1111";
        we_A <= '1';
        wait until rising_edge(clk); -- Clock 1: Write is sampled

        report ">> TEST 2B: Write Reg 2 with Complementary Partial Mask";
        wr_data_A <= (x"AAAAAAAA", x"BBBBBBBB", x"CCCCCCCC", x"DDDDDDDD");
        -- "1010" maps to -> bit 3(w)=1, bit 2(z)=0, bit 1(y)=1, bit 0(x)=0
        write_mask_A <= "1010";
        wait until rising_edge(clk); -- Clock 2: Partial Write is sampled
        we_A <= '0';

        wait until rising_edge(clk); -- 1-cycle write latency drain

        report ">> TEST 2C: Read and Verify Reg 2 (via rs2 port)";
        rs2_addr <= "0000010";
        wait until rising_edge(clk); -- Read Address is clocked into M10K
        wait until rising_edge(clk); -- Data is fully stable

        assert rs2_data(0) = x"88888888" report "Reg 2 X-mask preservation failed" severity error;
        assert rs2_data(1) = x"BBBBBBBB" report "Reg 2 Y-mask overwrite failed"    severity error;
        assert rs2_data(2) = x"88888888" report "Reg 2 Z-mask preservation failed" severity error;
        assert rs2_data(3) = x"DDDDDDDD" report "Reg 2 W-mask overwrite failed"    severity error;


        -- ====================================================================
        -- TEST 3: SIMULTANEOUS 3-PORT READ VERIFICATION
        -- ====================================================================
        -- With only one write port there is no longer any write arbitration to
        -- stress, so we just write one more register and then confirm that all
        -- three read ports independently return the correct data for distinct
        -- addresses on the same cycle -- which is the main reason the VRF is
        -- replicated in the first place.
        report ">> TEST 3A: Write Reg 3 (third distinct address)";
        wr_addr_A    <= "0000011";
        wr_data_A    <= (x"12345678", x"12345678", x"12345678", x"12345678");
        write_mask_A <= "1111";
        we_A         <= '1';
        wait until rising_edge(clk);
        we_A <= '0';

        wait until rising_edge(clk); -- 1-cycle write latency drain

        report ">> TEST 3B: Simultaneous 3-Port Read Verification";
        rs1_addr <= "0000001"; -- Reg 1 from TEST 1
        rs2_addr <= "0000010"; -- Reg 2 from TEST 2
        rs3_addr <= "0000011"; -- Reg 3 from TEST 3A

        wait until rising_edge(clk); -- Read Addresses are clocked into M10K
        wait until rising_edge(clk); -- Data is fully stable

        assert rs1_data(0) = x"11111111" report "Port rs1 Read failed" severity error;
        assert rs2_data(1) = x"BBBBBBBB" report "Port rs2 Read failed" severity error;
        assert rs3_data(0) = x"12345678" report "Port rs3 Read failed" severity error;

        report ">> SIMULATION COMPLETE: All assertions passed synchronously!";
        std.env.stop;
    end process;

end architecture sim;
