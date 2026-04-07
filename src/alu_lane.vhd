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
        is_load      : in  std_logic;
        imm_data     : in  std_logic_vector(15 downto 0); -- For LDI_LO / LDI_HI
        
        -- Data Inputs (Scalars)
        op_a         : in  word_t;
        op_b         : in  word_t;

        -- Thread ID computation inputs
        thread_id    : in  std_logic_vector(4 downto 0); -- Current thread index (0-31)
        warp_offset  : in  std_logic_vector(31 downto 0); -- Warp base offset from CSR
        
        -- Synchronized Outputs (Arrives exactly FPU_MAX_LATENCY cycles later)
        result       : out word_t;
        comp_flag    : out std_logic; -- Routes to Predicate Register File
        valid_out    : out std_logic
    );
end entity;

architecture rtl of alu_lane is

    -- 37-Cycle Delay Pipeline to match the FPU floating-point cores
    type res_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal res_pipe   : res_pipe_t := (others => (others => '0'));
    signal comp_pipe  : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');
    signal valid_pipe : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');
    
    -- Combinational evaluation wires
    signal raw_res    : word_t;
    signal raw_comp   : std_logic;

begin

    -- ========================================================================
    -- ZERO-LATENCY INTEGER COMBINATIONAL LOGIC
    -- ========================================================================
    process(opcode, op_a, op_b, imm_data, thread_id, warp_offset)
        variable a_uns : unsigned(31 downto 0);
        variable b_uns : unsigned(31 downto 0);
        variable a_sgn : signed(31 downto 0);
        variable b_sgn : signed(31 downto 0);
        variable shamt : integer range 0 to 31;
        variable prod  : unsigned(63 downto 0);
    begin
        a_uns := unsigned(op_a);
        b_uns := unsigned(op_b);
        a_sgn := signed(op_a);
        b_sgn := signed(op_b);
        
        -- Extract the bottom 5 bits of operand B for shift amounts (0 to 31)
        shamt := to_integer(b_uns(4 downto 0));
        prod  := a_uns * b_uns;
        
        -- Default defaults
        raw_res  <= op_a; 
        raw_comp <= '0';
        
        if is_load = '1' then
            case opcode is
                when OP_LDI_LO => raw_res <= x"0000" & imm_data;
                when OP_LDI_HI => raw_res <= imm_data & op_a(15 downto 0);
                when others => null;
            end case;
            
        else
            case opcode is
                when OP_IADD => raw_res <= std_logic_vector(a_uns + b_uns);
                when OP_ISUB => raw_res <= std_logic_vector(a_uns - b_uns);
                when OP_IMUL => raw_res <= std_logic_vector(prod(31 downto 0));
                when OP_IINC => raw_res <= std_logic_vector(a_uns + 1);
                when OP_IDEC => raw_res <= std_logic_vector(a_uns - 1);
                
                when OP_IAND => raw_res <= op_a and op_b;
                when OP_IOR  => raw_res <= op_a or op_b;
                when OP_IXOR => raw_res <= op_a xor op_b;
                when OP_ISHL => raw_res <= std_logic_vector(shift_left(a_uns, shamt));
                when OP_ISHR => raw_res <= std_logic_vector(shift_right(a_uns, shamt));
                when OP_ISAR => raw_res <= std_logic_vector(shift_right(a_sgn, shamt));
                
                when OP_ICMP_EQ  => if a_uns = b_uns then raw_comp <= '1'; end if;
                when OP_ICMP_SLT => if a_sgn < b_sgn then raw_comp <= '1'; end if;
                when OP_ICMP_ULT => if a_uns < b_uns then raw_comp <= '1'; end if;

                -- Compute absolute thread ID: warp_offset + lane index (0-31)
                when OP_THREAD_ID =>
                    raw_res <= std_logic_vector(
                        unsigned(warp_offset) + resize(unsigned(thread_id), 32)
                    );

                when others => null;
            end case;
        end if;
    end process;

    -- ========================================================================
    -- SEQUENTIAL PIPELINE SHIFT
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_pipe <= (others => '0');
                comp_pipe  <= (others => '0');
            else
                -- Inject combinational result into stage 1
                valid_pipe(1) <= valid_in;
                res_pipe(1)   <= raw_res;
                comp_pipe(1)  <= raw_comp;
                
                -- Shift pipeline down to match FPU latency
                for i in 2 to FPU_MAX_LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                    res_pipe(i)   <= res_pipe(i-1);
                    comp_pipe(i)  <= comp_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    result    <= res_pipe(FPU_MAX_LATENCY);
    comp_flag <= comp_pipe(FPU_MAX_LATENCY);
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
