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
-- MEMORY ARCHITECTURE:
--   This design uses two strategies to map efficiently onto M10K block RAMs:
--
--   1. FPU READ PORTS (rs1/rs2): Two M10K replicas, one per read port.
--      Each replica is split into four 1-bit-wide arrays (one per XYZW
--      component) so that the per-bit wr_mask can gate individual writes
--      without requiring a read-modify-write cycle, which would prevent M10K
--      inference.  The ramstyle "M10K" attribute forces block RAM placement.
--
--   2. IFU PORT (ifu_mask_out): A separate register-based shadow array that
--      mirrors every PRF write.  The IFU collapse loop reads all 32 threads'
--      entries simultaneously, which requires 32 concurrent reads of different
--      addresses — impossible from a single M10K read port. Storing the shadow
--      in flip-flops (ramstyle "logic") allows arbitrary parallel reads as
--      simple mux operations, at the cost of ~2^ADDR_WIDTH × 4 flip-flops
--      (~512 FFs for ADDR_WIDTH=7, ~2048 FFs for ADDR_WIDTH=9).
--
-- TIMING / LATENCY:
--   Write port  : 1 clock cycle latency (data visible on the cycle after we).
--   FPU ports   : 1 clock cycle (registered M10K read).
--                 IMPORTANT: unlike the previous async implementation, the
--                 caller MUST NOT register prf_rs1_data/prf_rs2_data again
--                 before using them.  execution_unit.vhd feeds these directly
--                 into the swizzle network at S1 alongside vrf_rs*_data (which
--                 also has 1-cycle VRF M10K latency), keeping both aligned.
--   IFU port    : 0 clock cycles (combinational from shadow registers).
--
-- PORT DESCRIPTIONS:
--   clk          : System clock.
--   reset        : Unused (M10K contents initialise to zero; shadow also zero).
--
--   rs1_addr     : ADDR_WIDTH-bit read address for source operand 1.
--   rs2_addr     : ADDR_WIDTH-bit read address for source operand 2.
--   rs1_data     : 4-bit registered read result (available 1 cycle after addr).
--   rs2_data     : 4-bit registered read result.
--
--   wr_addr      : ADDR_WIDTH-bit write address.
--   wr_data      : 4-bit data to write (one bit per vector component).
--   we           : Write enable, synchronous, active-high.
--   wr_mask      : 4-bit byte-enable. Bit i=1 writes component i.
--
--   ifu_pred_sel : 4-bit index selecting which predicate register (p0..p15)
--                  to collapse across all 32 threads.
--   ifu_pred_mod : 2-bit modifier (PRED_MOD_ANY/ALL/X/A) controlling how the
--                  4 component bits reduce to a single per-thread boolean.
--   ifu_mask_out : 32-bit output, one bit per thread, used as exec_mask by
--                  BRA_DIV. Combinational (zero-latency, from shadow).
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
        -- FPU MATH PORTS (1-cycle registered reads)
        -- ==========================================
        rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs1_data     : out std_logic_vector(3 downto 0); -- valid 1 cycle after rs1_addr
        rs2_data     : out std_logic_vector(3 downto 0); -- valid 1 cycle after rs2_addr

        wr_addr      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data      : in  std_logic_vector(3 downto 0);
        we           : in  std_logic;
        wr_mask      : in  std_logic_vector(3 downto 0); -- per-component write enable

        -- ==========================================
        -- IFU PORT (combinational, from shadow)
        -- ==========================================
        ifu_pred_sel : in  std_logic_vector(3 downto 0); -- select p0..p15
        ifu_pred_mod : in  std_logic_vector(1 downto 0); -- ANY, ALL, X, A modifiers
        ifu_mask_out : out std_logic_vector(31 downto 0) -- one bit per thread, exec_mask
    );
end entity;

architecture rtl of predicate_reg_file is

    -- ========================================================================
    -- M10K REPLICAS FOR FPU READ PORTS
    -- ========================================================================
    -- Split into 1-bit-wide component arrays so Quartus can infer M10K blocks
    -- with individually gated write enables (matching wr_mask bits).
    -- Two replicas allow rs1 and rs2 to read different addresses simultaneously.
    type prf_bit_t is array(0 to 2**ADDR_WIDTH - 1) of std_logic;

    signal prf1_x, prf1_y, prf1_z, prf1_w : prf_bit_t := (others => '0'); -- replica 1 → rs1_data
    signal prf2_x, prf2_y, prf2_z, prf2_w : prf_bit_t := (others => '0'); -- replica 2 → rs2_data

    attribute ramstyle : string;
    attribute ramstyle of prf1_x, prf1_y, prf1_z, prf1_w : signal is "M10K";
    attribute ramstyle of prf2_x, prf2_y, prf2_z, prf2_w : signal is "M10K";

    -- ========================================================================
    -- IFU SHADOW (register-based, supports 32-wide parallel combinational read)
    -- ========================================================================
    -- Maintained as flip-flops (ramstyle "logic") so all 32 thread entries for
    -- a given predicate register can be read in a single combinational pass.
    -- Updated synchronously on every PRF write (mirrors the M10K replicas).
    type prf_shadow_t is array(0 to 2**ADDR_WIDTH - 1) of std_logic_vector(3 downto 0);
    signal prf_shadow : prf_shadow_t := (others => "0000");
    attribute ramstyle of prf_shadow : signal is "logic";

begin

    -- ========================================================================
    -- SYNCHRONOUS WRITE + REGISTERED READ PROCESS
    -- ========================================================================
    -- Follows the standard Altera/Intel M10K inference template: write and read
    -- in the same clocked process, with the read address sampled on the rising
    -- edge and data available on the next cycle.
    --
    -- WHY component-split write enables: M10K blocks do not support arbitrary
    -- sub-word byte-enable granularity via a single write. Splitting the 4-bit
    -- entry into four 1-bit arrays gives each component its own write enable,
    -- matching the wr_mask semantics without read-modify-write overhead.
    process(clk)
        variable w_idx  : integer;
        variable r1_idx : integer;
        variable r2_idx : integer;
    begin
        if rising_edge(clk) then
            w_idx  := to_integer(unsigned(wr_addr));
            r1_idx := to_integer(unsigned(rs1_addr));
            r2_idx := to_integer(unsigned(rs2_addr));

            -- --- WRITE to M10K replicas (fan-out to both) ---
            if we = '1' then
                if wr_mask(0) = '1' then
                    prf1_x(w_idx) <= wr_data(0);
                    prf2_x(w_idx) <= wr_data(0);
                end if;
                if wr_mask(1) = '1' then
                    prf1_y(w_idx) <= wr_data(1);
                    prf2_y(w_idx) <= wr_data(1);
                end if;
                if wr_mask(2) = '1' then
                    prf1_z(w_idx) <= wr_data(2);
                    prf2_z(w_idx) <= wr_data(2);
                end if;
                if wr_mask(3) = '1' then
                    prf1_w(w_idx) <= wr_data(3);
                    prf2_w(w_idx) <= wr_data(3);
                end if;
            end if;

            -- --- WRITE to IFU shadow (same data, same address) ---
            if we = '1' then
                if wr_mask(0) = '1' then prf_shadow(w_idx)(0) <= wr_data(0); end if;
                if wr_mask(1) = '1' then prf_shadow(w_idx)(1) <= wr_data(1); end if;
                if wr_mask(2) = '1' then prf_shadow(w_idx)(2) <= wr_data(2); end if;
                if wr_mask(3) = '1' then prf_shadow(w_idx)(3) <= wr_data(3); end if;
            end if;

            -- --- REGISTERED READS from M10K replicas ---
            rs1_data(0) <= prf1_x(r1_idx);
            rs1_data(1) <= prf1_y(r1_idx);
            rs1_data(2) <= prf1_z(r1_idx);
            rs1_data(3) <= prf1_w(r1_idx);

            rs2_data(0) <= prf2_x(r2_idx);
            rs2_data(1) <= prf2_y(r2_idx);
            rs2_data(2) <= prf2_z(r2_idx);
            rs2_data(3) <= prf2_w(r2_idx);
        end if;
    end process;

    -- ========================================================================
    -- COMBINATIONAL IFU COLLAPSE (from shadow registers)
    -- ========================================================================
    -- Reads all 32 threads' copies of ifu_pred_sel simultaneously from the
    -- flip-flop shadow and reduces each to a single bit via ifu_pred_mod.
    -- Zero-latency because shadow is register-based, not block RAM.
    process(ifu_pred_sel, ifu_pred_mod, prf_shadow)
        variable p_val   : std_logic_vector(3 downto 0);
        variable bit_val : std_logic;
        variable idx     : integer;
    begin
        for i in 0 to 31 loop
            -- Address layout: thread i, predicate register ifu_pred_sel.
            -- Stride = 2^(ADDR_WIDTH-5) so each thread's pred regs are contiguous.
            idx := (i * (2**(ADDR_WIDTH-5))) + to_integer(unsigned(ifu_pred_sel));
            p_val := prf_shadow(idx);

            case ifu_pred_mod is
                when PRED_MOD_ANY => bit_val := p_val(3) or  p_val(2) or  p_val(1) or  p_val(0);
                when PRED_MOD_ALL => bit_val := p_val(3) and p_val(2) and p_val(1) and p_val(0);
                when PRED_MOD_X   => bit_val := p_val(0);
                when PRED_MOD_A   => bit_val := p_val(3);
                when others       => bit_val := '0';
            end case;

            ifu_mask_out(i) <= bit_val;
        end loop;
    end process;

end architecture rtl;
