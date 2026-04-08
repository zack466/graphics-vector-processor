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
        pc_ctrl     : out pc_ctrl_t;
        mem_ctrl    : out mem_ctrl_t -- NEW
    );
end entity;

architecture rtl of instruction_decoder is

    signal inst_type       : std_logic_vector(3 downto 0);
    signal internal_opcode : std_logic_vector(5 downto 0);

begin

    inst_type       <= instruction(3 downto 0);
    internal_opcode <= instruction(31 downto 26);

    process(instruction, inst_type, internal_opcode)
        variable v_fpu : fpu_ctrl_t;
        variable v_red : red_ctrl_t;
        variable v_pc  : pc_ctrl_t;
        variable v_alu : alu_ctrl_t;
        variable v_mem : mem_ctrl_t;
    begin
        -- ====================================================================
        -- 1. INITIALIZE VARIABLES WITH SAFE DEFAULTS (Prevents latches)
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

        v_pc.branch_type     := BR_NONE;
        v_pc.target_addr     := (others => '0');
        v_pc.predicate_sel   := "00";
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

        v_mem.is_valid         := '0';
        v_mem.is_store         := '0';
        v_mem.base_addr        := (others => '0');
        v_mem.offset_reg_idx   := "0000";
        v_mem.dest_src_reg_idx := "0000";

        -- ====================================================================
        -- 2. DECODE BASED ON INSTRUCTION TYPE
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
            v_fpu.rs3_addr_local := (others => '0'); -- Only 2-src math for now
            
            v_fpu.cmp_invert     := instruction(6);
            v_fpu.cmp_swap       := instruction(5);
            
            v_fpu.swiz_sel_a     := instruction(9 downto 7);

            case internal_opcode is
                when OP_FADD | OP_FSUB | OP_FMUL | OP_FMADD | 
                     OP_FRCP | OP_FSQRT | OP_FLOG2 | OP_FEXP2 | 
                     OP_FMIN | OP_FMAX | OP_F2I | OP_I2F |
                     OP_SIN  | OP_COS =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU; 
                    v_fpu.vrf_we      := '1';
                    v_fpu.prf_we      := '0';
                    v_fpu.is_logic_op := '0';
                    
                when OP_FCMP_LT | OP_FCMP_EQ =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '0'; 
                    v_fpu.prf_we      := '1';
                    v_fpu.is_logic_op := '0';
                    
                when OP_PAND | OP_POR | OP_PXOR =>
                    v_fpu.wb_mux_sel  := WB_MUX_FPU;
                    v_fpu.vrf_we      := '0'; 
                    v_fpu.prf_we      := '1';
                    v_fpu.is_logic_op := '1';

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
            v_red.red_mode       := instruction(31 downto 30);
            v_red.red_mask       := instruction(29 downto 26);
            v_red.rd_addr_local  := instruction(25 downto 22);
            v_red.rs1_addr_local := instruction(21 downto 18);
            v_red.rs2_addr_local := instruction(17 downto 14);
            
            v_red.swiz_sel_a     := instruction(13 downto 11);
            v_red.swiz_sel_b     := instruction(10 downto 8);

            v_red.wb_mux_sel     := WB_MUX_RED;
            v_red.vrf_we         := '1';

        elsif inst_type = INST_TYPE_CTRL then
            -- ----------------------------------------------------------------
            -- SIMT CONTROL INSTRUCTION MAP
            -- [31:26] Opcode | [25:24] Reserved | [23:8] Target (16b) 
            -- [7:6] P_Sel | [5:4] P_Mod | [3:0] Type
            -- ----------------------------------------------------------------
            v_pc.target_addr   := instruction(23 downto 8);
            v_pc.predicate_sel := instruction(7 downto 6);
            v_pc.predicate_mod := instruction(5 downto 4);

            case internal_opcode is
                when OP_JMP     => v_pc.branch_type := BR_JMP;
                when OP_BRA_Z   => v_pc.branch_type := BR_BRA_Z;
                when OP_BRA_NZ  => v_pc.branch_type := BR_BRA_NZ;
                when OP_BRA_DIV => v_pc.branch_type := BR_BRA_DIV;
                when OP_SSY     => v_pc.branch_type := BR_SSY;
                when OP_SYNC    => v_pc.branch_type := BR_SYNC;
                when others     => v_pc.branch_type := BR_NONE;
            end case;

        elsif inst_type = INST_TYPE_ALU then
            -- ----------------------------------------------------------------
            -- INTEGER ALU INSTRUCTION MAP
            -- [31:26] Opcode | [25:22] Mask | [21:18] Dest | [17:14] Src1
            -- [13:10] Src2   | [9:7] Swiz A | [6:4] Reserved | [3:0] Type
            -- ----------------------------------------------------------------
            v_alu.opcode         := internal_opcode;
            v_alu.write_mask     := instruction(25 downto 22);
            v_alu.rd_addr_local  := instruction(21 downto 18);
            v_alu.rs1_addr_local := instruction(17 downto 14);
            v_alu.rs2_addr_local := instruction(13 downto 10);
            
            v_alu.swiz_sel_a     := instruction(9 downto 7);
            v_alu.swiz_sel_b     := SWIZ_PASS;

            v_alu.wb_mux_sel     := WB_MUX_ALU;

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
            -- [31:26] Opcode | [25:10] Imm16 | [9] Full Mask | [8:4] Dest | [3:0] Type
            -- ----------------------------------------------------------------
            v_alu.opcode         := internal_opcode;
            v_alu.imm_data       := instruction(25 downto 10);
            v_alu.write_mask     := instruction(9) & instruction(9) & instruction(9) & instruction(9);
            v_alu.rd_addr_local  := instruction(7 downto 4);
            v_alu.rs1_addr_local := instruction(7 downto 4);
            v_alu.wb_mux_sel     := WB_MUX_ALU;
            v_alu.vrf_we         := '1';
            v_alu.prf_we         := '0';
            v_alu.is_load        := '1';

        elsif inst_type = INST_TYPE_MEM then
            -- ----------------------------------------------------------------
            -- MEMORY INSTRUCTION MAP (Routes to Scatter/Gather Unit)
            -- [31:26] Opcode | [25:12] Base Addr Imm (14b) | [11:8] Offset Reg
            -- [7:4] Dest/Src Reg | [3:0] Type
            -- ----------------------------------------------------------------
            v_mem.is_valid         := '1';
            v_mem.base_addr        := "00" & instruction(25 downto 12);
            v_mem.offset_reg_idx   := instruction(11 downto 8);
            v_mem.dest_src_reg_idx := instruction(7 downto 4);

            if internal_opcode = OP_STORE then
                v_mem.is_store := '1';
            else
                v_mem.is_store := '0';
            end if;

        elsif inst_type = INST_TYPE_SYS then
            -- ----------------------------------------------------------------
            -- SYSTEM INSTRUCTION MAP
            -- [31:26] Opcode | [25:4] Reserved | [3:0] Type
            -- ----------------------------------------------------------------
            -- We pass the opcode through v_fpu because the top-level 
            -- exec_mux_ctrl uses v_fpu as the default route. 
            v_fpu.opcode := internal_opcode;
            
            -- No register reads or writes are necessary for FLUSH or RETURN
            v_fpu.vrf_we := '0';
            v_fpu.prf_we := '0';

        end if;

        -- ====================================================================
        -- 3. ASSIGN VARIABLES TO OUTPUT PORTS
        -- ====================================================================
        fpu_ctrl <= v_fpu;
        red_ctrl <= v_red;
        pc_ctrl  <= v_pc;
        alu_ctrl <= v_alu;
        mem_ctrl <= v_mem;

    end process;

end architecture rtl;
