-- ============================================================================
-- FILE: writeback_controller.vhd
-- COMPONENT: Writeback Delay Pipeline
-- ============================================================================
--
-- This unit simply takes in the destination register addresses and write masks
-- of each instruction input into the fpu/alu lanes, and pipelines these values
-- so that the final result can be written back into the correct register after
-- waiting for FPU_MAX_LATENCY clocks.
--
-- Inputs:
-- - clk         : System clock.  All registers are rising-edge triggered.
-- - reset       : Synchronous active-high reset.
--                 state from FPGA initialisation.
-- - iss_rd_addr : 9-bit global destination address {thread_id[4:0], reg[3:0]}
--                 presented by the instruction issuer.  Injected at pipeline
--                 stage 0 each cycle.
-- - iss_mask    : 4-bit XYZW component write mask from the instruction word.
--                 Allows partial writes (e.g., .xyz only) to a vector register.
-- - iss_wb_mux  : 2-bit mux selector that routes one of {FPU result, reduction
--                 unit result, ALU result} to the register-file write data bus.
-- - iss_vrf_we  : Vector register file write-enable from the issuer.  Must be '0'
--                 for instructions that do not write the VRF (stores, predicates,
--                 NOPs).
-- - iss_prf_we  : Predicate register file write-enable from the issuer.  High only
--                 for compare/test instructions that produce a boolean result.
--
-- Outputs:
-- - wb_rd_addr  : Delayed rd_addr, aligned with execution-unit result.
-- - wb_mask     : Delayed write mask, aligned with execution-unit result.
-- - wb_mux_sel  : Delayed mux selector, aligned with execution-unit result.
-- - wb_vrf_we   : Delayed VRF write-enable — gates the actual VRF write port.
-- - wb_prf_we   : Delayed PRF write-enable — gates the actual PRF write port.
--
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity writeback_controller is
    port (
        clk         : in  std_logic;    -- system clock
        reset       : in  std_logic;    -- system reset

        -- ==========================================
        -- STAGE 0/1 INPUTS (From Instruction Issuer)
        -- ==========================================
        iss_rd_addr : in  std_logic_vector(8 downto 0);     -- destination register
        iss_mask    : in  std_logic_vector(3 downto 0);     -- destination write mask
        iss_wb_mux  : in  std_logic_vector(1 downto 0);     -- which unit to writeback from
        iss_vrf_we  : in  std_logic;                        -- vector register write enable
        iss_prf_we  : in  std_logic;                        -- predicate register write enable

        -- ==========================================
        -- STAGE N OUTPUTS (To Register Files)
        -- ==========================================
        wb_rd_addr  : out std_logic_vector(8 downto 0);     -- destination register
        wb_mask     : out std_logic_vector(3 downto 0);     -- destination write mask
        wb_mux_sel  : out std_logic_vector(1 downto 0);     -- which unit to writeback from
        wb_vrf_we   : out std_logic;                        -- vector register write enable
        wb_prf_we   : out std_logic                         -- predicate register write enable
    );
end entity;

architecture rtl of writeback_controller is

    -- ========================================================================
    -- PIPELINE TYPES (Derived directly from processor_constants_pkg)
    -- ========================================================================
    -- Array bounds are (1 to FPU_MAX_LATENCY), giving FPU_MAX_LATENCY stages.
    -- Index 1 is the input register (loaded from iss_* each cycle).
    -- Index FPU_MAX_LATENCY is the output register (tapped to wb_* ports).
    type addr_pipe_t is array (1 to FPU_MAX_LATENCY) of std_logic_vector(8 downto 0);
    type mask_pipe_t is array (1 to FPU_MAX_LATENCY) of std_logic_vector(3 downto 0);
    type mux_pipe_t  is array (1 to FPU_MAX_LATENCY) of std_logic_vector(1 downto 0);
    type we_pipe_t   is array (1 to FPU_MAX_LATENCY) of std_logic;

    -- ========================================================================
    -- SHIFT REGISTERS
    -- ========================================================================
    signal rd_addr_pipe : addr_pipe_t := (others => (others => '0'));
    signal mask_pipe    : mask_pipe_t := (others => "0000");
    signal mux_pipe     : mux_pipe_t  := (others => "00");
    signal vrf_we_pipe  : we_pipe_t   := (others => '0');
    signal prf_we_pipe  : we_pipe_t   := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                vrf_we_pipe <= (others => '0');
                prf_we_pipe <= (others => '0');
            else
                -- Inject new instruction metadata at the front of the pipeline.
                rd_addr_pipe(1) <= iss_rd_addr;
                mask_pipe(1)    <= iss_mask;
                mux_pipe(1)     <= iss_wb_mux;
                vrf_we_pipe(1)  <= iss_vrf_we;
                prf_we_pipe(1)  <= iss_prf_we;

                -- Unconditionally shift the pipeline to match FPU math progression.
                for i in 2 to FPU_MAX_LATENCY loop
                    rd_addr_pipe(i) <= rd_addr_pipe(i-1);
                    mask_pipe(i)    <= mask_pipe(i-1);
                    mux_pipe(i)     <= mux_pipe(i-1);
                    vrf_we_pipe(i)  <= vrf_we_pipe(i-1);
                    prf_we_pipe(i)  <= prf_we_pipe(i-1);
                end loop;
            end if;
        end if;
    end process;

    -- The last stage of each shift register produces signals that are delayed
    -- by exactly FPU_MAX_LATENCY cycles relative to the iss_* inputs, matching
    -- the latency of the execution unit's arithmetic pipeline.
    wb_rd_addr <= rd_addr_pipe(FPU_MAX_LATENCY);
    wb_mask    <= mask_pipe(FPU_MAX_LATENCY);
    wb_mux_sel <= mux_pipe(FPU_MAX_LATENCY);
    wb_vrf_we  <= vrf_we_pipe(FPU_MAX_LATENCY);
    wb_prf_we  <= prf_we_pipe(FPU_MAX_LATENCY);

end architecture rtl;
