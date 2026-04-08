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
    type addr_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(8 downto 0);
    type mask_pipe_t is array (0 to FPU_MAX_LATENCY) of std_logic_vector(3 downto 0);
    type mux_pipe_t  is array (0 to FPU_MAX_LATENCY) of std_logic_vector(1 downto 0);
    type we_pipe_t   is array (0 to FPU_MAX_LATENCY) of std_logic;

    -- ========================================================================
    -- SHIFT REGISTERS
    -- ========================================================================
    signal rd_addr_pipe : addr_pipe_t := (others => (others => '0'));
    signal mask_pipe    : mask_pipe_t := (others => "0000");
    signal mux_pipe     : mux_pipe_t  := (others => "00");
    
    -- Only Write Enables strictly require initialization to prevent memory corruption
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
                -- 1. Inject new instruction metadata at the front of the pipeline
                rd_addr_pipe(0) <= iss_rd_addr;
                mask_pipe(0)    <= iss_mask;
                mux_pipe(0)     <= iss_wb_mux;
                vrf_we_pipe(0)  <= iss_vrf_we;
                prf_we_pipe(0)  <= iss_prf_we;

                -- 2. Unconditionally shift the pipeline to match FPU math progression
                for i in 1 to FPU_MAX_LATENCY loop
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
    wb_rd_addr <= rd_addr_pipe(FPU_MAX_LATENCY);
    wb_mask    <= mask_pipe(FPU_MAX_LATENCY);
    wb_mux_sel <= mux_pipe(FPU_MAX_LATENCY);
    wb_vrf_we  <= vrf_we_pipe(FPU_MAX_LATENCY);
    wb_prf_we  <= prf_we_pipe(FPU_MAX_LATENCY);

end architecture rtl;
