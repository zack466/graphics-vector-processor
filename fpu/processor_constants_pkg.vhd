library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use work.vector_types_pkg.all;

package processor_constants_pkg is

    -- ========================================================================
    -- INSTRUCTION TYPES (Bottom 4 bits [3:0])
    -- ========================================================================
    constant INST_TYPE_FPU  : std_logic_vector(3 downto 0) := "0000";
    constant INST_TYPE_CTRL : std_logic_vector(3 downto 0) := "0001";
    constant INST_TYPE_RED  : std_logic_vector(3 downto 0) := "0010";

    -- ========================================================================
    -- FPU MATH OPCODES [31:26] (When Type == 0000)
    -- ========================================================================
    constant OP_NOP     : std_logic_vector(5 downto 0) := "000000"; 
    constant OP_FADD    : std_logic_vector(5 downto 0) := "000001"; 
    constant OP_FSUB    : std_logic_vector(5 downto 0) := "000010"; 
    constant OP_FMUL    : std_logic_vector(5 downto 0) := "000011"; 
    constant OP_FMADD   : std_logic_vector(5 downto 0) := "000100"; 
    constant OP_FRCP    : std_logic_vector(5 downto 0) := "000101"; 
    constant OP_FSQRT   : std_logic_vector(5 downto 0) := "000110"; 
    constant OP_FLOG2   : std_logic_vector(5 downto 0) := "000111"; 
    constant OP_FEXP2   : std_logic_vector(5 downto 0) := "001000"; 
    constant OP_FMIN    : std_logic_vector(5 downto 0) := "001001"; 
    constant OP_FMAX    : std_logic_vector(5 downto 0) := "001010"; 
    constant OP_FCMP_LT : std_logic_vector(5 downto 0) := "001011"; 
    constant OP_FCMP_EQ : std_logic_vector(5 downto 0) := "001100"; 
    constant OP_F2I     : std_logic_vector(5 downto 0) := "001101"; 
    constant OP_I2F     : std_logic_vector(5 downto 0) := "001110"; 
    constant OP_SIN     : std_logic_vector(5 downto 0) := "010000"; 
    constant OP_COS     : std_logic_vector(5 downto 0) := "010001"; 

    -- ========================================================================
    -- CONTROL FLOW OPCODES [31:26] (When Type == 0001)
    -- ========================================================================
    constant OP_JMP     : std_logic_vector(5 downto 0) := "110000"; -- Unconditional Jump
    constant OP_BRA_Z   : std_logic_vector(5 downto 0) := "110001"; -- Branch if Warp Zero
    constant OP_BRA_NZ  : std_logic_vector(5 downto 0) := "110010"; -- Branch if Warp Not Zero
    constant OP_BRA_DIV : std_logic_vector(5 downto 0) := "110011"; -- Branch Divergent (Push True path)
    constant OP_SSY     : std_logic_vector(5 downto 0) := "110100"; -- Set Sync (Push Meetup PC)
    constant OP_SYNC    : std_logic_vector(5 downto 0) := "110101"; -- Synchronize (Pop Stack)

    -- Writeback Mux Selectors
    constant WB_MUX_FPU : std_logic_vector(1 downto 0) := "00";
    constant WB_MUX_RED : std_logic_vector(1 downto 0) := "01";

    -- ========================================================================
    -- REDUCTION UNIT MODES (Used when Type == 0010)
    -- ========================================================================
    constant RED_MODE_DOT     : std_logic_vector(1 downto 0) := "00"; -- Standard Dot Product (a * b)
    constant RED_MODE_SQ_MAG  : std_logic_vector(1 downto 0) := "01"; -- Squared Magnitude (a * a)
    constant RED_MODE_SUM     : std_logic_vector(1 downto 0) := "10"; -- Component Sum (a * 1.0)
    constant RED_MODE_ABS_SUM : std_logic_vector(1 downto 0) := "11"; -- Absolute Sum (|a| * 1.0)

    -- ========================================================================
    -- CONTROL RECORDS
    -- ========================================================================
    type fpu_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(1 downto 0);
        rs2_addr_local  : std_logic_vector(1 downto 0);
        rs3_addr_local  : std_logic_vector(1 downto 0);
        rd_addr_local   : std_logic_vector(1 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        swiz_sel_c      : swizzle_sel_t;
        write_mask      : std_logic_vector(3 downto 0);
        wb_mux_sel      : std_logic_vector(1 downto 0);
        reg_we          : std_logic;
    end record;

    type red_ctrl_t is record
        rs1_addr_local  : std_logic_vector(1 downto 0);
        rs2_addr_local  : std_logic_vector(1 downto 0);
        rd_addr_local   : std_logic_vector(1 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        red_mask        : std_logic_vector(3 downto 0); -- Which input components to sum (e.g. DP3 vs DP4)
        red_mode        : std_logic_vector(1 downto 0); -- DOT, SQ_MAG, SUM, ABS_SUM
        wb_mux_sel      : std_logic_vector(1 downto 0); -- Routes writeback multiplexer
        reg_we          : std_logic;
    end record;

    type pc_ctrl_t is record
        is_jmp          : std_logic;
        is_bra_z        : std_logic;
        is_bra_nz       : std_logic;
        is_bra_div      : std_logic;
        is_ssy          : std_logic;
        is_sync         : std_logic;
        target_addr     : std_logic_vector(15 downto 10); -- 16-bit branch target
        predicate_sel   : std_logic_vector(1 downto 0);  -- Which P-reg to evaluate
    end record;

    -- ========================================================================
    -- HARDWARE LATENCY CONSTANTS (Derived from Altera IP / Simulation Models)
    -- ========================================================================
    constant LAT_FMADD      : integer := 22;
    constant LAT_FRCP       : integer := 14;
    constant LAT_FSQRT      : integer := 9;
    constant LAT_FRSQRT     : integer := 28;
    constant LAT_FMIN       : integer := 3;
    constant LAT_FMAX       : integer := 3;
    constant LAT_FSIN       : integer := 21;
    constant LAT_FCOS       : integer := 21;
    constant LAT_FLOG2      : integer := 21;
    constant LAT_FEXP2      : integer := 17;
    constant LAT_FCMP_LT    : integer := 3;
    constant LAT_FCMP_EQ    : integer := 3;
    constant LAT_I2F        : integer := 6; -- Fix to Float
    constant LAT_F2I        : integer := 6; -- Float to Fix
    constant LAT_REDUCT     : integer := 37; -- 4D Scalar Product

    -- The rigid pipeline depth for the entire execution backend 
    -- Bound by the 37-cycle Scalar Product block.
    constant FPU_MAX_LATENCY : integer := 37;

end package;
