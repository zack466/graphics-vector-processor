----------------------------------------------------------------------------
--
--  TODO
-- 
--  Revision History:
--     20 May 25    Zack Huang      initial revision
--
----------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity sdram_agent_tb is
end sdram_agent_tb;

architecture behavioral of sdram_agent_tb is
    constant DATA_WIDTH : integer := 128;

    -- input/output signals to unit under test
    signal clk             : std_logic;                        -- system clock
    signal reset           : std_logic;                        -- system reset
    signal read            : std_logic;                        -- indicates read transaction
    signal write           : std_logic;                        -- indicates write transaction
    signal address         : std_logic_vector(31 downto 0);    -- address of transaction
    signal readdatavalid   : std_logic;                        -- indicates the readdata signal contains valid data
    signal readdata        : std_logic_vector(DATA_WIDTH-1 downto 0);          -- read data return
    signal writedata       : std_logic_vector(DATA_WIDTH-1 downto 0);          -- write data for a transaction
    signal writeresponsevalid   : std_logic;                                   -- indicates the write transaction is complete
    signal byteenable      : std_logic_vector(DATA_WIDTH/32 - 1 downto 0);     -- byte enables for each write lane
    signal waitrequest     : std_logic;                                        -- indicates need for additional cycles

begin

    -- Instantiate UUT
    UUT : entity work.sdram_agent
    generic map (
        DATA_WIDTH => DATA_WIDTH,
        MEM_SIZE => 256
    )
    port map (
        clk => clk,
        reset => reset,
        read => read,
        write => write,
        address => address,
        readdatavalid => readdatavalid,
        readdata => readdata,
        writedata => writedata,
        writeresponsevalid => writeresponsevalid,
        byteenable => byteenable,
        waitrequest => waitrequest
    );

    process
        procedure tick is
        begin
            clk <= '0';
            wait for 10 ns;
            clk <= '1';
            wait for 10 ns;
        end procedure tick;

        procedure write_data(addr: unsigned; to_write : std_logic_vector) is
        begin
            read <= '0';
            write <= '1';
            address <= std_logic_vector(addr);
            byteenable <= (others => '1');
            writedata <= to_write;

            tick;
            while waitrequest = '1' loop
                tick;
            end loop;
            assert writeresponsevalid = '1'
                report "Write response not valid"
                severity error;
            write <= '0';
            tick;
        end procedure;

        procedure read_data(addr: unsigned) is
        begin
            write <= '0';
            read <= '1';
            address <= std_logic_vector(addr);
            byteenable <= (others => '1');

            tick;
            while waitrequest = '1' loop
                tick;
            end loop;
            assert readdatavalid = '1'
                report "Read data not valid"
                severity error;
            read <= '0';
            tick;
        end procedure;
    begin
        -- Reset system
        reset <= '1';
        tick;

        -- set default behavior (no read, no write)
        reset <= '0';
        read <= '0';
        write <= '0';
        tick;

        write_data(to_unsigned(0, 32), X"AAAABBBBCCCCDDDDEEEEFFFF00000000");
        write_data(to_unsigned(1, 32), X"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        write_data(to_unsigned(2, 32), X"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBCC");
        write_data(to_unsigned(3, 32), X"1111111111111111111111111111AAAA");

        read_data(to_unsigned(0, 32));
        report "Read data: " & to_hstring(readdata);
        read_data(to_unsigned(1, 32));
        report "Read data: " & to_hstring(readdata);
        read_data(to_unsigned(2, 32));
        report "Read data: " & to_hstring(readdata);
        read_data(to_unsigned(3, 32));
        report "Read data: " & to_hstring(readdata);
        read_data(to_unsigned(4, 32));
        report "Read data: " & to_hstring(readdata);

        wait;
    end process;
end behavioral;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity sdram_host_tb is
end sdram_host_tb;

architecture behavioral of sdram_host_tb is
    constant DATA_WIDTH : integer := 128;

    -- Avalon MM interface between host and agent
    signal clk             : std_logic;                        -- system clock
    signal reset           : std_logic;                        -- system reset
    signal read            : std_logic;                        -- indicates read transaction
    signal write           : std_logic;                        -- indicates write transaction
    signal address         : std_logic_vector(31 downto 0);    -- address of transaction
    signal readdatavalid   : std_logic;                        -- indicates the readdata signal contains valid data
    signal readdata        : std_logic_vector(DATA_WIDTH-1 downto 0);          -- read data return
    signal writedata       : std_logic_vector(DATA_WIDTH-1 downto 0);          -- write data for a transaction
    signal writeresponsevalid   : std_logic;                                   -- indicates the write transaction is complete
    signal byteenable      : std_logic_vector(DATA_WIDTH/32 - 1 downto 0);     -- byte enables for each write lane
    signal waitrequest     : std_logic;                                        -- indicates need for additional cycles

    -- Control signals for sdram host
    signal do_read         : std_logic;
    signal do_write        : std_logic;
    signal in_address      : std_logic_vector(31 downto 0);
    signal in_data         : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal out_data        : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal write_complete  : std_logic;
    signal read_complete   : std_logic;

begin

    -- Instantiate UUT
    UUT : entity work.sdram_host
    generic map (
        DATA_WIDTH => DATA_WIDTH
    )
    port map (
        -- Avalon MM interface
        clk => clk,
        reset => reset,
        read => read,
        write => write,
        address => address,
        readdatavalid => readdatavalid,
        readdata => readdata,
        writedata => writedata,
        writeresponsevalid => writeresponsevalid,
        byteenable => byteenable,
        waitrequest => waitrequest,
        -- Control signals
        do_read => do_read,
        do_write => do_write,
        in_address => in_address,
        in_data => in_data,
        out_data => out_data,
        write_complete => write_complete,
        read_complete => read_complete
    );

    -- Supporting entity
    agent : entity work.sdram_agent
    generic map (
        DATA_WIDTH => DATA_WIDTH,
        MEM_SIZE => 256
    )
    port map (
        clk => clk,
        reset => reset,
        read => read,
        write => write,
        address => address,
        readdatavalid => readdatavalid,
        readdata => readdata,
        writedata => writedata,
        writeresponsevalid => writeresponsevalid,
        byteenable => byteenable,
        waitrequest => waitrequest
    );

    process
        procedure tick is
        begin
            clk <= '0';
            wait for 10 ns;
            clk <= '1';
            wait for 10 ns;
        end procedure tick;

        procedure write_data(addr: unsigned; to_write : std_logic_vector) is
        begin
            do_read <= '0';
            do_write <= '1';
            in_address <= std_logic_vector(addr);
            in_data <= to_write;
            tick;

            while write_complete = '0' loop
                tick;
            end loop;
            do_write <= '0';
            tick;
        end procedure;

        procedure read_data(addr: unsigned) is
        begin
            do_read <= '1';
            do_write <= '0';
            in_address <= std_logic_vector(addr);
            tick;

            while read_complete = '0' loop
                tick;
            end loop;
            do_read <= '0';
            tick;
        end procedure;

    begin
        -- Reset system
        reset <= '1';
        tick;

        -- Set default signals
        reset <= '0';
        do_read <= '0';
        do_write <= '0';
        tick;

        write_data(to_unsigned(0, 32), X"AAAABBBBCCCCDDDDEEEEFFFF00000000");
        write_data(to_unsigned(1, 32), X"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
        write_data(to_unsigned(2, 32), X"10101010101010101010101010101010");

        read_data(to_unsigned(0, 32));
        report "Read data: " & to_hstring(out_data);
        read_data(to_unsigned(1, 32));
        report "Read data: " & to_hstring(out_data);
        read_data(to_unsigned(2, 32));
        report "Read data: " & to_hstring(out_data);
        read_data(to_unsigned(3, 32));
        report "Read data: " & to_hstring(out_data);

        wait;
    end process;
end behavioral;

