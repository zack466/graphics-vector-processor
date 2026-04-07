library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity tb_alu_lane is
end entity tb_alu_lane;

architecture sim of tb_alu_lane is

    constant CLK_PERIOD : time := 10 ns;

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    
    signal opcode    : std_logic_vector(5 downto 0) := OP_NOP;
    signal valid_in  : std_logic := '0';
    signal is_load   : std_logic := '0'; -- NEW
    signal imm_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal op_a        : word_t := (others => '0');
    signal op_b        : word_t := (others => '0');
    signal thread_id   : std_logic_vector(4 downto 0) := (others => '0');
    signal warp_offset : std_logic_vector(31 downto 0) := (others => '0');

    signal result    : word_t;
    signal comp_flag : std_logic;
    signal valid_out : std_logic;

begin

    uut: entity work.alu_lane
        port map (
            clk         => clk,
            reset       => reset,
            opcode      => opcode,
            valid_in    => valid_in,
            is_load     => is_load,
            imm_data    => imm_data,
            op_a        => op_a,
            op_b        => op_b,
            thread_id   => thread_id,
            warp_offset => warp_offset,
            result      => result,
            comp_flag   => comp_flag,
            valid_out   => valid_out
        );

    clk_process : process
    begin
        clk <= '0'; wait for CLK_PERIOD / 2;
        clk <= '1'; wait for CLK_PERIOD / 2;
    end process;

    stim_proc: process
        -- Helper procedure to issue an instruction into the pipeline
        procedure issue_inst(
            op_code     : std_logic_vector(5 downto 0);
            a_val       : word_t;
            b_val       : word_t;
            imm_val     : std_logic_vector(15 downto 0) := x"0000";
            is_load_val : std_logic := '0' -- NEW
        ) is
        begin
            opcode   <= op_code;
            op_a     <= a_val;
            op_b     <= b_val;
            imm_data <= imm_val;
            is_load  <= is_load_val; -- NEW
            valid_in <= '1';
            wait until rising_edge(clk);
            valid_in <= '0';
        end procedure;

    begin
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- ====================================================================
        -- TEST SEQUENCE 1: Arithmetic & Shifts
        -- ====================================================================
        report ">> Issuing ALU Arithmetic and Shifts...";
        
        -- 1. Addition: 100 + 50 = 150 (x"96")
        issue_inst(OP_IADD, std_logic_vector(to_unsigned(100, 32)), std_logic_vector(to_unsigned(50, 32)));
        
        -- 2. Multiplication: 5000 * 30 = 150000 (x"249F0")
        issue_inst(OP_IMUL, std_logic_vector(to_unsigned(5000, 32)), std_logic_vector(to_unsigned(30, 32)));
        
        -- 3. Decrement: 42 - 1 = 41 (x"29")
        issue_inst(OP_IDEC, std_logic_vector(to_unsigned(42, 32)), x"00000000");

        -- 4. Arithmetic Shift Right: -100 >> 2 = -25
        issue_inst(OP_ISAR, std_logic_vector(to_signed(-100, 32)), std_logic_vector(to_unsigned(2, 32)));

        -- Wait for the first instruction to exit the 37-cycle pipeline
        for i in 1 to FPU_MAX_LATENCY - 4 loop 
            wait until rising_edge(clk); 
        end loop;

        -- Check Results (Reading them out on consecutive clocks)
        wait until falling_edge(clk);
        assert to_integer(unsigned(result)) = 150 report "OP_IADD Failed!" severity error;
        
        wait until falling_edge(clk);
        assert to_integer(unsigned(result)) = 150000 report "OP_IMUL Failed!" severity error;
        
        wait until falling_edge(clk);
        assert to_integer(unsigned(result)) = 41 report "OP_IDEC Failed!" severity error;
        
        wait until falling_edge(clk);
        assert to_integer(signed(result)) = -25 report "OP_ISAR Failed! (Sign extension bug?)" severity error;
        wait until rising_edge(clk);

        -- ====================================================================
        -- TEST SEQUENCE 2: Immediates and Comparisons
        -- ====================================================================
        report ">> Issuing Immediates and Comparisons...";
        
        -- 1. LDI_LO: Load x"BEEF" (Flagged with is_load_val = '1')
        issue_inst(OP_LDI_LO, x"00000000", x"00000000", x"BEEF", '1');
        
        -- 2. LDI_HI: Load x"DEAD" into upper half, keeping x"BEEF" in lower (Flagged with '1')
        issue_inst(OP_LDI_HI, x"0000BEEF", x"00000000", x"DEAD", '1');
        
        -- 3. ICMP_SLT: Signed -5 < 2 (Should be TRUE)
        issue_inst(OP_ICMP_SLT, std_logic_vector(to_signed(-5, 32)), std_logic_vector(to_signed(2, 32)));
        
        -- 4. ICMP_ULT: Unsigned -5 < 2 (Unsigned -5 is massive. Should be FALSE)
        issue_inst(OP_ICMP_ULT, std_logic_vector(to_signed(-5, 32)), std_logic_vector(to_signed(2, 32)));
        
        -- 5. ICMP_EQ: 1234 == 1234 (Should be TRUE)
        issue_inst(OP_ICMP_EQ, std_logic_vector(to_unsigned(1234, 32)), std_logic_vector(to_unsigned(1234, 32)));

        for i in 1 to FPU_MAX_LATENCY - 5 loop 
            wait until rising_edge(clk); 
        end loop;

        wait until falling_edge(clk);
        assert result = x"0000BEEF" report "OP_LDI_LO Failed!" severity error;
        
        wait until falling_edge(clk);
        assert result = x"DEADBEEF" report "OP_LDI_HI Failed!" severity error;
        
        wait until falling_edge(clk);
        assert comp_flag = '1' report "OP_ICMP_SLT Failed! (-5 < 2 is True)" severity error;
        
        wait until falling_edge(clk);
        assert comp_flag = '0' report "OP_ICMP_ULT Failed! (-5 as Unsigned is > 2)" severity error;
        
        wait until falling_edge(clk);
        assert comp_flag = '1' report "OP_ICMP_EQ Failed!" severity error;

        report ">> SIMULATION COMPLETE: All ALU instructions passed synchronously!";
        std.env.stop;
    end process;

end architecture sim;
