-- =============================================================================
-- FILE: predicate_reg_file.vhd
-- COMPONENT: Predicate Register File
-- =============================================================================
--
-- Stores per-thread boolean comparison results used to drive the SIMT execution
-- mask. Each entry holds 4 bits (one per vector component X, Y, Z, W), mirroring
-- the 4-wide VRF layout.
--
-- Inputs:
--   clk          : System clock.
--   reset        : System reset.
--   rs1_addr     : Read address for source operand 1.
--   rs2_addr     : Read address for source operand 2.
--   wr_addr      : Write address.
--   wr_data      : 4-bit write data (one bit per vector component).
--   we           : Write enable, synchronous, active-high.
--   wr_mask      : 4-bit per-component write enable.
--   ifu_pred_sel : Selects which predicate register (p0..p15) to collapse.
--   ifu_pred_mod : Reduction mode (PRED_MOD_ANY/ALL/X/A).
--
-- Outputs:
--   rs1_data     : 4-bit registered read result (1 cycle after rs1_addr).
--   rs2_data     : 4-bit registered read result (1 cycle after rs2_addr).
--   ifu_mask_out : 32-bit exec_mask output, one bit per thread. Combinational.
--
-- ADDRESS SPACE:
--   Address = { thread_id[4:0], pred_reg[3:0] }  (9-bit, 512 entries total)
--     - bits [8:4] = thread index (0-31)
--     - bits [3:0] = predicate register index (p0..p15)
--
-- MEMORY ARCHITECTURE:
--   FPU ports  (rs1/rs2): Two M10K replicas, each split into four 1-bit-wide
--                          component arrays to support per-bit wr_mask without
--                          a read-modify-write cycle.
--   IFU port (ifu_mask_out): Register-based shadow array mirroring every PRF
--                             write, allowing 32 concurrent combinational reads.
--
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

        -- FPU MATH PORTS (1-cycle registered reads)
        rs1_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs2_addr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        rs1_data     : out std_logic_vector(3 downto 0);
        rs2_data     : out std_logic_vector(3 downto 0);

        wr_addr      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        wr_data      : in  std_logic_vector(3 downto 0);
        we           : in  std_logic;
        wr_mask      : in  std_logic_vector(3 downto 0);

        -- IFU PORT (combinational, from shadow)
        ifu_pred_sel : in  std_logic_vector(3 downto 0);
        ifu_pred_mod : in  std_logic_vector(1 downto 0);
        ifu_mask_out : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of predicate_reg_file is

    -- ========================================================================
    -- M10K REPLICAS FOR FPU READ PORTS
    -- ========================================================================
    -- Two replicas allow rs1 and rs2 to read different addresses simultaneously.
    -- Split into 1-bit component arrays so wr_mask can gate writes per-component.
    type prf_bit_t is array(0 to 2**ADDR_WIDTH - 1) of std_logic;

    signal prf1_x, prf1_y, prf1_z, prf1_w : prf_bit_t := (others => '0'); -- replica 1 → rs1_data
    signal prf2_x, prf2_y, prf2_z, prf2_w : prf_bit_t := (others => '0'); -- replica 2 → rs2_data

    attribute ramstyle : string;
    attribute ramstyle of prf1_x, prf1_y, prf1_z, prf1_w : signal is "M10K";
    attribute ramstyle of prf2_x, prf2_y, prf2_z, prf2_w : signal is "M10K";

    -- ========================================================================
    -- IFU SHADOW (register-based, supports 32-wide parallel combinational read)
    -- ========================================================================
    -- Stored as flip-flops so all 32 thread entries for a given predicate register
    -- can be read in a single combinational pass. Mirrors every PRF write.
    type prf_shadow_t is array(0 to 2**ADDR_WIDTH - 1) of std_logic_vector(3 downto 0);
    signal prf_shadow : prf_shadow_t := (others => "0000");
    attribute ramstyle of prf_shadow : signal is "logic";

begin

    -- ========================================================================
    -- SYNCHRONOUS WRITE + REGISTERED READ
    -- ========================================================================
    process(clk)
        variable w_idx  : integer;
        variable r1_idx : integer;
        variable r2_idx : integer;
    begin
        if rising_edge(clk) then
            w_idx  := to_integer(unsigned(wr_addr));
            r1_idx := to_integer(unsigned(rs1_addr));
            r2_idx := to_integer(unsigned(rs2_addr));

            -- Write to M10K replicas (fan-out to both)
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

            -- Write to IFU shadow
            if we = '1' then
                if wr_mask(0) = '1' then prf_shadow(w_idx)(0) <= wr_data(0); end if;
                if wr_mask(1) = '1' then prf_shadow(w_idx)(1) <= wr_data(1); end if;
                if wr_mask(2) = '1' then prf_shadow(w_idx)(2) <= wr_data(2); end if;
                if wr_mask(3) = '1' then prf_shadow(w_idx)(3) <= wr_data(3); end if;
            end if;

            -- Registered reads from M10K replicas
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
    -- Reads all 32 threads' copies of ifu_pred_sel and reduces each to a single
    -- bit via ifu_pred_mod. Zero-latency because shadow is register-based.
    process(ifu_pred_sel, ifu_pred_mod, prf_shadow)
        variable p_val   : std_logic_vector(3 downto 0);
        variable bit_val : std_logic;
        variable idx     : integer;
    begin
        for i in 0 to 31 loop
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
