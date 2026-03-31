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
    constant INST_TYPE_ALU  : std_logic_vector(3 downto 0) := "0011";
    constant INST_TYPE_IMM  : std_logic_vector(3 downto 0) := "0100";

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
    
    -- Predicate Logic Opcodes
    constant OP_PAND    : std_logic_vector(5 downto 0) := "011000"; 
    constant OP_POR     : std_logic_vector(5 downto 0) := "011001"; 
    constant OP_PXOR    : std_logic_vector(5 downto 0) := "011010"; 

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
    constant WB_MUX_ALU : std_logic_vector(1 downto 0) := "10";

    -- ========================================================================
    -- REDUCTION UNIT MODES (Used when Type == 0010)
    -- ========================================================================
    constant RED_MODE_DOT     : std_logic_vector(1 downto 0) := "00"; -- Standard Dot Product (a * b)
    constant RED_MODE_SQ_MAG  : std_logic_vector(1 downto 0) := "01"; -- Squared Magnitude (a * a)
    constant RED_MODE_SUM     : std_logic_vector(1 downto 0) := "10"; -- Component Sum (a * 1.0)
    constant RED_MODE_ABS_SUM : std_logic_vector(1 downto 0) := "11"; -- Absolute Sum (|a| * 1.0)

    -- ========================================================================
    -- CONDENSED BRANCH TYPES & PREDICATE MODIFIERS
    -- ========================================================================
    constant BR_NONE    : std_logic_vector(2 downto 0) := "000";
    constant BR_JMP     : std_logic_vector(2 downto 0) := "001";
    constant BR_BRA_Z   : std_logic_vector(2 downto 0) := "010";
    constant BR_BRA_NZ  : std_logic_vector(2 downto 0) := "011";
    constant BR_BRA_DIV : std_logic_vector(2 downto 0) := "100";
    constant BR_SSY     : std_logic_vector(2 downto 0) := "101";
    constant BR_SYNC    : std_logic_vector(2 downto 0) := "110";

    constant PRED_MOD_ANY : std_logic_vector(1 downto 0) := "00"; -- True if X|Y|Z|A == 1
    constant PRED_MOD_ALL : std_logic_vector(1 downto 0) := "01"; -- True if X&Y&Z&A == 1
    constant PRED_MOD_X   : std_logic_vector(1 downto 0) := "10"; -- True if X == 1
    constant PRED_MOD_A   : std_logic_vector(1 downto 0) := "11"; -- True if A == 1

    -- ========================================================================
    -- INTEGER ALU OPCODES [31:26] (When Type == 0011)
    -- ========================================================================
    constant OP_IADD    : std_logic_vector(5 downto 0) := "000000";
    constant OP_ISUB    : std_logic_vector(5 downto 0) := "000001";
    constant OP_IAND    : std_logic_vector(5 downto 0) := "000010";
    constant OP_IOR     : std_logic_vector(5 downto 0) := "000011";
    constant OP_IXOR    : std_logic_vector(5 downto 0) := "000100";
    constant OP_ISHL    : std_logic_vector(5 downto 0) := "000101"; 
    constant OP_ISHR    : std_logic_vector(5 downto 0) := "000110"; 
    constant OP_IMUL    : std_logic_vector(5 downto 0) := "000111"; -- NEW
    constant OP_IINC    : std_logic_vector(5 downto 0) := "001000"; -- NEW
    constant OP_IDEC    : std_logic_vector(5 downto 0) := "001001"; -- NEW
    constant OP_ISAR    : std_logic_vector(5 downto 0) := "001010"; -- NEW: Shift Arith Right
    constant OP_ICMP_EQ : std_logic_vector(5 downto 0) := "001011"; -- NEW
    constant OP_ICMP_SLT: std_logic_vector(5 downto 0) := "001100"; -- NEW: Signed Less Than
    constant OP_ICMP_ULT: std_logic_vector(5 downto 0) := "001101"; -- NEW: Unsigned Less Than

    -- ========================================================================
    -- IMMEDIATE OPCODES [31:26] (When Type == 0100)
    -- ========================================================================
    constant OP_LDI_LO  : std_logic_vector(5 downto 0) := "000000"; -- NEW
    constant OP_LDI_HI  : std_logic_vector(5 downto 0) := "000001"; -- NEW

    -- ========================================================================
    -- CONTROL RECORDS (Expanded explicitly to remove downstream decoding)
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
        cmp_invert      : std_logic; 
        cmp_swap        : std_logic; 
        is_logic_op     : std_logic;
        vrf_we          : std_logic; 
        prf_we          : std_logic; 
        wb_mux_sel      : std_logic_vector(1 downto 0);
    end record;

    type red_ctrl_t is record
        rs1_addr_local  : std_logic_vector(1 downto 0);
        rs2_addr_local  : std_logic_vector(1 downto 0);
        rd_addr_local   : std_logic_vector(1 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        red_mask        : std_logic_vector(3 downto 0); 
        red_mode        : std_logic_vector(1 downto 0); 
        wb_mux_sel      : std_logic_vector(1 downto 0); 
        vrf_we          : std_logic; 
    end record;

    type pc_ctrl_t is record
        branch_type     : std_logic_vector(2 downto 0);  
        target_addr     : std_logic_vector(15 downto 0); 
        predicate_sel   : std_logic_vector(1 downto 0);  
        predicate_mod   : std_logic_vector(1 downto 0);  
    end record;

    type alu_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(1 downto 0);
        rs2_addr_local  : std_logic_vector(1 downto 0);
        rd_addr_local   : std_logic_vector(1 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        write_mask      : std_logic_vector(3 downto 0);
        wb_mux_sel      : std_logic_vector(1 downto 0);
        vrf_we          : std_logic;
        prf_we          : std_logic;                     -- NEW: For ALU Compares
        is_load         : std_logic;                     -- NEW: Differentiates LDI from standard math
        imm_data        : std_logic_vector(15 downto 0); -- NEW: For Immediate Loads
    end record;

    -- ========================================================================
    -- UNIFIED EXECUTION PIPELINE RECORD
    -- Muxed from specific ctrl records before entering the Issue Stage
    -- ========================================================================
    type exec_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(1 downto 0);
        rs2_addr_local  : std_logic_vector(1 downto 0);
        rs3_addr_local  : std_logic_vector(1 downto 0); 
        rd_addr_local   : std_logic_vector(1 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        swiz_sel_c      : swizzle_sel_t;                
        write_mask      : std_logic_vector(3 downto 0);
        cmp_invert      : std_logic;                    
        cmp_swap        : std_logic;                    
        is_logic_op     : std_logic;                    
        vrf_we          : std_logic;
        prf_we          : std_logic;                    
        wb_mux_sel      : std_logic_vector(1 downto 0);
        is_load         : std_logic;                    
        imm_data        : std_logic_vector(15 downto 0); -- NEW
    end record;

    -- ========================================================================
    -- HARDWARE LATENCY CONSTANTS (TODO: update for real Altera IP)
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
    constant LAT_I2F        : integer := 6; 
    constant LAT_F2I        : integer := 6; 
    constant LAT_REDUCT     : integer := 37;    -- 4d scalar product

    constant FPU_MAX_LATENCY : integer := 37;

end package;
