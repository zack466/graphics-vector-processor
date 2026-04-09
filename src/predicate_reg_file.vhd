-- =============================================================================
-- predicate_reg_file.vhd — Per-Thread Predicate Register File (PRF)
-- =============================================================================
--
-- WHY THIS COMPONENT EXISTS:
--   In a SIMT (Single Instruction Multiple Threads) GPU, threads within a warp
--   execute in lockstep but may take different conditional branches depending on
--   their data. The mechanism for this is the execution mask: a per-thread bit
--   that says whether a given thread is "active" for the current instruction.
--   The PRF is the storage backing that mask. Comparison instructions (ICMP_EQ,
--   FCMP_LT, etc.) write their boolean results here; branch instructions
--   (BRA_DIV) read the PRF to reconstruct the execution mask and decide how to
--   split the warp across divergent paths.
--
--   Each predicate register stores 4 bits — one per vector component (X, Y, Z,
--   W/A). This mirrors the 4-wide VRF (Vector Register File) and lets a single
--   comparison gate per-component execution independently if needed.
--
-- ADDRESS SPACE:
--   Address = { thread_id[4:0], pred_reg[3:0] }  (9-bit, 512 entries total)
--     - bits [8:4] = thread index (0-31, one warp of 32 threads)
--     - bits [3:0] = predicate register index (p0..p15)
--   The ADDR_WIDTH generic defaults to 9 to match this layout. A narrower width
--   (e.g. 7) can be used in simulation to save memory.
--
-- HOW TO USE:
--   1. Connect rs1_addr / rs2_addr to the swizzle network's predicate source
--      addresses. rs1_data / rs2_data are combinational — valid with zero clock
--      delay — so the swizzle network can forward them directly into the FPU
--      lane for PAND/POR/PXOR without a pipeline stall.
--   2. Connect wr_addr / wr_data / we / wr_mask to the writeback controller.
--      The writeback controller asserts we exactly FPU_MAX_LATENCY cycles after
--      an ICMP or FCMP instruction is issued, when the comparison result arrives
--      at the pipeline tail. wr_mask enables per-component writeback so that a
--      scalar compare (e.g. comparing only the X component) does not clobber
--      the Y/Z/W predicate bits of the same register.
--   3. Connect ifu_pred_sel / ifu_pred_mod / ifu_mask_out to the IFU
--      (Instruction Fetch Unit). The IFU reads all 32 threads' copies of the
--      selected predicate register simultaneously during fetch/decode to build
--      the 32-bit exec_mask for BRA_DIV. This path must be combinational
--      because the IFU cannot afford a pipeline bubble every branch.
--
-- PORT DESCRIPTIONS:
--   clk          : System clock. Only the write port is synchronous to this.
--   reset        : Synchronous active-high reset. Clears all 512 PRF entries.
--
--   rs1_addr     : ADDR_WIDTH-bit read address for source operand 1.
--                  Encoded as {thread_id, pred_reg_index}.
--   rs2_addr     : ADDR_WIDTH-bit read address for source operand 2.
--   rs1_data     : 4-bit combinational read result (X,Y,Z,W bits of rs1 entry).
--   rs2_data     : 4-bit combinational read result (X,Y,Z,W bits of rs2 entry).
--
--   wr_addr      : ADDR_WIDTH-bit write address for writeback.
--   wr_data      : 4-bit data to write (one bit per vector component).
--   we           : Write enable, synchronous, active-high.
--   wr_mask      : 4-bit byte-enable for the write. Bit i=1 allows writing
--                  component i. Allows ICMP on a single component without
--                  disturbing the other three component predicates.
--
--   ifu_pred_sel : 4-bit index selecting which of the 16 predicate registers
--                  (p0..p15) to collapse across all 32 threads.
--                  NOTE: current port is 2-bit (p0..p3); widen if >4 pred regs
--                  are needed.
--   ifu_pred_mod : 2-bit modifier controlling how the 4 component bits are
--                  reduced to a single per-thread boolean:
--                    PRED_MOD_ANY (00) : bit_val = X OR Y OR Z OR W
--                      — thread is active if ANY component passed the compare.
--                    PRED_MOD_ALL (01) : bit_val = X AND Y AND Z AND W
--                      — thread is active only if ALL components passed.
--                    PRED_MOD_X   (10) : bit_val = X component only (bit 0).
--                      — scalar compare on the X lane gates the whole thread.
--                    PRED_MOD_A   (11) : bit_val = W/Alpha component (bit 3).
--                      — useful for alpha-test style culling.
--   ifu_mask_out : 32-bit output, one bit per thread. Bit i is the collapsed
--                  predicate value for thread i. Used directly as exec_mask
--                  by BRA_DIV to split the warp.
--
-- TIMING / LATENCY:
--   Write port  : 1 clock cycle latency (data visible on the cycle after we).
--   Read ports  : 0 clock cycles (purely combinational / asynchronous).
--   IFU port    : 0 clock cycles (purely combinational / asynchronous).
--   Reset       : 1 clock cycle to clear all entries (synchronous).
--
-- IMPORTANT: Because the read ports are asynchronous, the caller must ensure
--   that wr_addr does not alias rs1_addr or rs2_addr during the write cycle,
--   or accept read-during-write undefined behaviour (read-before-write semantic
--   on most FPGA block-RAM primitives when both address the same location).
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity predicate_reg_file is
    generic (
        ADDR_WIDTH : integer := 7 -- Default: 5-bit thread + 2-bit pred reg
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;

        -- ==========================================
        -- FPU MATH PORTS (Scalar 4-bit access)
        -- ==========================================
        rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs1_data     : out std_logic_vector(3 downto 0);
        rs2_data     : out std_logic_vector(3 downto 0);

        wr_addr      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data      : in  std_logic_vector(3 downto 0);
        we           : in  std_logic;
        wr_mask      : in  std_logic_vector(3 downto 0); -- Allows partial X,Y,Z,A updates

        -- ==========================================
        -- IFU PORT (Warp-Wide 32-bit collapse)
        -- ==========================================
        ifu_pred_sel : in  std_logic_vector(1 downto 0); -- Select p0, p1, p2, or p3
        ifu_pred_mod : in  std_logic_vector(1 downto 0); -- ANY, ALL, X, A modifiers
        ifu_mask_out : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of predicate_reg_file is

    -- 2**ADDR_WIDTH entries (e.g. ADDR_WIDTH=9: 512 entries = 32 threads * 16 regs).
    -- Using an explicit array type rather than a block-RAM primitive lets the
    -- synthesiser choose the right memory structure based on read-port count:
    -- two async read ports (rs1/rs2) + one 32-wide async IFU read generally
    -- forces distributed LUT-RAM rather than block-RAM, which is fine because
    -- the PRF is small (512 * 4 bits = 256 bytes) and needs zero-latency reads.
    type prf_t is array(0 to 2**ADDR_WIDTH - 1) of std_logic_vector(3 downto 0);
    signal prf : prf_t := (others => "0000");

begin

    -- ========================================================================
    -- SYNCHRONOUS WRITE PORT
    -- ========================================================================
    -- WHY synchronous: writeback timing is controlled by the FPU_MAX_LATENCY
    -- pipeline in the writeback controller, so the PRF write can be clocked
    -- without any handshake complexity. The write arrives predictably on the
    -- cycle after the pipeline drain.
    --
    -- WHY per-bit mask instead of a byte-enable: ICMP instructions may target
    -- only one of the four XYZW slots within a predicate register (e.g. an
    -- instruction that only operates on the X component). The wr_mask prevents
    -- a single-component comparison from corrupting the Y, Z, or W predicate
    -- bits that may belong to a different logical comparison. Each bit of
    -- wr_mask corresponds to the matching component index (0=X, 1=Y, 2=Z, 3=W).
    process(clk)
        variable w_idx : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                prf <= (others => "0000");
            elsif we = '1' then
                w_idx := to_integer(unsigned(wr_addr));
                if wr_mask(0) = '1' then prf(w_idx)(0) <= wr_data(0); end if;
                if wr_mask(1) = '1' then prf(w_idx)(1) <= wr_data(1); end if;
                if wr_mask(2) = '1' then prf(w_idx)(2) <= wr_data(2); end if;
                if wr_mask(3) = '1' then prf(w_idx)(3) <= wr_data(3); end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- ASYNCHRONOUS READ PORTS (For FPU Logic Ops)
    -- ========================================================================
    -- WHY asynchronous: the swizzle network assembles operands for the FPU lane
    -- in the same cycle the instruction is dispatched. Registering these reads
    -- would add a pipeline bubble before every PAND/POR/PXOR, requiring the
    -- issue logic to stall — unacceptable for a fixed-throughput SIMT pipeline.
    -- The combinational path length here is short (address decode + SRAM read),
    -- so it fits within a clock period at typical FPGA frequencies.
    rs1_data <= prf(to_integer(unsigned(rs1_addr)));
    rs2_data <= prf(to_integer(unsigned(rs2_addr)));

    -- ========================================================================
    -- ASYNCHRONOUS IFU COLLAPSE PORT
    -- ========================================================================
    -- WHY asynchronous: BRA_DIV is decoded in the IFU's fetch/decode phase.
    -- If the exec_mask were registered here, the IFU would need an extra cycle
    -- to wait for the mask — potentially misaligning the branch with the warp
    -- scheduler's divergence bookkeeping. Keeping it combinational means the
    -- IFU can compute the new exec_mask in the same cycle it decodes BRA_DIV.
    --
    -- WHY loop over 32 threads: we need one bit per thread in the warp. The
    -- loop generates 32 independent reads of the same predicate register index
    -- across all thread slots, which the synthesiser expands into 32 parallel
    -- address computations into the distributed LUT-RAM.
    process(ifu_pred_sel, ifu_pred_mod, prf)
        variable p_val   : std_logic_vector(3 downto 0);
        variable bit_val : std_logic;
        variable idx     : integer;
    begin
        for i in 0 to 31 loop
            -- Address layout: thread i's predicate register j lives at
            --   addr = i * (2^(ADDR_WIDTH-5)) + j
            -- The stride (2^(ADDR_WIDTH-5)) accounts for the pred_reg field
            -- width so that each thread's predicate registers are contiguous
            -- and do not overlap between threads regardless of ADDR_WIDTH.
            idx := (i * (2**(ADDR_WIDTH-5))) + to_integer(unsigned(ifu_pred_sel));
            p_val := prf(idx);

            -- Apply the modifier to collapse the 4-bit vector to a 1-bit truth.
            -- WHY four modes: different shader patterns need different semantics:
            --   ANY  — a thread is active if at least one component passed (e.g.
            --           "if any of XYZW satisfy the condition, keep this thread").
            --   ALL  — a thread is active only when every component passed (e.g.
            --           "cull a triangle only when all three vertices are behind").
            --   X    — scalar path; only the X-lane result gates the thread. Used
            --           when the comparison was intentionally scalar.
            --   A    — alpha/W-component only; useful for alpha-test culling where
            --           only the W channel carries the opacity predicate.
            case ifu_pred_mod is
                when PRED_MOD_ANY => bit_val := p_val(3) or p_val(2) or p_val(1) or p_val(0);
                when PRED_MOD_ALL => bit_val := p_val(3) and p_val(2) and p_val(1) and p_val(0);
                when PRED_MOD_X   => bit_val := p_val(0);
                when PRED_MOD_A   => bit_val := p_val(3);
                when others       => bit_val := '0';
            end case;

            ifu_mask_out(i) <= bit_val;
        end loop;
    end process;

end architecture rtl;
