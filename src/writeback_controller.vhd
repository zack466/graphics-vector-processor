-- ============================================================================
-- writeback_controller.vhd — Writeback Pipeline / Destination-Address Delay
-- ============================================================================
--
-- WHY THIS COMPONENT EXISTS
-- -------------------------
-- The execution unit contains several floating-point IP cores (FPU lanes,
-- scalar-product unit, ALU) whose results emerge after a fixed but non-trivial
-- number of clock cycles (FPU_MAX_LATENCY).  When the instruction issuer drives
-- rd_addr and write-enable onto the bus, the result data does not yet exist —
-- the IP cores are still computing.  The writeback controller is a pure shift
-- register that delays the address and control signals by exactly FPU_MAX_LATENCY
-- cycles so that the destination address and WE arrive at the register files on
-- the same cycle the arithmetic result comes out of the execution unit.
--
-- WHY A SEPARATE COMPONENT (not inline registers in the execution unit)?
-- Centralising the delay in one place means:
--  1. Pipeline depth is tunable from a single constant (FPU_MAX_LATENCY in
--     processor_constants_pkg).  Changing it automatically adjusts every signal
--     without touching the execution unit RTL.
--  2. The execution unit remains focused on data-path logic and does not need to
--     carry control side-channel signals (addresses, masks, mux selects) through
--     every IP-core stage.
--  3. The design's "single tap" model makes it straightforward to add forwarding
--     or hazard-detection logic in the future — all writeback metadata passes
--     through one well-defined shift register.
--
-- HOW TO USE
-- ----------
-- Connect iss_* inputs directly to the instruction issuer's per-thread outputs.
-- The wb_* outputs connect directly to the VRF/PRF write ports.  No external
-- enable or handshaking is required — the pipeline shifts unconditionally every
-- cycle, relying on vrf_we/prf_we being '0' for bubbles.
--
-- PORT DESCRIPTIONS
-- -----------------
-- clk         : System clock.  All registers are rising-edge triggered.
-- reset       : Synchronous active-high reset.  Only vrf_we_pipe and prf_we_pipe
--               are cleared (to '0') on reset; address/mask/mux pipelines are
--               don't-care while WE is deasserted and are left at their reset
--               state from FPGA initialisation.
--
-- iss_rd_addr : 9-bit global destination address {thread_id[4:0], reg[3:0]}
--               presented by the instruction issuer.  Injected at pipeline
--               stage 0 each cycle.
-- iss_mask    : 4-bit XYZW component write mask from the instruction word.
--               Allows partial writes (e.g., .xyz only) to a vector register.
-- iss_wb_mux  : 2-bit mux selector that routes one of {FPU result, reduction
--               unit result, ALU result} to the register-file write data bus.
-- iss_vrf_we  : Vector register file write-enable from the issuer.  Must be '0'
--               for instructions that do not write the VRF (stores, predicates,
--               NOPs).
-- iss_prf_we  : Predicate register file write-enable from the issuer.  High only
--               for compare/test instructions that produce a boolean result.
--
-- wb_rd_addr  : Delayed rd_addr, aligned with execution-unit result.
-- wb_mask     : Delayed write mask, aligned with execution-unit result.
-- wb_mux_sel  : Delayed mux selector, aligned with execution-unit result.
-- wb_vrf_we   : Delayed VRF write-enable — gates the actual VRF write port.
-- wb_prf_we   : Delayed PRF write-enable — gates the actual PRF write port.
--
-- TIMING / LATENCY
-- ----------------
-- Every signal is delayed by exactly FPU_MAX_LATENCY rising edges:
-- one edge to load stage 1, then FPU_MAX_LATENCY-1 edges to shift to the output.
-- The output signals are purely registered (no combinational output path), so
-- they are glitch-free and can drive the register-file write ports directly.
-- The depth equals FPU_MAX_LATENCY exactly because the iss_* inputs are driven
-- from S2 of the execution unit — the same stage at which functional units start.
-- No off-by-one correction is needed.
--
-- Only vrf_we and prf_we are reset to '0' — the other pipeline stages hold
-- their FPGA power-on state until written.  This is intentional: the data
-- written to the register file when WE='0' is irrelevant, so initialising
-- address/mask/mux pipelines wastes reset-logic resources for no safety benefit.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

-- Pipelines writeback signals to be in sync with the FPU and reduction unit.
-- Ensures that vectors/predicates are written back into their corresponding
-- register files on the right clock.
entity writeback_controller is
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- ==========================================
        -- STAGE 0/1 INPUTS (From Instruction Issuer)
        -- ==========================================
        iss_rd_addr : in  std_logic_vector(8 downto 0);
        iss_mask    : in  std_logic_vector(3 downto 0);
        iss_wb_mux  : in  std_logic_vector(1 downto 0);
        iss_vrf_we  : in  std_logic;
        iss_prf_we  : in  std_logic;

        -- ==========================================
        -- STAGE N OUTPUTS (To Register Files)
        -- ==========================================
        wb_rd_addr  : out std_logic_vector(8 downto 0);
        wb_mask     : out std_logic_vector(3 downto 0);
        wb_mux_sel  : out std_logic_vector(1 downto 0);
        wb_vrf_we   : out std_logic;
        wb_prf_we   : out std_logic
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

    -- Only Write Enables strictly require initialization to prevent memory corruption.
    -- WHY: If vrf_we_pipe or prf_we_pipe come out of reset in an unknown state,
    -- the register files could be written with garbage on the first FPU_MAX_LATENCY
    -- cycles.  The address/mask/mux pipelines are safe to leave uninitialised
    -- because their values are only consumed when WE='1'.
    signal vrf_we_pipe  : we_pipe_t   := (others => '0');
    signal prf_we_pipe  : we_pipe_t   := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Only flush the write-enable pipelines on reset.  Clearing
                -- address/mask/mux would be wasteful: they are don't-care while
                -- WE='0', so the synthesis tool can optimise those registers away
                -- if they are not reset.
                vrf_we_pipe <= (others => '0');
                prf_we_pipe <= (others => '0');
            else
                -- 1. Inject new instruction metadata at the front of the pipeline.
                --    This happens every cycle; when no instruction is being issued
                --    the issuer drives WE='0', which propagates as a bubble through
                --    the shift register and prevents a spurious register-file write.
                rd_addr_pipe(1) <= iss_rd_addr;
                mask_pipe(1)    <= iss_mask;
                mux_pipe(1)     <= iss_wb_mux;
                vrf_we_pipe(1)  <= iss_vrf_we;
                prf_we_pipe(1)  <= iss_prf_we;

                -- 2. Unconditionally shift the pipeline to match FPU math progression.
                --    WHY unconditional (no enable/stall)?  The barrel scheduler never
                --    stalls mid-instruction — it issues all 32 threads back-to-back
                --    with no bubbles.  A stall signal would complicate the design
                --    without any benefit in this architecture.
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

    -- ========================================================================
    -- OUTPUT ROUTING (Outputs arrive perfectly synced with FPU math results)
    -- ========================================================================
    -- Tapping the last stage of each shift register produces signals that are
    -- delayed by exactly FPU_MAX_LATENCY cycles relative to the iss_* inputs,
    -- matching the latency of the execution unit's arithmetic pipeline.
    wb_rd_addr <= rd_addr_pipe(FPU_MAX_LATENCY);
    wb_mask    <= mask_pipe(FPU_MAX_LATENCY);
    wb_mux_sel <= mux_pipe(FPU_MAX_LATENCY);
    wb_vrf_we  <= vrf_we_pipe(FPU_MAX_LATENCY);
    wb_prf_we  <= prf_we_pipe(FPU_MAX_LATENCY);

end architecture rtl;
