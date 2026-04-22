-- ============================================================================
-- FILE: processor_constants_pkg.vhd
-- PACKAGE: processor_constants_pkg
-- ============================================================================
--
--   Central repository for every magic number, encoding constant, and
--   pre-decoded control record type used by the SIMT vector processor.
--   Concentrating these definitions here achieves two goals:
--     1. Single point of change: adjusting an opcode encoding, pipeline depth,
--        or record field affects every entity that uses this package without
--        requiring edits scattered across multiple files.
--     2. Type safety: passing decoded control fields as typed records rather
--        than raw std_logic_vector slices eliminates bit-index errors when
--        connecting units.  The compiler catches mismatched field assignments
--        at elaboration time rather than at runtime.
--
-- INSTRUCTION WORD LAYOUT (32 bits):
--   [31:26]  opcode     (6 bits)  — operation selector
--   [25:xx]  operands             — layout varies by INST_TYPE (see decoder)
--   [3:0]    inst_type  (4 bits)  — dispatch key used by FSM and decoder
--
-- KEY GROUPINGS:
--   INST_TYPE_*   Bottom 4 bits of every instruction; used by the FSM to
--                 dispatch to the right datapath and by the decoder to choose
--                 which record fields to populate.
--
--   SWIZ_*        3-bit swizzle mode codes fed to the swizzle network before
--                 each functional unit.  SWIZ_PASS is the identity; SWIZ_X/Y/Z/W
--                 broadcast a single component to all four lanes.
--
--   OP_*          6-bit opcode values in bits[31:26].  Note that FPU and ALU
--                 instruction classes overlap in some numeric values
--                 (e.g. OP_IADD = OP_NOP = "000000") — the INST_TYPE field
--                 disambiguates which unit should execute the instruction.
--
--   BR_*          Condensed 3-bit branch type codes stored in pc_ctrl_t.
--                 The decoder translates the 6-bit OP_JMP / OP_BRA_* / OP_SSY
--                 opcodes into these compact codes so the IFU only needs a
--                 single small case statement instead of comparing against the
--                 full 6-bit opcode space.
--
--   PRED_MOD_*    Controls how the PRF collapses a 4-bit per-thread predicate
--                 register to a 1-bit branch-taken signal for conditional
--                 branches.  ANY = taken if any component is 1; ALL = taken if
--                 all components are 1; X/A = taken based on a single component.
--
--   WB_MUX_*      Selects which execution pipeline's result is routed to the
--                 VRF writeback port.  Values correspond to FPU, RED, ALU.
--
--   RED_MODE_*    Selects the reduction operation performed by the reduction
--                 unit before accumulation.  The four modes cover the most
--                 common SIMT reduction patterns (dot product, squared
--                 magnitude, component sum, absolute sum).
--
--   LAT_*         Exact integer pipeline depths of each Altera/Intel IP core
--                 (in clock cycles from input-valid to output-valid).  These
--                 MUST match the IP core configuration used at synthesis.
--                 Mismatches cause writeback to land in the wrong register.
--
--   FPU_MAX_LATENCY = LAT_FRSQRT  The normalizing constant.  All execution units
--                 (FPU, ALU, RED) are padded with shift-register delay lines
--                 to exactly this many cycles, ensuring all 32 thread results
--                 for a single instruction arrive at the VRF write port in a
--                 neat 32-cycle burst rather than staggered by unit latency.
--                 This uniform commit window simplifies the writeback mux.
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use work.vector_types_pkg.all;

package processor_constants_pkg is

    -- ========================================================================
    -- ARCHITECTURAL PARAMETERS
    -- ========================================================================
    constant WARP_SIZE       : integer := 32; -- Threads per warp (barrel scheduler replay count)
    constant THREAD_ID_WIDTH : integer := 5;  -- Bits to address WARP_SIZE threads (log2(32)=5)
    constant LOCAL_REG_WIDTH : integer := 4;  -- Bits to address 16 VRF/PRF registers per thread
    constant VRF_ADDR_WIDTH  : integer := THREAD_ID_WIDTH + LOCAL_REG_WIDTH; -- 9-bit flat VRF/PRF address = {thread_id, reg_idx}

    -- ========================================================================
    -- INSTRUCTION TYPES (Bottom 4 bits [3:0])
    -- ========================================================================
    constant INST_TYPE_FPU  : std_logic_vector(3 downto 0) := "0000"; -- Floating-point parallel operations
    constant INST_TYPE_CTRL : std_logic_vector(3 downto 0) := "0001"; -- Branch / control flow instructions
    constant INST_TYPE_RED  : std_logic_vector(3 downto 0) := "0010"; -- Floating-point reduction operations
    constant INST_TYPE_ALU  : std_logic_vector(3 downto 0) := "0011"; -- Integer ALU operations
    constant INST_TYPE_IMM  : std_logic_vector(3 downto 0) := "0100"; -- Immediate load instructions
    constant INST_TYPE_MEM  : std_logic_vector(3 downto 0) := "0101"; -- Scatter/gather load/store
    constant INST_TYPE_SYS  : std_logic_vector(3 downto 0) := "0110"; -- System & environment instructions

    -- ========================================================================
    -- SWIZZLE MODES
    -- ========================================================================
    constant SWIZ_PASS      : std_logic_vector(2 downto 0) := "000"; -- Passthrough (.xyzw) — identity
    constant SWIZ_X         : std_logic_vector(2 downto 0) := "100"; -- Splat X (.xxxx) — broadcast component 0
    constant SWIZ_Y         : std_logic_vector(2 downto 0) := "101"; -- Splat Y (.yyyy) — broadcast component 1
    constant SWIZ_Z         : std_logic_vector(2 downto 0) := "110"; -- Splat Z (.zzzz) — broadcast component 2
    constant SWIZ_W         : std_logic_vector(2 downto 0) := "111"; -- Splat W/A (.wwww/.aaaa) — broadcast component 3


    -- ========================================================================
    -- FPU MATH OPCODES [31:26] (When Type == 0000)
    -- ========================================================================
    constant OP_NOP     : std_logic_vector(5 downto 0) := "000000"; -- No operation (safe default for uninitialized IMEM)
    constant OP_FADD    : std_logic_vector(5 downto 0) := "000001"; -- IEEE 754 single-precision add
    constant OP_FSUB    : std_logic_vector(5 downto 0) := "000010"; -- IEEE 754 single-precision subtract
    constant OP_FMUL    : std_logic_vector(5 downto 0) := "000011"; -- IEEE 754 single-precision multiply
    constant OP_FMADD   : std_logic_vector(5 downto 0) := "000100"; -- Fused multiply-add: rs1*rs2+rs3
    constant OP_FDIV    : std_logic_vector(5 downto 0) := "000101"; -- Division: rs1 / rs2
    constant OP_FSQRT   : std_logic_vector(5 downto 0) := "000110"; -- Square root
    constant OP_FLOG2   : std_logic_vector(5 downto 0) := "000111"; -- Base-2 logarithm
    constant OP_FEXP2   : std_logic_vector(5 downto 0) := "001000"; -- Base-2 exponent (2^rs1)
    constant OP_FMIN    : std_logic_vector(5 downto 0) := "001001"; -- Component-wise minimum
    constant OP_FMAX    : std_logic_vector(5 downto 0) := "001010"; -- Component-wise maximum
    constant OP_FCMP_LT : std_logic_vector(5 downto 0) := "001011"; -- Compare less-than → predicate register
    constant OP_FCMP_EQ : std_logic_vector(5 downto 0) := "001100"; -- Compare equal → predicate register
    constant OP_F2I     : std_logic_vector(5 downto 0) := "001101"; -- Float-to-integer conversion (truncate)
    constant OP_I2F     : std_logic_vector(5 downto 0) := "001110"; -- Integer-to-float conversion
    constant OP_SIN     : std_logic_vector(5 downto 0) := "010000"; -- Sine (radians)
    constant OP_COS     : std_logic_vector(5 downto 0) := "010001"; -- Cosine (radians)
    constant OP_MOV     : std_logic_vector(5 downto 0) := "010010"; -- Register move: rd = rs1 (with write mask)

    -- Predicate Logic Opcodes
    constant OP_PAND    : std_logic_vector(5 downto 0) := "011000"; -- Predicate AND: pd = ps1 & ps2 (component-wise)
    constant OP_POR     : std_logic_vector(5 downto 0) := "011001"; -- Predicate OR:  pd = ps1 | ps2
    constant OP_PXOR    : std_logic_vector(5 downto 0) := "011010"; -- Predicate XOR: pd = ps1 ^ ps2

    -- ========================================================================
    -- SYSTEM OPCODES [31:26] (When Type == 0110)
    -- ========================================================================
    constant OP_FLUSH   : std_logic_vector(5 downto 0) := "111110"; -- Pipeline memory barrier: drain all in-flight ops
    constant OP_RETURN  : std_logic_vector(5 downto 0) := "111111"; -- End of kernel: halt processor (csr_run <= 0)
    constant OP_BREAK   : std_logic_vector(5 downto 0) := "111100"; -- Debug breakpoint: halt + set break_hit flag
    constant OP_INT     : std_logic_vector(5 downto 0) := "111101"; -- Software interrupt: set irq_pending, continue execution

    -- ========================================================================
    -- CONTROL FLOW OPCODES [31:26] (When Type == 0001)
    -- ========================================================================
    constant OP_JMP     : std_logic_vector(5 downto 0) := "110000"; -- Unconditional jump to target_addr
    constant OP_BRA_Z   : std_logic_vector(5 downto 0) := "110001"; -- Branch if warp predicate evaluates to zero
    constant OP_BRA_NZ  : std_logic_vector(5 downto 0) := "110010"; -- Branch if warp predicate evaluates to non-zero
    constant OP_BRA_DIV : std_logic_vector(5 downto 0) := "110011"; -- Divergent branch: push true-path mask, execute false path
    constant OP_SSY     : std_logic_vector(5 downto 0) := "110100"; -- Set Sync: push meetup PC onto divergence stack
    constant OP_SYNC    : std_logic_vector(5 downto 0) := "110101"; -- Synchronize: pop divergence stack, merge thread masks
    constant OP_BRA_L   : std_logic_vector(5 downto 0) := "110110"; -- Branch with link: link_reg=PC+1, PC=target_addr
    constant OP_BRA_X   : std_logic_vector(5 downto 0) := "110111"; -- Branch to link: PC=link_reg (function return)
    constant OP_PUSH_L  : std_logic_vector(5 downto 0) := "111000"; -- Push link register onto call stack (for nested calls)
    constant OP_POP_L   : std_logic_vector(5 downto 0) := "111001"; -- Pop call stack into link register

    -- ========================================================================
    -- WRITEBACK MUX SELECTORS
    -- ========================================================================
    constant WB_MUX_FPU : std_logic_vector(1 downto 0) := "00"; -- Route FPU output to VRF
    constant WB_MUX_RED : std_logic_vector(1 downto 0) := "01"; -- Route reduction unit output to VRF
    constant WB_MUX_ALU : std_logic_vector(1 downto 0) := "10"; -- Route ALU output to VRF

    -- ========================================================================
    -- REDUCTION UNIT MODES (Used when Type == 0010)
    -- ========================================================================
    constant RED_MODE_DOT     : std_logic_vector(1 downto 0) := "00"; -- Dot product: sum(rs1[i] * rs2[i])
    constant RED_MODE_SQ_MAG  : std_logic_vector(1 downto 0) := "01"; -- Squared magnitude: sum(rs1[i] * rs1[i])
    constant RED_MODE_SUM     : std_logic_vector(1 downto 0) := "10"; -- Component sum: sum(rs1[i])
    constant RED_MODE_ABS_SUM : std_logic_vector(1 downto 0) := "11"; -- Absolute sum: sum(|rs1[i]|)

    -- ========================================================================
    -- CALL STACK DEPTH
    -- ========================================================================
    constant CALL_STACK_DEPTH : integer := 8;

    -- ========================================================================
    -- CONDENSED BRANCH TYPES & PREDICATE MODIFIERS
    -- ========================================================================
    constant BR_NONE    : std_logic_vector(3 downto 0) := "0000"; -- No branch; PC increments normally
    constant BR_JMP     : std_logic_vector(3 downto 0) := "0001"; -- Unconditional jump
    constant BR_BRA_Z   : std_logic_vector(3 downto 0) := "0010"; -- Branch if predicate is zero
    constant BR_BRA_NZ  : std_logic_vector(3 downto 0) := "0011"; -- Branch if predicate is non-zero
    constant BR_BRA_DIV : std_logic_vector(3 downto 0) := "0100"; -- Divergent branch (push true mask)
    constant BR_SSY     : std_logic_vector(3 downto 0) := "0101"; -- Set sync point (push meetup PC)
    constant BR_SYNC    : std_logic_vector(3 downto 0) := "0110"; -- Synchronize (pop divergence stack)
    constant BR_BRA_L   : std_logic_vector(3 downto 0) := "0111"; -- Branch with link: link_reg=PC+1, PC=target
    constant BR_BRA_X   : std_logic_vector(3 downto 0) := "1000"; -- Branch to link register: PC=link_reg
    constant BR_PUSH_L  : std_logic_vector(3 downto 0) := "1001"; -- Push link register onto call stack
    constant BR_POP_L   : std_logic_vector(3 downto 0) := "1010"; -- Pop call stack into link register

    -- Predicate modifiers
    constant PRED_MOD_ANY : std_logic_vector(1 downto 0) := "00"; -- Branch taken if any component of predicate == 1
    constant PRED_MOD_ALL : std_logic_vector(1 downto 0) := "01"; -- Branch taken if all components of predicate == 1
    constant PRED_MOD_X   : std_logic_vector(1 downto 0) := "10"; -- Branch taken if X (component 0) of predicate == 1
    constant PRED_MOD_A   : std_logic_vector(1 downto 0) := "11"; -- Branch taken if A/W (component 3) of predicate == 1

    -- ========================================================================
    -- INTEGER ALU OPCODES [31:26] (When Type == 0011)
    -- ========================================================================
    constant OP_IADD      : std_logic_vector(5 downto 0) := "000000"; -- Integer add: rd = rs1 + rs2
    constant OP_ISUB      : std_logic_vector(5 downto 0) := "000001"; -- Integer subtract: rd = rs1 - rs2
    constant OP_IAND      : std_logic_vector(5 downto 0) := "000010"; -- Bitwise AND
    constant OP_IOR       : std_logic_vector(5 downto 0) := "000011"; -- Bitwise OR
    constant OP_IXOR      : std_logic_vector(5 downto 0) := "000100"; -- Bitwise XOR
    constant OP_ISHL      : std_logic_vector(5 downto 0) := "000101"; -- Logical shift left
    constant OP_ISHR      : std_logic_vector(5 downto 0) := "000110"; -- Logical shift right (zero-fill)
    constant OP_IMUL      : std_logic_vector(5 downto 0) := "000111"; -- Integer multiply (lower 32 bits)
    constant OP_IINC      : std_logic_vector(5 downto 0) := "001000"; -- Increment: rd = rs1 + 1
    constant OP_IDEC      : std_logic_vector(5 downto 0) := "001001"; -- Decrement: rd = rs1 - 1
    constant OP_ISAR      : std_logic_vector(5 downto 0) := "001010"; -- Arithmetic shift right (sign-extend)
    constant OP_ICMP_EQ   : std_logic_vector(5 downto 0) := "001011"; -- Compare equal → predicate register
    constant OP_ICMP_SLT  : std_logic_vector(5 downto 0) := "001100"; -- Compare signed less-than → predicate
    constant OP_ICMP_ULT  : std_logic_vector(5 downto 0) := "001101"; -- Compare unsigned less-than → predicate

    constant OP_THREAD_ID : std_logic_vector(5 downto 0) := "001110"; -- rd = csr_warp_offset + thread_id (per-thread unique ID)
    constant OP_WIDTH     : std_logic_vector(5 downto 0) := "001111"; -- rd.x = frame_width
    constant OP_HEIGHT    : std_logic_vector(5 downto 0) := "010000"; -- rd.x = frame_height
    constant OP_TIME      : std_logic_vector(5 downto 0) := "010001"; -- rd.x = elapsed_time_ms

    -- ========================================================================
    -- IMMEDIATE OPCODES (When Type == INST_TYPE_IMM = "0100")
    -- ========================================================================
    constant OP_LDI_LO  : std_logic_vector(5 downto 0) := "000000"; -- LDI_LO: sub-op bits[5:4]="00"
    constant OP_LDI_HI  : std_logic_vector(5 downto 0) := "010000"; -- LDI_HI: sub-op bits[5:4]="01"

    -- ========================================================================
    -- CONTROL RECORDS (Expanded explicitly to remove downstream decoding)
    -- ========================================================================
    -- fpu_ctrl_t: decoded fields for INST_TYPE_FPU instructions.
    type fpu_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(3 downto 0);
        rs2_addr_local  : std_logic_vector(3 downto 0);
        rs3_addr_local  : std_logic_vector(3 downto 0); -- Used only by FMADD; '0000' for all other ops
        rd_addr_local   : std_logic_vector(3 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        swiz_sel_c      : swizzle_sel_t;                -- Third swizzle for FMADD rs3 operand
        write_mask      : std_logic_vector(3 downto 0); -- Component write-enable for VRF writeback
        cmp_invert      : std_logic;  -- Invert comparison result (implements >=, !=)
        cmp_swap        : std_logic;  -- Swap rs1/rs2 before comparison (implements >, <=)
        is_logic_op     : std_logic;  -- '1' for PAND/POR/PXOR; routes to predicate writeback
        vrf_we          : std_logic;  -- '1' when this op writes a VRF register
        prf_we          : std_logic;  -- '1' when this op writes a predicate register
        wb_mux_sel      : std_logic_vector(1 downto 0); -- Always WB_MUX_FPU for this class
    end record;

    -- red_ctrl_t: decoded fields for INST_TYPE_RED (reduction) instructions.
    type red_ctrl_t is record
        rs1_addr_local  : std_logic_vector(3 downto 0);
        rs2_addr_local  : std_logic_vector(3 downto 0);
        rd_addr_local   : std_logic_vector(3 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        red_mask        : std_logic_vector(3 downto 0); -- Component inclusion mask for the accumulator
        red_mode        : std_logic_vector(1 downto 0); -- RED_MODE_* constant selecting the reduction operation
        wb_mux_sel      : std_logic_vector(1 downto 0); -- Always WB_MUX_RED for this class
        vrf_we          : std_logic;  -- '1' when reduction result writes to VRF
    end record;

    -- pc_ctrl_t: decoded fields for INST_TYPE_CTRL instructions.
    type pc_ctrl_t is record
        branch_type     : std_logic_vector(3 downto 0);  -- BR_* constant (4-bit; supports 11 branch types)
        target_addr     : std_logic_vector(15 downto 0); -- Instruction-word-encoded branch target (PC-relative or absolute)
        predicate_sel   : std_logic_vector(3 downto 0);  -- Local predicate register index for conditional branches
        predicate_mod   : std_logic_vector(1 downto 0);  -- PRED_MOD_* collapse mode
    end record;

    -- alu_ctrl_t: decoded fields for INST_TYPE_ALU and INST_TYPE_IMM.
    type alu_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(3 downto 0);
        rs2_addr_local  : std_logic_vector(3 downto 0);
        rd_addr_local   : std_logic_vector(3 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        write_mask      : std_logic_vector(3 downto 0);
        wb_mux_sel      : std_logic_vector(1 downto 0); -- Always WB_MUX_ALU for this class
        vrf_we          : std_logic;
        prf_we          : std_logic;   -- '1' for ICMP_EQ, ICMP_SLT, ICMP_ULT
        is_load         : std_logic;   -- '1' for INST_TYPE_IMM: use imm_data as rs2
        imm_data        : std_logic_vector(15 downto 0); -- 16-bit literal for IMM instructions
    end record;

    -- ========================================================================
    -- UNIFIED EXECUTION PIPELINE RECORD
    -- ========================================================================
    -- exec_ctrl_t is a superset of both fpu_ctrl_t and alu_ctrl_t fields:
    -- The instruction_issue entity and execution_unit share a single record
    -- type for simplicity. The decoder-mux in the processor top level
    -- populates only the relevant fields for each instruction class; the
    -- unused fields default to safe values ('0' / all-zeros). This avoids
    -- the need for polymorphism or multiple port map variants on the issuer.
    type exec_ctrl_t is record
        opcode          : std_logic_vector(5 downto 0);
        rs1_addr_local  : std_logic_vector(3 downto 0);
        rs2_addr_local  : std_logic_vector(3 downto 0);
        rs3_addr_local  : std_logic_vector(3 downto 0); -- Third source for FMADD; '0000' otherwise
        rd_addr_local   : std_logic_vector(3 downto 0);
        swiz_sel_a      : swizzle_sel_t;
        swiz_sel_b      : swizzle_sel_t;
        swiz_sel_c      : swizzle_sel_t;                -- Third swizzle for FMADD; SWIZ_PASS otherwise
        write_mask      : std_logic_vector(3 downto 0); -- Component write-enable mask for VRF
        cmp_invert      : std_logic;                    -- FPU: invert compare result
        cmp_swap        : std_logic;                    -- FPU: swap operands before compare
        is_logic_op     : std_logic;                    -- FPU: route result to predicate file
        vrf_we          : std_logic;                    -- '1' when result writes to VRF
        prf_we          : std_logic;                    -- '1' when result writes to PRF
        wb_mux_sel      : std_logic_vector(1 downto 0); -- WB_MUX_* selector for writeback mux
        is_load         : std_logic;                    -- IMM: substitute imm_data for rs2 operand
        imm_data        : std_logic_vector(15 downto 0); -- 16-bit immediate (IMM instructions only)
    end record;

    -- ========================================================================
    -- HARDWARE LATENCY CONSTANTS
    -- ========================================================================
    -- CRITICAL: Each constant must exactly match the pipeline depth reported by
    -- the corresponding Altera/Intel Floating-Point IP core at synthesis.  If a
    -- core's latency changes after regeneration, the writeback will be delayed
    -- or early by the delta, corrupting the wrong register for up to WARP_SIZE
    -- consecutive threads.
    --
    -- LAT_* values are in clock cycles from the cycle input data is presented
    -- to the cycle the result appears at the IP core output. Targeting 100 MHz.
    constant LAT_FMADD      : integer := 9;  -- Fused multiply-add
    constant LAT_FDIV       : integer := 9;  -- Division
    constant LAT_FSQRT      : integer := 6;  -- Square root
    constant LAT_FMIN       : integer := 2;  -- Component-wise minimum
    constant LAT_FMAX       : integer := 2;  -- Component-wise maximum
    constant LAT_FSIN       : integer := 18; -- Sine
    constant LAT_FCOS       : integer := 18; -- Cosine
    constant LAT_FLOG2      : integer := 12; -- Base-2 log
    constant LAT_FEXP2      : integer := 5;  -- Base-2 exponent
    constant LAT_FCMP_LT    : integer := 3;  -- Less-than compare
    constant LAT_FCMP_EQ    : integer := 1;  -- Equality compare
    constant LAT_I2F        : integer := 4;  -- Integer to float conversion
    constant LAT_F2I        : integer := 2;  -- Float to integer conversion
    constant LAT_REDUCT     : integer := 16; -- 4D scalar product

    -- FPU_MAX_LATENCY: The normalizing pipeline depth (length of slowest
    -- operation). Every other unit has a shift-register delay appended to pad
    -- its output to this same latency.
    constant FPU_MAX_LATENCY : integer := LAT_FSIN; -- Tied to bottleneck op; update if IP changes

end package;
