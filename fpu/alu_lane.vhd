library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity alu_lane is
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        
        -- Control
        opcode       : in  std_logic_vector(5 downto 0);
        valid_in     : in  std_logic;
        
        -- Data Inputs (Scalars)
        op_a         : in  word_t;
        op_b         : in  word_t;
        
        -- Synchronized Outputs (Arrives exactly FPU_MAX_LATENCY cycles later)
        result       : out word_t;
        valid_out    : out std_logic
    );
end entity;

architecture rtl of alu_lane is

    -- 37-Cycle Delay Pipeline to match the FPU floating-point cores
    type res_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal res_pipe   : res_pipe_t := (others => (others => '0'));
    signal valid_pipe : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');
    
    -- Combinational evaluation wire
    signal raw_res    : word_t;

begin

    -- ========================================================================
    -- ZERO-LATENCY INTEGER COMBINATIONAL LOGIC
    -- ========================================================================
    process(opcode, op_a, op_b)
        variable a_uns : unsigned(31 downto 0);
        variable b_uns : unsigned(31 downto 0);
        variable shamt : integer range 0 to 31;
    begin
        a_uns := unsigned(op_a);
        b_uns := unsigned(op_b);
        -- Extract the bottom 5 bits of operand B for shift amounts (0 to 31)
        shamt := to_integer(b_uns(4 downto 0));
        
        case opcode is
            when OP_IADD => raw_res <= std_logic_vector(a_uns + b_uns);
            when OP_ISUB => raw_res <= std_logic_vector(a_uns - b_uns);
            when OP_IAND => raw_res <= op_a and op_b;
            when OP_IOR  => raw_res <= op_a or op_b;
            when OP_IXOR => raw_res <= op_a xor op_b;
            when OP_ISHL => raw_res <= std_logic_vector(shift_left(a_uns, shamt));
            when OP_ISHR => raw_res <= std_logic_vector(shift_right(a_uns, shamt));
            when others  => raw_res <= (others => '0');
        end case;
    end process;

    -- ========================================================================
    -- SEQUENTIAL PIPELINE SHIFT
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_pipe <= (others => '0');
            else
                -- Inject combinational result into stage 1
                valid_pipe(1) <= valid_in;
                res_pipe(1)   <= raw_res;
                
                -- Shift pipeline down to match FPU latency
                for i in 2 to FPU_MAX_LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                    res_pipe(i)   <= res_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    result    <= res_pipe(FPU_MAX_LATENCY);
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
