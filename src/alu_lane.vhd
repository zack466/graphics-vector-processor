-- =============================================================================
-- FILE: alu_lane.vhd
-- COMPONENT: Integer ALU Lane
-- =============================================================================
--
-- In a SIMT processor, each thread lane needs both integer and floating-point
-- execution capability. The ALU lane handles all integer opcodes (IADD, ISUB,
-- IMUL, bitwise, shifts, ICMP comparisons, THREAD_ID, WIDTH, HEIGHT, TIME) and 
-- the immediate-load pseudo-instructions (LDI_LO, LDI_HI). This unit provides
-- those capabilities, and can be used in the same manner as the FPU lanes
-- since all operations are padded to a latency of MAX_FPU_LATENCY.
--
-- Inputs:
--   clk          : System clock. The delay shift-register is clocked on the
--                  rising edge.
--   reset        : Synchronous active-high reset. Flushes all pipeline stages
--                  (valid_pipe and comp_pipe go to zero; result is don't-care).
--
--   opcode       : 6-bit instruction opcode. Decoded combinationally in the
--                  integer ALU process. Must remain stable for one clock cycle;
--                  changes take effect on the next rising edge.
--   valid_in     : Asserted for one cycle when the lane is being issued a new
--                  instruction. Propagates through valid_pipe so valid_out
--                  pulses FPU_MAX_LATENCY cycles later.
--   is_load      : '1' selects the LDI (immediate-load) path, bypassing the
--                  main opcode decode. Prevents LDI from accidentally matching
--                  an integer opcode with the same encoding.
--   imm_data     : 16-bit immediate value carried by LDI_LO / LDI_HI. Only
--                  sampled when is_load='1'.
--
--   op_a         : 32-bit integer source operand A (from the VRF read stage).
--   op_b         : 32-bit integer source operand B (from the VRF read stage).
--
--   thread_id    : 5-bit lane index (0-31) within the current warp. Used only
--                  by THREAD_ID to compute the absolute thread number.
--   warp_offset  : 32-bit warp base address from the CSR. Added to thread_id
--                  to produce the absolute thread ID visible to the shader.
--   frame_width  : 16-bit frame width uniform for WIDTH instruction.
--   frame_height : 16-bit frame height uniform for HEIGHT instruction.
--   time_ms      : 32-bit time uniform for TIME instruction.
--
-- Outputs:
--   result       : 32-bit integer result, valid FPU_MAX_LATENCY cycles after
--                  valid_in. For ICMP instructions this field is undefined;
--                  only comp_flag carries meaningful data.
--   comp_flag    : 1-bit comparison result for ICMP instructions. Routed to
--                  the PRF write port by the writeback controller. For non-ICMP
--                  instructions this will be '0' (safe default).
--   valid_out    : High for one cycle when result and comp_flag are valid.
--                  Aligned with FPU valid_out so the writeback controller can
--                  treat both lanes identically.
--
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity alu_lane is
    port (
        clk          : in  std_logic;   -- system clock
        reset        : in  std_logic;   -- system reset
        
        -- Control
        opcode       : in  std_logic_vector(5 downto 0);    -- opcode from instruction bits
        valid_in     : in  std_logic;                       -- if input instruction is valid
        is_load      : in  std_logic;                       -- is a LDI_LO or LDI_HI instruction
        imm_data     : in  std_logic_vector(15 downto 0);   -- For LDI_LO / LDI_HI
        
        -- Data Inputs (Scalars)
        op_a         : in  word_t;
        op_b         : in  word_t;

        -- Shader Uniforms & Thread ID computation inputs
        thread_id    : in  std_logic_vector(4 downto 0);  -- Current thread index (0-31)
        warp_offset  : in  std_logic_vector(31 downto 0); -- Warp base offset from CSR
        frame_width  : in  std_logic_vector(15 downto 0); -- frame width
        frame_height : in  std_logic_vector(15 downto 0); -- frame height
        time_ms      : in  std_logic_vector(31 downto 0); -- elapsed time (ms)
        
        -- Synchronized Outputs (Arrives exactly FPU_MAX_LATENCY cycles later)
        result       : out word_t;
        comp_flag    : out std_logic; -- Routes to Predicate Register File
        valid_out    : out std_logic  -- result is valid
    );
end entity;

architecture rtl of alu_lane is

    -- FPU_MAX_LATENCY-deep pipeline
    type res_pipe_t is array (1 to FPU_MAX_LATENCY) of word_t;
    signal res_pipe   : res_pipe_t := (others => (others => '0'));
    signal comp_pipe  : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');
    signal valid_pipe : std_logic_vector(FPU_MAX_LATENCY downto 1) := (others => '0');

    -- Combinational evaluation wires. These are NOT registered here; the
    -- pipeline process below registers them at stage 1 on the next clock edge.
    signal raw_res    : word_t;
    signal raw_comp   : std_logic;

begin

    -- ========================================================================
    -- ZERO-LATENCY INTEGER COMBINATIONAL LOGIC
    -- ========================================================================
    process(opcode, op_a, op_b, imm_data, thread_id, warp_offset, frame_width, frame_height, time_ms, is_load)
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

        -- Use bottom 5 bits for shift amount
        shamt := to_integer(b_uns(4 downto 0));

        -- IMUL multiplies two 32-bit values; the product can be up to 64 bits.
        -- We discard the upper 32 bits.
        prod  := a_uns * b_uns;

        -- Safe defaults: pass op_a through and clear comp. This means an
        -- unrecognised opcode silently forwards op_a, which is preferable to
        -- driving X (undefined) into the pipeline and potentially corrupting
        -- a writeback.
        raw_res  <= op_a;
        raw_comp <= '0';

        if is_load = '1' then
            -- The IMM instruction encoding embeds the 4-bit write-mask in
            -- opcode[3:0], so the 6-bit opcode overlaps with integer ALU
            -- opcodes. Using is_load as a priority override ensures LDI
            -- instructions are never misinterpreted as integer ops.
            --
            -- WHY only check opcode[5:4]: bits [3:0] of the opcode carry the
            -- component write-mask (extracted from instruction[29:26] by the
            -- decoder). Only the top 2 bits distinguish LDI_LO ("00") from
            -- LDI_HI ("01"); the mask bits are irrelevant here and must be
            -- masked out to avoid matching failures.
            case opcode(5 downto 4) is
                when "00" =>
                    -- LDI_LO: load immediate into the lower 16 bits, zero-extending.
                    raw_res <= x"0000" & imm_data;
                when "01" =>
                    -- LDI_HI: load immediate into the upper 16 bits, PRESERVING the
                    -- lower 16 bits from op_a. This is the standard 32-bit immediate
                    -- construction idiom: issue LDI_LO first, then LDI_HI.
                    -- op_a carries the current register value (rs1=rd in the decoder)
                    -- so the lower half is not lost.
                    raw_res <= imm_data & op_a(15 downto 0);
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

                -- Compute absolute thread ID: warp_offset + lane index (0-31).
                when OP_THREAD_ID =>
                    raw_res <= std_logic_vector(
                        unsigned(warp_offset) + resize(unsigned(thread_id), 32)
                    );

                -- Shader Uniform: WIDTH
                -- Zero-padded to 32 bits to match the datapath width.
                when OP_WIDTH =>
                    raw_res <= x"0000" & frame_width;
                    
                -- Shader Uniform: HEIGHT
                -- Zero-padded to 32 bits to match the datapath width.
                when OP_HEIGHT =>
                    raw_res <= x"0000" & frame_height;

                -- Shader Uniform: TIME
                -- Returns the elapsed time in milliseconds. Useful for animating
                -- shader effects.
                when OP_TIME =>
                    raw_res <= time_ms;

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
                -- Only valid_pipe and comp_pipe need reset; res_pipe data is
                -- irrelevant while valid is low, so resetting it wastes power.
                valid_pipe <= (others => '0');
                comp_pipe  <= (others => '0');
            else
                -- Inject combinational result into stage 1 on every clock.
                valid_pipe(1) <= valid_in;
                res_pipe(1)   <= raw_res;
                comp_pipe(1)  <= raw_comp;

                -- Shift pipeline down to match FPU latency.
                for i in 2 to FPU_MAX_LATENCY loop
                    valid_pipe(i) <= valid_pipe(i-1);
                    res_pipe(i)   <= res_pipe(i-1);
                    comp_pipe(i)  <= comp_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    -- Pipelined outputs
    result    <= res_pipe(FPU_MAX_LATENCY);
    comp_flag <= comp_pipe(FPU_MAX_LATENCY);
    valid_out <= valid_pipe(FPU_MAX_LATENCY);

end architecture rtl;
