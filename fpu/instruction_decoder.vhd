library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_decoder is
    port (
        instruction : in  word_t;
        fpu_ctrl    : out fpu_ctrl_t;
        red_ctrl    : out red_ctrl_t;
        pc_ctrl     : out pc_ctrl_t
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
    begin
        -- ====================================================================
        -- 1. INITIALIZE VARIABLES WITH SAFE DEFAULTS (Prevents latches)
        -- ====================================================================
        v_fpu.opcode         := OP_NOP;
        v_fpu.rs1_addr_local := "00";
        v_fpu.rs2_addr_local := "00";
        v_fpu.rs3_addr_local := "00";
        v_fpu.rd_addr_local  := "00";
        v_fpu.swiz_sel_a     := ("00", "00", "00", "00");
        v_fpu.swiz_sel_b     := ("11", "10", "01", "00"); -- Pass-through
        v_fpu.swiz_sel_c     := ("11", "10", "01", "00"); -- Pass-through
        v_fpu.write_mask     := "0000";
        v_fpu.wb_mux_sel     := WB_MUX_FPU;
        v_fpu.reg_we         := '0';

        v_red.rs1_addr_local := "00";
        v_red.rs2_addr_local := "00";
        v_red.rd_addr_local  := "00";
        v_red.swiz_sel_a     := ("00", "00", "00", "00");
        v_red.swiz_sel_b     := ("00", "00", "00", "00");
        v_red.red_mask       := "0000";
        v_red.red_mode       := "00";
        v_red.wb_mux_sel     := WB_MUX_RED;
        v_red.reg_we         := '0';

        v_pc.is_jmp          := '0';
        v_pc.is_bra_z        := '0';
        v_pc.is_bra_nz       := '0';
        v_pc.is_bra_div      := '0';
        v_pc.is_ssy          := '0';
        v_pc.is_sync         := '0';
        v_pc.target_addr     := (others => '0');
        v_pc.predicate_sel   := "00";


        -- ====================================================================
        -- 2. DECODE BASED ON INSTRUCTION TYPE
        -- ====================================================================
        if inst_type = INST_TYPE_FPU then
            -- ----------------------------------------------------------------
            -- FPU MATH INSTRUCTION MAP
            -- [31:26] Opcode | [25:22] Mask | [21:20] Dest | [19:18] Src1
            -- [17:16] Src2   | [15:14] Src3 | [13:12] Rsvd | [11:4] Swiz A
            -- ----------------------------------------------------------------
            v_fpu.opcode         := internal_opcode;
            v_fpu.write_mask     := instruction(25 downto 22);
            v_fpu.rd_addr_local  := instruction(21 downto 20);
            v_fpu.rs1_addr_local := instruction(19 downto 18);
            v_fpu.rs2_addr_local := instruction(17 downto 16);
            v_fpu.rs3_addr_local := instruction(15 downto 14);
            
            v_fpu.swiz_sel_a(3)  := instruction(11 downto 10);
            v_fpu.swiz_sel_a(2)  := instruction(9 downto 8);
            v_fpu.swiz_sel_a(1)  := instruction(7 downto 6);
            v_fpu.swiz_sel_a(0)  := instruction(5 downto 4);

            case internal_opcode is
                when OP_FADD | OP_FSUB | OP_FMUL | OP_FMADD | 
                     OP_FRCP | OP_FSQRT | OP_FLOG2 | OP_FEXP2 | 
                     OP_FMIN | OP_FMAX | OP_F2I | OP_I2F |
                     OP_SIN  | OP_COS =>
                    v_fpu.wb_mux_sel := WB_MUX_FPU; 
                    v_fpu.reg_we     := '1';
                    
                when OP_FCMP_LT | OP_FCMP_EQ =>
                    v_fpu.wb_mux_sel := WB_MUX_FPU;
                    v_fpu.reg_we     := '0'; 
                    
                when others => null;
            end case;

        elsif inst_type = INST_TYPE_RED then
            -- ----------------------------------------------------------------
            -- REDUCTION INSTRUCTION MAP
            -- [31:30] Mode | [29:26] Mask | [25:24] Dest   | [23:22] Src1
            -- [21:20] Src2 | [19:12] Swz A| [11:4]  Swz B  | [3:0] Type (0010)
            -- ----------------------------------------------------------------
            v_red.red_mode       := instruction(31 downto 30);
            v_red.red_mask       := instruction(29 downto 26);
            v_red.rd_addr_local  := instruction(25 downto 24);
            v_red.rs1_addr_local := instruction(23 downto 22);
            v_red.rs2_addr_local := instruction(21 downto 20);
            
            v_red.swiz_sel_a(3)  := instruction(19 downto 18);
            v_red.swiz_sel_a(2)  := instruction(17 downto 16);
            v_red.swiz_sel_a(1)  := instruction(15 downto 14);
            v_red.swiz_sel_a(0)  := instruction(13 downto 12);
            
            v_red.swiz_sel_b(3)  := instruction(11 downto 10);
            v_red.swiz_sel_b(2)  := instruction(9 downto 8);
            v_red.swiz_sel_b(1)  := instruction(7 downto 6);
            v_red.swiz_sel_b(0)  := instruction(5 downto 4);

            v_red.wb_mux_sel     := WB_MUX_RED;
            v_red.reg_we         := '1';

        elsif inst_type = INST_TYPE_CTRL then
            -- ----------------------------------------------------------------
            -- SIMT CONTROL INSTRUCTION MAP
            -- [31:26] Opcode | [25:10] Target Address (16b) | [9:8] Pred Sel
            -- ----------------------------------------------------------------
            v_pc.target_addr   := instruction(25 downto 10);
            v_pc.predicate_sel := instruction(9 downto 8);

            case internal_opcode is
                when OP_JMP     => v_pc.is_jmp     := '1';
                when OP_BRA_Z   => v_pc.is_bra_z   := '1';
                when OP_BRA_NZ  => v_pc.is_bra_nz  := '1';
                when OP_BRA_DIV => v_pc.is_bra_div := '1';
                when OP_SSY     => v_pc.is_ssy     := '1';
                when OP_SYNC    => v_pc.is_sync    := '1';
                when others     => null;
            end case;
        end if;

        -- ====================================================================
        -- 3. ASSIGN VARIABLES TO OUTPUT PORTS
        -- ====================================================================
        fpu_ctrl <= v_fpu;
        red_ctrl <= v_red;
        pc_ctrl  <= v_pc;

    end process;

end architecture rtl;
