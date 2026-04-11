-- ============================================================================
-- PACKAGE: processor_constants_pkg
-- ============================================================================
-- PURPOSE:
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
-- HOW TO USE THIS PACKAGE:
--   Add "use work.processor_constants_pkg.all;" after the library clause in
--   any entity that needs instruction encoding constants or control records.
--   Do not redeclare constants or add entity-local aliases — always reference
--   the canonical names from this package to avoid divergence.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use work.vector_types_pkg.all;

package processor_constants_pkg is

    -- ========================================================================
    -- ARCHITECTURAL PARAMETERS
    -- ========================================================================
    -- WHY named constants instead of literals: every width and size that appears
    -- in more than one place is a single source of truth here.  Changing WARP_SIZE
    -- from 32 to 16 (hypothetically) would require only edits in this block, not
    -- a grep across all entities.
    constant WARP_SIZE       : integer := 32; -- Threads per warp (barrel scheduler replay count)
    constant THREAD_ID_WIDTH : integer := 5;  -- Bits to address WARP_SIZE threads (log2(32)=5)
    constant LOCAL_REG_WIDTH : integer := 4;  -- Bits to address 16 VRF/PRF registers per thread
    constant VRF_ADDR_WIDTH  : integer := THREAD_ID_WIDTH + LOCAL_REG_WIDTH; -- 9-bit flat VRF/PRF address = {thread_id, reg_idx}

    -- ========================================================================
    -- INSTRUCTION TYPES (Bottom 4 bits [3:0])
    -- ========================================================================
    -- WHY place the type tag in bits[3:0] rather than bits[31:28] or alongside
    -- the opcode: keeping the type in the LSBs allows the FSM to extract it
    -- with a simple 4-bit slice (inst_word(3 downto 0)) without shifting.  It
    -- also keeps the opcode field in a fixed position [31:26] regardless of type,
    -- simplifying the decoder for all instruction classes simultaneously.
    -- WHY 4 bits (16 possible types) when only 7 are used: leaves room for
    -- future instruction classes (e.g. tensor ops, special function units)
    -- without changing the instruction word format.
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
    -- WHY 3 bits: the swizzle field encodes only broadcast (splat) modes here,
    -- not arbitrary per-component permutations.  Full GLSL-style .xyzw swizzles
    -- would need 8 bits (2 bits × 4 components); restricting to splat modes
    -- saves instruction encoding bits and covers the most common use case
    -- (broadcasting a scalar — e.g. a uniform constant — across all vector lanes).
    -- WHY SWIZ_PASS = "000": making the identity the all-zeros encoding means
    -- freshly-zeroed control registers (reset state) default to no swizzle,
    -- which is the correct default for arithmetic instructions.
    -- WHY the splat modes start at "100": bit[2]='1' acts as a "splat enable"
    -- flag, with bits[1:0] selecting which component to broadcast.  This
    -- encoding can be decoded with a single MSB check.
    constant SWIZ_PASS      : std_logic_vector(2 downto 0) := "000"; -- Passthrough (.xyzw) — identity
    constant SWIZ_X         : std_logic_vector(2 downto 0) := "100"; -- Splat X (.xxxx) — broadcast component 0
    constant SWIZ_Y         : std_logic_vector(2 downto 0) := "101"; -- Splat Y (.yyyy) — broadcast component 1
    constant SWIZ_Z         : std_logic_vector(2 downto 0) := "110"; -- Splat Z (.zzzz) — broadcast component 2
    constant SWIZ_W         : std_logic_vector(2 downto 0) := "111"; -- Splat W/A (.wwww/.aaaa) — broadcast component 3


    -- ========================================================================
    -- FPU MATH OPCODES [31:26] (When Type == 0000)
    -- ========================================================================
    -- WHY OP_NOP = "000000" (all zeros): an instruction word of all zeros
    -- (e.g. uninitialized memory) decodes as FPU NOP, which is a safe no-op.
    -- This makes accidental execution of blank program memory benign.
    -- WHY the opcode space has gaps (e.g. no "001111"): opcodes are assigned
    -- to match Altera IP core select-function codes where possible so the
    -- execution unit can pass the opcode field directly to the IP core without
    -- a translation lookup table.
    constant OP_NOP     : std_logic_vector(5 downto 0) := "000000"; -- No operation (safe default for uninitialized IMEM)
    constant OP_FADD    : std_logic_vector(5 downto 0) := "000001"; -- IEEE 754 single-precision add
    constant OP_FSUB    : std_logic_vector(5 downto 0) := "000010"; -- IEEE 754 single-precision subtract
    constant OP_FMUL    : std_logic_vector(5 downto 0) := "000011"; -- IEEE 754 single-precision multiply
    constant OP_FMADD   : std_logic_vector(5 downto 0) := "000100"; -- Fused multiply-add: rs1*rs2+rs3
    constant OP_FRCP    : std_logic_vector(5 downto 0) := "000101"; -- Reciprocal: 1/rs1
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

    -- Predicate Logic Opcodes
    -- WHY these are FPU-type instructions (INST_TYPE_FPU) rather than ALU:
    --   Predicate registers are 4 bits wide and share the same 9-bit address
    --   space as VRF.  Routing PAND/POR/PXOR through the FPU pipeline (with
    --   the is_logic_op flag) allows them to use the existing PRF writeback
    --   path without a dedicated predicate ALU.
    constant OP_PAND    : std_logic_vector(5 downto 0) := "011000"; -- Predicate AND: pd = ps1 & ps2 (component-wise)
    constant OP_POR     : std_logic_vector(5 downto 0) := "011001"; -- Predicate OR:  pd = ps1 | ps2
    constant OP_PXOR    : std_logic_vector(5 downto 0) := "011010"; -- Predicate XOR: pd = ps1 ^ ps2

    -- ========================================================================
    -- SYSTEM OPCODES [31:26] (When Type == 0110)
    -- ========================================================================
    -- WHY system opcodes cluster at the top of the opcode space ("11xxxx"):
    --   Setting bits[31:30]="11" (the two MSBs of the opcode field) makes it
    --   visually obvious during instruction hex dumps that a word is a system
    --   instruction.  It also leaves the lower half of the space free for future
    --   SYS-type instructions that are not halt/interrupt operations.
    -- WHY OP_FLUSH goes through the issuer (EXEC_WAIT path) rather than acting
    --   immediately: FLUSH must send a sentinel token through the entire 28-stage
    --   FPU pipeline to ensure all in-flight results have committed to the VRF
    --   before the barrier completes.  The issuer + exec_flush_active mechanism
    --   implements this without a dedicated stall counter in the FSM.
    constant OP_FLUSH   : std_logic_vector(5 downto 0) := "111110"; -- Pipeline memory barrier: drain all in-flight ops
    constant OP_RETURN  : std_logic_vector(5 downto 0) := "111111"; -- End of kernel: halt processor (csr_run <= 0)
    constant OP_BREAK   : std_logic_vector(5 downto 0) := "111100"; -- Debug breakpoint: halt + set break_hit flag
    constant OP_INT     : std_logic_vector(5 downto 0) := "111101"; -- Software interrupt: set irq_pending, continue execution

    -- ========================================================================
    -- CONTROL FLOW OPCODES [31:26] (When Type == 0001)
    -- ========================================================================
    -- WHY CTRL instructions go directly to ADVANCE_PC (no issuer involvement):
    --   Branch decisions are warp-wide, not per-thread.  The IFU computes the
    --   next PC combinationally from active_pc_ctrl during ADVANCE_PC.  There
    --   is nothing for the issuer or execution unit to do for CTRL instructions.
    -- WHY OP_BRA_DIV (divergent branch) is distinct from OP_BRA_Z / OP_BRA_NZ:
    --   A divergent branch pushes the "true path" thread mask onto the SIMT
    --   divergence stack and continues with the "false path" mask.  BRA_Z/NZ
    --   are convergent branches that only need a single taken/not-taken bit;
    --   they do not interact with the divergence stack.
    -- WHY OP_SSY / OP_SYNC exist as separate instructions:
    --   SSY (Set Sync) pushes the post-divergence meetup PC onto the stack so
    --   that both divergent paths know where to converge.  SYNC (Synchronize)
    --   pops the stack and resumes with the union of both thread masks.
    --   Having explicit stack push/pop instructions allows software to control
    --   nesting depth and meetup points precisely.
    constant OP_JMP     : std_logic_vector(5 downto 0) := "110000"; -- Unconditional jump to target_addr
    constant OP_BRA_Z   : std_logic_vector(5 downto 0) := "110001"; -- Branch if warp predicate evaluates to zero
    constant OP_BRA_NZ  : std_logic_vector(5 downto 0) := "110010"; -- Branch if warp predicate evaluates to non-zero
    constant OP_BRA_DIV : std_logic_vector(5 downto 0) := "110011"; -- Divergent branch: push true-path mask, execute false path
    constant OP_SSY     : std_logic_vector(5 downto 0) := "110100"; -- Set Sync: push meetup PC onto divergence stack
    constant OP_SYNC    : std_logic_vector(5 downto 0) := "110101"; -- Synchronize: pop divergence stack, merge thread masks

    -- ========================================================================
    -- WRITEBACK MUX SELECTORS
    -- ========================================================================
    -- WHY three selectors (not a flag per unit): the three execution pipelines
    -- (FPU, RED, ALU) have different output bus widths and latency padding.
    -- A 2-bit mux selector is cheaper to pipeline through FPU_MAX_LATENCY
    -- stages than three individual enable bits, and prevents two units from
    -- simultaneously claiming the writeback port.
    constant WB_MUX_FPU : std_logic_vector(1 downto 0) := "00"; -- Route FPU output to VRF
    constant WB_MUX_RED : std_logic_vector(1 downto 0) := "01"; -- Route reduction unit output to VRF
    constant WB_MUX_ALU : std_logic_vector(1 downto 0) := "10"; -- Route ALU output to VRF

    -- ========================================================================
    -- REDUCTION UNIT MODES (Used when Type == 0010)
    -- ========================================================================
    -- WHY four modes rather than a general multiply-accumulate:
    --   These four cover the most common inner-product operations in graphics
    --   and signal processing shaders (dot product for lighting, squared
    --   magnitude for normalization, component sum for area integrals, absolute
    --   sum for Manhattan distance).  A general MACC would require a separate
    --   multiplier input mux and increase the critical path of the reduction
    --   pipeline.  The four fixed modes are implemented efficiently in Altera's
    --   dot-product IP core.
    constant RED_MODE_DOT     : std_logic_vector(1 downto 0) := "00"; -- Dot product: sum(rs1[i] * rs2[i])
    constant RED_MODE_SQ_MAG  : std_logic_vector(1 downto 0) := "01"; -- Squared magnitude: sum(rs1[i] * rs1[i])
    constant RED_MODE_SUM     : std_logic_vector(1 downto 0) := "10"; -- Component sum: sum(rs1[i])
    constant RED_MODE_ABS_SUM : std_logic_vector(1 downto 0) := "11"; -- Absolute sum: sum(|rs1[i]|)

    -- ========================================================================
    -- CONDENSED BRANCH TYPES & PREDICATE MODIFIERS
    -- ========================================================================
    -- WHY condensed branch types (BR_*) in addition to the raw OP_* opcodes:
    --   The IFU needs to evaluate branch conditions and update the PC using a
    --   simple case statement.  Comparing against 6-bit opcodes would give a
    --   large case with many unused values.  The decoder pre-translates each
    --   CTRL opcode into a 3-bit BR_* code stored in pc_ctrl_t.branch_type,
    --   keeping the IFU's combinational logic small and fast on the critical path.
    -- WHY BR_NONE = "000": makes the default (reset) state of pc_ctrl_t a
    --   no-branch, which is correct for sequential execution and for non-CTRL
    --   instructions whose dec_pc fields are irrelevant.
    constant BR_NONE    : std_logic_vector(2 downto 0) := "000"; -- No branch; PC increments normally
    constant BR_JMP     : std_logic_vector(2 downto 0) := "001"; -- Unconditional jump
    constant BR_BRA_Z   : std_logic_vector(2 downto 0) := "010"; -- Branch if predicate is zero
    constant BR_BRA_NZ  : std_logic_vector(2 downto 0) := "011"; -- Branch if predicate is non-zero
    constant BR_BRA_DIV : std_logic_vector(2 downto 0) := "100"; -- Divergent branch (push true mask)
    constant BR_SSY     : std_logic_vector(2 downto 0) := "101"; -- Set sync point (push meetup PC)
    constant BR_SYNC    : std_logic_vector(2 downto 0) := "110"; -- Synchronize (pop divergence stack)

    -- WHY four predicate modifiers rather than just ANY/ALL:
    --   Shaders commonly need to branch on a single specific predicate component
    --   (e.g. "if alpha > 0" = PRED_MOD_A on the alpha component) without
    --   requiring all four components to meet the condition.  X and A
    --   (component 0 and component 3) are the most useful single-component
    --   cases for scalar and alpha conditions respectively.
    constant PRED_MOD_ANY : std_logic_vector(1 downto 0) := "00"; -- Branch taken if any component of predicate == 1
    constant PRED_MOD_ALL : std_logic_vector(1 downto 0) := "01"; -- Branch taken if all components of predicate == 1
    constant PRED_MOD_X   : std_logic_vector(1 downto 0) := "10"; -- Branch taken if X (component 0) of predicate == 1
    constant PRED_MOD_A   : std_logic_vector(1 downto 0) := "11"; -- Branch taken if A/W (component 3) of predicate == 1

    -- ========================================================================
    -- INTEGER ALU OPCODES [31:26] (When Type == 0011)
    -- ========================================================================
    -- WHY OP_IADD = "000000" collides with OP_NOP: the INST_TYPE field (bits[3:0])
    -- disambiguates — "000000" with INST_TYPE_ALU is IADD; with INST_TYPE_FPU
    -- it is NOP.  The ALU and FPU are separate functional units, so the same
    -- numeric opcode is safe to reuse across types.
    -- WHY OP_ISHL/ISHR (logical shift) and OP_ISAR (arithmetic shift right)
    -- are separate: logical shift fills vacated bits with 0; arithmetic shift
    -- right sign-extends, which is needed for signed integer division by powers
    -- of two.  Keeping them as separate opcodes avoids a sign/unsigned flag bit.
    -- WHY OP_THREAD_ID is an ALU instruction: it produces a per-thread integer
    -- result (warp_offset + thread_id) that belongs in the VRF as an integer,
    -- not a float.  Routing it through the ALU pipeline (not FPU) avoids an
    -- unnecessary int-to-float conversion.
    constant OP_IADD    : std_logic_vector(5 downto 0) := "000000"; -- Integer add: rd = rs1 + rs2
    constant OP_ISUB    : std_logic_vector(5 downto 0) := "000001"; -- Integer subtract: rd = rs1 - rs2
    constant OP_IAND    : std_logic_vector(5 downto 0) := "000010"; -- Bitwise AND
    constant OP_IOR     : std_logic_vector(5 downto 0) := "000011"; -- Bitwise OR
    constant OP_IXOR    : std_logic_vector(5 downto 0) := "000100"; -- Bitwise XOR
    constant OP_ISHL    : std_logic_vector(5 downto 0) := "000101"; -- Logical shift left
    constant OP_ISHR    : std_logic_vector(5 downto 0) := "000110"; -- Logical shift right (zero-fill)
    constant OP_IMUL    : std_logic_vector(5 downto 0) := "000111"; -- Integer multiply (lower 32 bits)
    constant OP_IINC    : std_logic_vector(5 downto 0) := "001000"; -- Increment: rd = rs1 + 1
    constant OP_IDEC    : std_logic_vector(5 downto 0) := "001001"; -- Decrement: rd = rs1 - 1
    constant OP_ISAR    : std_logic_vector(5 downto 0) := "001010"; -- Arithmetic shift right (sign-extend)
    constant OP_ICMP_EQ   : std_logic_vector(5 downto 0) := "001011"; -- Compare equal → predicate register
    constant OP_ICMP_SLT  : std_logic_vector(5 downto 0) := "001100"; -- Compare signed less-than → predicate
    constant OP_ICMP_ULT  : std_logic_vector(5 downto 0) := "001101"; -- Compare unsigned less-than → predicate
    constant OP_THREAD_ID : std_logic_vector(5 downto 0) := "001110"; -- rd = csr_warp_offset + thread_id (per-thread unique ID)

    -- ========================================================================
    -- IMMEDIATE OPCODES [31:26] (When Type == 0100)
    -- ========================================================================
    -- WHY two instructions (LDI_LO / LDI_HI) rather than one 32-bit load:
    --   The instruction word is only 32 bits wide.  After reserving 4 bits for
    --   INST_TYPE, 6 for opcode, and 4 for the destination register, only 18
    --   bits remain — not enough for a full 32-bit immediate.  LDI_LO loads the
    --   lower 16 bits of a register; LDI_HI loads the upper 16 bits.  Together
    --   they allow any 32-bit constant to be materialized in two instructions,
    --   which is sufficient for loading addresses and wide constants.
    constant OP_LDI_LO  : std_logic_vector(5 downto 0) := "000000"; -- Load 16-bit immediate into lower half of rd
    constant OP_LDI_HI  : std_logic_vector(5 downto 0) := "000001"; -- Load 16-bit immediate into upper half of rd

    -- ========================================================================
    -- MEMORY OPCODES [31:26] (When Type == 0101)
    -- ========================================================================
    -- WHY bits[31:30] = "10" for memory opcodes: mirrors the SYS opcode
    -- convention ("11xxxx") by placing memory ops in the upper quarter of
    -- the opcode space, making them visually distinguishable from arithmetic
    -- ops (which start at "00xxxx").
    -- WHY LOAD and STORE are separate opcodes (not a single MEM + is_store bit):
    --   The is_store direction bit is already decoded from the instruction word
    --   by the decoder into dec_mem.is_store.  The separate opcode values
    --   provide a redundant check and make disassembly output unambiguous.
    constant OP_LOAD    : std_logic_vector(5 downto 0) := "100000"; -- Scatter-gather load: VRF[dest] ← DDR3[base + offset[t]]
    constant OP_STORE   : std_logic_vector(5 downto 0) := "100001"; -- Scatter-gather store: DDR3[base + offset[t]] ← VRF[src]

    -- ========================================================================
    -- CSR (CONTROL STATUS REGISTER) ADDRESS MAP (3-Bit)
    -- ========================================================================
    -- WHY a 3-bit address space (8 registers): this maps directly to Quartus
    -- Platform Designer's Avalon-MM slave port, which uses a word-address
    -- register select.  3 bits gives 8 registers; the current design uses 7.
    -- Increasing to 4 bits would require regenerating the Platform Designer
    -- component; 3 bits is sufficient for the current feature set.
    -- WHY W1C (write-1-to-clear) for IRQ_ACK and BREAK: allows the host to
    -- atomically clear a flag in a single write without needing a prior read.
    -- This prevents a race condition where a new event could set the flag
    -- between a read and a write-0 operation.
    constant CSR_ADDR_RUN         : std_logic_vector(2 downto 0) := "000"; -- [R/W]   bit[0]: 1=run, 0=halt
    constant CSR_ADDR_START_PC    : std_logic_vector(2 downto 0) := "001"; -- [W]     bits[15:0]: force PC to this address on next ADVANCE_PC
    constant CSR_ADDR_IRQ_ACK     : std_logic_vector(2 downto 0) := "010"; -- [R/W1C] bit[0]: read=irq_pending, write-1-to-clear
    constant CSR_ADDR_BREAK       : std_logic_vector(2 downto 0) := "011"; -- [R/W1C] bit[0]: read=break_hit, write-1-to-clear
    constant CSR_ADDR_CURR_PC     : std_logic_vector(2 downto 0) := "100"; -- [R]     bits[15:0]: current IFU program counter
    constant CSR_ADDR_EXEC_MASK   : std_logic_vector(2 downto 0) := "101"; -- [R]     bits[31:0]: active thread execution mask from IFU
    constant CSR_ADDR_WARP_OFFSET : std_logic_vector(2 downto 0) := "110"; -- [R/W]   bits[31:0]: base thread ID added by THREAD_ID instruction

    -- ========================================================================
    -- CONTROL RECORDS (Expanded explicitly to remove downstream decoding)
    -- ========================================================================
    -- WHY use records instead of raw std_logic_vector buses:
    --   Passing decoded control fields as named record members means the
    --   compiler catches any field mismatch (wrong width, wrong name) at
    --   elaboration time.  A flat slv bus would require every connected entity
    --   to know which bits carry which field — a fragile convention that breaks
    --   silently when the encoding changes.
    -- WHY separate records per instruction class rather than one big record:
    --   Different instruction classes encode the same bit positions differently.
    --   For example, FPU has three source registers while ALU has two; MEM has
    --   a base address field where ALU has an immediate.  One unified record
    --   would need all fields to be always present, wasting logic when unused
    --   fields must be driven to constants.  Separate records let the decoder
    --   express exactly what each class needs; the top-level mux selects the
    --   right one before the issuer.

    -- fpu_ctrl_t: decoded fields for INST_TYPE_FPU instructions.
    -- cmp_invert: when '1', the comparison result is logically inverted before
    --   writing to the predicate register (implements >=, !=, etc.).
    -- cmp_swap: when '1', operands rs1 and rs2 are swapped before comparison
    --   (implements >, <= without needing separate opcodes for each direction).
    -- is_logic_op: distinguishes PAND/POR/PXOR (predicate ops) from arithmetic
    --   FPU ops so the execution unit can route to the predicate write path.
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
    -- WHY no rs3 field: the reduction unit only accumulates rs1 and rs2; it
    --   does not support a third source operand.
    -- WHY red_mask is separate from write_mask: write_mask controls which VRF
    --   components are written; red_mask controls which vector components are
    --   included in the reduction accumulation (e.g. 3-component vs 4-component
    --   dot product).
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
    -- This record is evaluated by the IFU during ADVANCE_PC to compute the
    -- next PC.  It is also injected by the processor top level (active_pc_ctrl)
    -- when do_force_pc='1' to implement host-driven PC repositioning.
    -- predicate_sel: which predicate register (by local index) holds the
    --   branch condition; the PRF evaluates it combinationally into prf_mask_out.
    -- predicate_mod: PRED_MOD_* constant controlling the collapse function.
    type pc_ctrl_t is record
        branch_type     : std_logic_vector(2 downto 0);  -- BR_* constant
        target_addr     : std_logic_vector(15 downto 0); -- Instruction-word-encoded branch target (PC-relative or absolute)
        predicate_sel   : std_logic_vector(1 downto 0);  -- Local predicate register index for conditional branches
        predicate_mod   : std_logic_vector(1 downto 0);  -- PRED_MOD_* collapse mode
    end record;

    -- alu_ctrl_t: decoded fields for INST_TYPE_ALU and INST_TYPE_IMM.
    -- WHY no rs3 field: the integer ALU is a 2-source unit; no ALU instruction
    --   uses a third register operand.
    -- is_load: '1' for INST_TYPE_IMM instructions.  When set, the execution
    --   unit substitutes imm_data for the rs2 read value on the operand path,
    --   making the 16-bit immediate act as a literal second operand.
    -- imm_data: 16-bit immediate from the instruction word; only valid when
    --   INST_TYPE_IMM; zero for INST_TYPE_ALU.
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

    -- mem_ctrl_t: decoded fields for INST_TYPE_MEM instructions.
    -- WHY this record is NOT merged into exec_ctrl_t: memory operations bypass
    --   the execution pipeline entirely (they go to memory_unit, not u_exec).
    --   Including memory fields in exec_ctrl_t would bloat the record carried
    --   through FPU_MAX_LATENCY pipeline stages for every instruction, even
    --   though those fields are never used by the execution unit.  Keeping mem
    --   separate allows exec_ctrl_t to remain minimal.
    -- base_addr: 16-bit field from instruction encoding.  Zero-extended to 32
    --   bits at the instantiation site: dec_mem.base_addr & x"0000" places the
    --   immediate in bits[31:16] of the Avalon address.
    type mem_ctrl_t is record
        is_valid         : std_logic;                    -- Mirrors mem_op_valid; available for the MCU
        is_store         : std_logic;                    -- '1' = scatter (write DDR3), '0' = gather (read DDR3)
        base_addr        : std_logic_vector(15 downto 0); -- 16-bit instruction immediate; upper half of byte address
        offset_reg_idx   : std_logic_vector(3 downto 0); -- Local register index of per-thread byte offset
        dest_src_reg_idx : std_logic_vector(3 downto 0); -- Local register index of load destination / store source
    end record;

    -- ========================================================================
    -- UNIFIED EXECUTION PIPELINE RECORD
    -- ========================================================================
    -- WHY exec_ctrl_t is a superset of both fpu_ctrl_t and alu_ctrl_t fields:
    --   The instruction_issue entity and execution_unit share a single record
    --   type for simplicity.  The decoder-mux in the processor top level
    --   populates only the relevant fields for each instruction class; the
    --   unused fields default to safe values ('0' / all-zeros).  This avoids
    --   the need for polymorphism or multiple port map variants on the issuer.
    -- WHY rs*_addr_local fields exist even though the issuer expands them to
    --   global addresses: the issuer reads these local indices to compute the
    --   global {thread_id, reg_idx} address.  After the issuer, local addresses
    --   are no longer needed (iss_exec_record zeroes them out).
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
    -- WHY these are constants in the package rather than local generics on each
    -- entity: the latency values must be consistent between the execution unit
    -- (which builds the delay-line padding) and the FSM/issuer (which determine
    -- how long to wait in EXEC_WAIT).  A package constant is a single source of
    -- truth; if the IP core configuration changes (e.g., pipeline stages are
    -- adjusted in Quartus IP parameter editor), only this file needs updating.
    --
    -- CRITICAL: Each constant must exactly match the pipeline depth reported by
    -- the corresponding Altera/Intel Floating-Point IP core at synthesis.  If a
    -- core's latency changes after regeneration, the writeback will be delayed
    -- or early by the delta, corrupting the wrong register for up to WARP_SIZE
    -- consecutive threads.
    --
    -- LAT_* values are in clock cycles from the cycle input data is presented
    -- to the cycle the result appears at the IP core output.
    constant LAT_FMADD      : integer := 22; -- Fused multiply-add (ALTFP_MULT + ALTFP_ADD pipeline)
    constant LAT_FRCP       : integer := 14; -- Reciprocal (ALTFP_INV)
    constant LAT_FSQRT      : integer := 9;  -- Square root (ALTFP_SQRT)
    constant LAT_FRSQRT     : integer := 28; -- Reciprocal square root — equals FPU_MAX_LATENCY (bottleneck op)
    constant LAT_FMIN       : integer := 3;  -- Component-wise minimum (comparator + mux)
    constant LAT_FMAX       : integer := 3;  -- Component-wise maximum (comparator + mux)
    constant LAT_FSIN       : integer := 21; -- Sine (ALTFP_SINCOS)
    constant LAT_FCOS       : integer := 21; -- Cosine (ALTFP_SINCOS)
    constant LAT_FLOG2      : integer := 21; -- Base-2 log (ALTFP_LOG)
    constant LAT_FEXP2      : integer := 17; -- Base-2 exponent (ALTFP_EXP)
    constant LAT_FCMP_LT    : integer := 3;  -- Less-than compare (ALTFP_COMPARE)
    constant LAT_FCMP_EQ    : integer := 3;  -- Equality compare (ALTFP_COMPARE)
    constant LAT_I2F        : integer := 6;  -- Integer to float conversion (ALTFP_CONVERT)
    constant LAT_F2I        : integer := 6;  -- Float to integer conversion (ALTFP_CONVERT)
    constant LAT_REDUCT     : integer := 16; -- 4D dot product reduction (optimized accumulator IP)

    -- FPU_MAX_LATENCY: The normalizing pipeline depth.
    -- WHY 28 (= LAT_FRSQRT): reciprocal square root is the slowest operation.
    -- Every other unit has a shift-register delay appended to pad its output to
    -- this same latency.  This ensures that for any single instruction, all 32
    -- thread results arrive at the VRF write port in a contiguous 32-cycle
    -- burst starting exactly FPU_MAX_LATENCY cycles after issue of thread 0.
    -- The FSM waits in EXEC_WAIT until exec_flush_active='0', which the
    -- execution unit asserts only after the last padded result has committed.
    constant FPU_MAX_LATENCY : integer := LAT_FRSQRT; -- Tied to bottleneck op; update LAT_FRSQRT if IP changes

end package;
