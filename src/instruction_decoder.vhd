-- =============================================================================
-- FILE: instruction_decoder.vhd
-- COMPONENT: Instruction Decoder
-- =============================================================================
--
-- Purely combinational instruction decode. Given a 32-bit instruction word, it
-- produces five decoded control records that fan out to different pipeline
-- units: FPU, reduction, ALU, and PC (branch). There is no state and no
-- registered outputs; every output changes within the same clock cycle as the
-- input instruction word changes.
--
-- Inputs:
--   instruction - 32-bit raw instruction word from instruction memory.
--
-- Outputs:
--   fpu_ctrl    - Decoded FPU control record. Also carries SYS opcodes.
--   red_ctrl    - Decoded reduction control record.
--   alu_ctrl    - Decoded integer ALU control record. Also carries IMM ops.
--   pc_ctrl     - Decoded branch/jump control record.
--
--
-- INSTRUCTION WORD BIT FIELD LAYOUT (by instruction type):
--
--   [3:0]  = inst_type  (common to all formats, selects the decode branch)
--   [31:26] = opcode    (common to all formats)
--
-- Floating-Point Operation (does math on vector registers in parallel)
--   FPU  : [31:26]=opcode  [25:22]=write_mask  [21:18]=rd    [17:14]=rs1
--          [13:10]=rs2     [9:7]=swiz_a         [6]=cmp_inv  [5]=cmp_swap
--          (rs3 not encoded; reserved for future FMA extension)
--
-- Reduction Operation (sums along vector register compon):
--   RED  : [31:30]=mode    [29:26]=mask         [25:22]=rd    [21:18]=rs1
--          [17:14]=rs2     [13:11]=swiz_a       [10:8]=swiz_b
--          (mode overlaps the top 2 bits of opcode because RED only needs
--           2 mode bits and has no further opcode variation)
--
-- Branch Operations (modifies PC):
--   CTRL : [31:26]=opcode  [25:10]=target_addr(16b) [9:6]=pred_sel
--          [5:4]=pred_mod
--
-- ALU Operations (treats registers as integers):
--   ALU  : [31:26]=opcode  [25:22]=write_mask   [21:18]=rd    [17:14]=rs1
--          [13:10]=rs2     [9:7]=swiz_a         [6:4]=reserved
--          (no rs3, no cmp fields — integer ops are simpler than FPU)
--
-- Immediate Load Instructions:
--   IMM  : [31:30]=LDI_subop  [29:26]=write_mask  [25:10]=imm16  [9:8]=reserved
--          [7:4]=rd
--          (LDI_subop: "00"=LDI_LO, "01"=LDI_HI; decoded by alu_lane on opcode[5:4])
--          (write_mask: 4-bit component mask — same W/Z/Y/X convention as ALU/FPU)
--          (rs1_addr is set equal to rd_addr so the ALU can read the current
--           destination value; needed by LDI_HI to preserve the lower 16 bits)
--
-- System instructions:
--   SYS  : [31:26]=opcode  [25:4]=reserved       [3:0]=type
--          (FLUSH/RETURN/BREAK/INT: opcode is routed through v_fpu because
--           warp_unit.vhd's exec_mux uses dec_fpu.opcode as the default path;
--           no register reads or writes are needed for these tokens)
--
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_decoder is
    port (
        instruction : in  word_t;
        fpu_ctrl    : out fpu_ctrl_t;
        red_ctrl    : out red_ctrl_t;
        alu_ctrl    : out alu_ctrl_t;
        pc_ctrl     : out pc_ctrl_t
    );
end entity;

architecture rtl of instruction_decoder is

    -- inst_type: bottom 4 bits, select the decode branch below.
    -- Extracted as a named signal for readability and to avoid repeating the
    -- bit-slice in every comparison.
    signal inst_type       : std_logic_vector(3 downto 0);

    -- internal_opcode: top 6 bits, common to all formats that carry an opcode.
    -- For INST_TYPE_RED the top 2 bits are repurposed as the reduction mode,
    -- so this signal is only meaningful as an opcode for non-RED instructions.
    signal internal_opcode : std_logic_vector(5 downto 0);

begin

    inst_type       <= instruction(3 downto 0);
    internal_opcode <= instruction(31 downto 26);

    process(instruction, inst_type, internal_opcode)
        variable v_fpu : fpu_ctrl_t;
        variable v_red : red_ctrl_t;
        variable v_pc  : pc_ctrl_t;
        variable v_alu : alu_ctrl_t;
    begin
        -- ====================================================================
        -- INITIALIZE VARIABLES WITH SAFE DEFAULTS (Prevents latches)
        -- ====================================================================
        v_fpu.opcode         := OP_NOP;
        v_fpu.rs1_addr_local := "0000";
        v_fpu.rs2_addr_local := "0000";
        v_fpu.rs3_addr_local := "0000";
        v_fpu.rd_addr_local  := "0000";
        v_fpu.swiz_sel_a     := SWIZ_PASS;
        v_fpu.swiz_sel_b     := SWIZ_PASS;
        v_fpu.swiz_sel_c     := SWIZ_PASS;
        v_fpu.write_mask     := "0000";
        v_fpu.cmp_invert     := '0';
        v_fpu.cmp_swap       := '0';
        v_fpu.is_logic_op    := '0';
        v_fpu.wb_mux_sel     := WB_MUX_FPU;
        v_fpu.vrf_we         := '0';
        v_fpu.prf_we         := '0';

        v_red.rs1_addr_local := "0000";
        v_red.rs2_addr_local := "0000";
        v_red.rd_addr_local  := "0000";
        v_red.swiz_sel_a     := SWIZ_PASS;
        v_red.swiz_sel_b     := SWIZ_PASS;
        v_red.red_mask       := "0000";
        v_red.red_mode       := "00";
        v_red.wb_mux_sel     := WB_MUX_RED;
        v_red.vrf_we         := '0';

        v_pc.branch_type     := BR_NONE; -- 4-bit; "0000" = no branch
        v_pc.target_addr     := (others => '0');
        v_pc.predicate_sel   := "0000";
        v_pc.predicate_mod   := PRED_MOD_ANY;

        v_alu.opcode         := OP_NOP;
        v_alu.rs1_addr_local := "0000";
        v_alu.rs2_addr_local := "0000";
        v_alu.rd_addr_local  := "0000";
        v_alu.swiz_sel_a     := SWIZ_PASS;
        v_alu.swiz_sel_b     := SWIZ_PASS;
        v_alu.write_mask     := "0000";
        v_alu.wb_mux_sel     := WB_MUX_ALU;
        v_alu.vrf_we         := '0';
        v_alu.prf_we         := '0';
        v_alu.is_load        := '0';
        v_alu.imm_data       := (others => '0');

        -- ====================================================================
        -- DECODE BASED ON INSTRUCTION TYPE
        -- ====================================================================
        if inst_type = INST_TYPE_FPU then
            -- ----------------------------------------------------------------
            -- FPU MATH INSTRUCTION MAP
            -- [31:26] Opcode | [25:22] Mask | [21:18] Dest | [17:14] Src1
            -- [13:10] Src2   | [9:7] Swiz A | [6] Cmp_Inv | [5] Cmp_Swap | [4] Rsvd | [3:0] Type
            -- ----------------------------------------------------------------
            v_fpu.opcode         := internal_opcode;
            v_fpu.write_mask     := instruction(25 downto 22);
            v_fpu.rd_addr_local  := instruction(21 downto 18);
            v_fpu.rs1_addr_local := instruction(17 downto 14);
            v_fpu.rs2_addr_local := instruction(13 downto 10);
            -- rs3 is not encoded in this instruction format: only 2-source FPU
            -- ops are currently supported. FMA (3-source) would need a new
            -- format variant with rs3 occupying bits currently reserved.
            v_fpu.rs3_addr_local := (others => '0');

            -- cmp_invert/cmp_swap: modifier bits that allow the assembler to
            -- synthesize LT/GT/LE/GE/NE comparisons from just FCMP_LT and
            -- FCMP_EQ. cmp_invert flips the result; cmp_swap swaps operand order.
            v_fpu.cmp_invert     := instruction(6);
            v_fpu.cmp_swap       := instruction(5);

            -- Only swiz_sel_a is encoded for FPU ops. swiz_sel_b defaults to
            -- SWIZ_PASS (pass-through) set during initialization above.
            v_fpu.swiz_sel_a     := instruction(9 downto 7);

            case internal_opcode is
                -- Standard math ops: result goes to VRF (floating-point data).
                -- prf_we='0' because math results are not comparison predicates.
                when OP_FADD | OP_FSUB | OP_FMUL | OP_FMADD |
                     OP_FDIV | OP_FSQRT | OP_FLOG2 | OP_FEXP2 |
                     OP_FMIN | OP_FMAX | OP_F2I | OP_I2F |
                     OP_SIN  | OP_COS  | OP_MOV =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '1';
                    v_fpu.prf_we      := '0';
                    v_fpu.is_logic_op := '0';

                -- Comparison ops: result goes to PRF (predicate register file),
                -- NOT the VRF. vrf_we='0' prevents clobbering a vector register.
                -- is_logic_op='0' so swizzle_network routes VRF data (not PRF bits)
                -- to the FPU inputs — the FPU compares float values.
                when OP_FCMP_LT | OP_FCMP_EQ =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '0';
                    v_fpu.prf_we      := '1';
                    v_fpu.is_logic_op := '0';

                -- Predicate logic ops (AND/OR/XOR on predicate registers):
                -- result goes to PRF. is_logic_op='1' tells swizzle_network to
                -- route PRF bits (not VRF floats) to the FPU inputs, because
                -- these ops operate on 1-bit predicate values, not floats.
                when OP_PAND | OP_POR | OP_PXOR =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '0';
                    v_fpu.prf_we      := '1';
                    v_fpu.is_logic_op := '1';

                -- NOP: no writes; safe to pass through the pipeline doing nothing.
                when OP_NOP =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '0';
                    v_fpu.prf_we      := '0';
                    v_fpu.is_logic_op := '0';

                when others => null;
            end case;

        elsif inst_type = INST_TYPE_RED then
            -- ----------------------------------------------------------------
            -- REDUCTION INSTRUCTION MAP
            -- [31:30] Mode | [29:26] Mask | [25:22] Dest   | [21:18] Src1
            -- [17:14] Src2 | [13:11] Swz A| [10:8] Swz B   | [3:0] Type
            -- ----------------------------------------------------------------
            -- WHY mode overlaps the opcode field: reductions only need 2 bits
            -- of mode (e.g. sum, dot, min, max) and there is no further opcode
            -- variation within the RED type. Reusing bits [31:30] avoids
            -- wasting instruction encoding space.
            v_red.red_mode       := instruction(31 downto 30);
            v_red.red_mask       := instruction(29 downto 26);
            v_red.rd_addr_local  := instruction(25 downto 22);
            v_red.rs1_addr_local := instruction(21 downto 18);
            v_red.rs2_addr_local := instruction(17 downto 14);

            -- Reduction supports independent swizzles on both source operands
            -- (unlike FPU which only swizzles rs1). This allows, for example,
            -- a dot product to read rs1.xyzw and rs2.xyzw in different orders.
            v_red.swiz_sel_a     := instruction(13 downto 11);
            v_red.swiz_sel_b     := instruction(10 downto 8);

            v_red.wb_mux_sel     := WB_MUX_RED;
            -- Reduction always writes to VRF (scalar result broadcast to all
            -- components). There is no predicate-producing reduction variant.
            v_red.vrf_we         := '1';

        elsif inst_type = INST_TYPE_CTRL then
            -- ----------------------------------------------------------------
            -- SIMT CONTROL INSTRUCTION MAP
            -- [31:26] Opcode | [25:10] Target (16b) | [9:6] P_Sel
            -- [5:4] P_Mod | [3:0] Type
            -- ----------------------------------------------------------------
            -- target_addr is a 16-bit absolute PC value (matching PC_WIDTH in
            -- the IFU generic). It is the branch destination for JMP/BRA, the
            -- reconvergence point for SSY, or the not-taken fallthrough for SYNC.
            v_pc.target_addr   := instruction(25 downto 10);

            -- predicate_sel chooses which PRF register to evaluate for conditional
            -- branches (BRA_Z, BRA_NZ). predicate_mod controls whether ANY or ALL
            -- active threads must satisfy the predicate to take the branch.
            v_pc.predicate_sel := instruction(9 downto 6);
            v_pc.predicate_mod := instruction(5 downto 4);

            case internal_opcode is
                when OP_JMP     => v_pc.branch_type := BR_JMP;
                when OP_BRA_Z   => v_pc.branch_type := BR_BRA_Z;
                when OP_BRA_NZ  => v_pc.branch_type := BR_BRA_NZ;

                -- BRA_DIV: divergent branch that may split the active thread mask.
                -- Handled by the IFU's SIMT stack logic; see instruction_fetch_unit.vhd.
                when OP_BRA_DIV => v_pc.branch_type := BR_BRA_DIV;

                -- SSY: "Set Sync Point" — records the reconvergence PC before a
                -- BRA_DIV so the SIMT stack knows where to rejoin the warp.
                when OP_SSY     => v_pc.branch_type := BR_SSY;

                -- SYNC: reconvergence instruction. The IFU uses the SIMT stack
                -- entry to decide whether this is the end of IF or ELSE.
                when OP_SYNC    => v_pc.branch_type := BR_SYNC;

                -- Function call / return instructions (link register + call stack):
                when OP_BRA_L   => v_pc.branch_type := BR_BRA_L;
                when OP_BRA_X   => v_pc.branch_type := BR_BRA_X;
                when OP_PUSH_L  => v_pc.branch_type := BR_PUSH_L;
                when OP_POP_L   => v_pc.branch_type := BR_POP_L;
                when others     => v_pc.branch_type := BR_NONE;
            end case;

        elsif inst_type = INST_TYPE_ALU then
            -- ----------------------------------------------------------------
            -- INTEGER ALU INSTRUCTION MAP
            -- [31:26] Opcode | [25:22] Mask | [21:18] Dest | [17:14] Src1
            -- [13:10] Src2   | [9:7] Swiz A | [6:4] Reserved | [3:0] Type
            -- ----------------------------------------------------------------
            -- ALU format is deliberately identical to FPU format in the
            -- register-address and mask fields. This keeps assembler tooling
            -- simple: the same field extraction code handles both types.
            v_alu.opcode         := internal_opcode;
            v_alu.write_mask     := instruction(25 downto 22);
            v_alu.rd_addr_local  := instruction(21 downto 18);
            v_alu.rs1_addr_local := instruction(17 downto 14);
            v_alu.rs2_addr_local := instruction(13 downto 10);

            -- Only swiz_sel_a is encoded. swiz_sel_b = SWIZ_PASS because the
            -- ALU lane only reads component 0 of each operand anyway (scalar).
            v_alu.swiz_sel_a     := instruction(9 downto 7);
            v_alu.swiz_sel_b     := SWIZ_PASS;

            v_alu.wb_mux_sel     := WB_MUX_ALU;

            -- ICMP instructions write to the PRF (1-bit comparison flag per
            -- component), not the VRF. This mirrors the FPU FCMP design.
            -- All other integer ALU ops (including THREAD_ID, RESOLUTION, TIME) 
            -- produce a 32-bit integer result routed to the VRF.
            if internal_opcode = OP_ICMP_EQ or internal_opcode = OP_ICMP_SLT or internal_opcode = OP_ICMP_ULT then
                v_alu.vrf_we := '0';
                v_alu.prf_we := '1';
            else
                v_alu.vrf_we := '1';
                v_alu.prf_we := '0';
            end if;

        elsif inst_type = INST_TYPE_IMM then
            -- ----------------------------------------------------------------
            -- IMMEDIATE INSTRUCTION MAP (Routes to ALU Lane)
            -- [31:30] LDI sub-op | [29:26] Write Mask | [25:10] Imm16
            -- [9:8] Reserved     | [7:4] Dest          | [3:0] Type
            -- ----------------------------------------------------------------
            -- internal_opcode = instruction[31:26]:
            --   bits[5:4] = LDI sub-op (00=LDI_LO, 01=LDI_HI); decoded by alu_lane
            --   bits[3:0] = write_mask (carried in opcode lower nibble; alu_lane ignores)
            v_alu.opcode         := internal_opcode;
            v_alu.imm_data       := instruction(25 downto 10);
            -- 4-bit component write_mask extracted directly from bits [29:26].
            -- Supports any combination of X/Y/Z/W components — same encoding
            -- as the ALU/FPU mask field (bit0=X, bit1=Y, bit2=Z, bit3=W).
            v_alu.write_mask     := instruction(29 downto 26);
            v_alu.rd_addr_local  := instruction(7 downto 4);
            -- WHY rs1_addr_local = rd_addr_local:
            --   LDI_HI loads the upper 16 bits of a register while preserving
            --   the lower 16 bits. The ALU lane must read the CURRENT value of
            --   the destination register to merge the halves. Setting rs1=rd
            --   causes the register file to read the destination's existing data
            --   into op_a, which the ALU then uses for the merge.
            v_alu.rs1_addr_local := instruction(7 downto 4);
            v_alu.wb_mux_sel     := WB_MUX_ALU;
            v_alu.vrf_we         := '1';
            v_alu.prf_we         := '0';
            -- is_load='1' signals the ALU lane to enter LDI decode mode rather
            -- than interpreting op_a/op_b as two register operands.
            v_alu.is_load        := '1';

        elsif inst_type = INST_TYPE_SYS then
            -- ----------------------------------------------------------------
            -- SYSTEM INSTRUCTION MAP
            -- [31:26] Opcode | [25:4] Reserved | [3:0] Type
            -- ----------------------------------------------------------------
            -- WHY route through v_fpu rather than a dedicated SYS record:
            --   warp_unit.vhd's exec_mux uses dec_fpu.opcode as the default
            --   control path. By placing the SYS opcode (FLUSH, RETURN, BREAK,
            --   INT) into v_fpu.opcode, the processor FSM sees it at the
            --   expected location without needing a separate mux input for
            --   system tokens.
            v_fpu.opcode := internal_opcode;
            v_fpu.rs1_addr_local := instruction(17 downto 14);

            -- No register reads or writes are necessary for FLUSH or RETURN:
            -- FLUSH is a pipeline token that carries no data.
            -- RETURN causes the processor FSM to halt; it writes no registers.
            v_fpu.vrf_we := '0';
            v_fpu.prf_we := '0';

        end if;

        -- ====================================================================
        -- ASSIGN VARIABLES TO OUTPUT PORTS
        -- ====================================================================
        fpu_ctrl <= v_fpu;
        red_ctrl <= v_red;
        pc_ctrl  <= v_pc;
        alu_ctrl <= v_alu;

    end process;

end architecture rtl;
