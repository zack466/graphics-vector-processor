-- =============================================================================
-- FILE: instruction_fetch_unit.vhd
-- COMPONENT: Instruction Fetch Unit (IFU)
-- =============================================================================
--
-- PURPOSE:
--   The IFU is the only block that knows which threads within the warp are
--   currently active. It manages three things simultaneously:
--
--     1. Program Counter (PC): Tracks the next instruction address and drives
--        the instruction memory address bus. On normal sequential execution it
--        increments by 1 each cycle. On branches it jumps to target_addr.
--
--     2. Execution Mask (exec_mask_out): A WARP_SIZE-bit vector where each bit
--        represents one thread. '1' = thread is active and should execute the
--        current instruction; '0' = thread is masked off (predicated out or
--        deferred by divergence). The mask is updated by BRA_DIV/SYNC logic.
--
--     3. SIMT Divergence Stack: Hardware stack of {reconv_pc, deferred_pc,
--        deferred_mask, outer_mask} entries. Supports up to STACK_DEPTH nested
--        if/else blocks. This is the core of the SIMT control-flow model.
--
-- USAGE:
--   Instantiated once by processor.vhd. The stall input is driven by the
--   processor FSM. The pc_ctrl input arrives from instruction_decoder via the
--   processor FSM and is sampled on the cycle when stall='0' (ADVANCE_PC state).
--   predicate_mask must be stable (read from the PRF collapse port) on the same
--   cycle that pc_ctrl carries a branch instruction.
--
-- TIMING / LATENCY:
--   - stall='1' freezes PC, active_mask, and fetch_mask_reg. The IFU holds its
--     current state until stall is deasserted.
--   - fetch_valid = imem_valid AND NOT stall. In the current implementation,
--     imem_valid is tied to '1' by the top-level since instruction memory
--     (M10K BRAM) has a fixed 1-cycle read latency and never stalls.
--   - The FETCH_1→FETCH_2 transition in the processor FSM takes 2 cycles because
--     M10K BRAM requires one cycle to return data after the address is presented.
--     stall='1' is asserted during FETCH_1 and deasserted on FETCH_2, so the IFU
--     advances the PC precisely once per instruction fetch.
--   - fetch_mask_reg is loaded from next_mask on the same cycle the PC is updated.
--     This keeps the mask aligned with the instruction currently being fetched
--     (not the previous or next one).
--
-- SIMT CONTROL-FLOW MODEL:
--   Divergence is handled using an explicit hardware stack inspired by the
--   NVIDIA SIMT model. The sequence for a simple if/else is:
--
--     SSY   <reconv_pc>    -- Record where the warp reconverges after if/else
--     BRA_DIV <taken_pc>  -- Split warp: IF threads jump, ELSE threads deferred
--     <IF body>
--     SYNC                -- End of IF: switch to ELSE threads
--     <ELSE body>
--     SYNC                -- End of ELSE: pop stack, restore all threads
--     <reconv_pc>:
--     <post-branch code>
--
--   The SIMT stack stores enough state to replay both paths without OS support.
--   STACK_DEPTH controls the maximum nesting level of if/else blocks.
--
-- PORTS:
--   clk              - System clock.
--   reset            - Synchronous active-high reset. Sets PC=0, activates all
--                      threads (active_mask = all-ones), clears the stack (sp=0).
--   imem_addr        - PC driven directly to instruction memory address bus.
--   imem_data        - Raw 32-bit instruction word from memory; passed through
--                      to instruction_out unchanged (no buffering in the IFU).
--   imem_valid       - When '1', imem_data is valid. Currently tied high by the
--                      top-level; included for future stall-capable memory.
--   stall            - When '1', PC and masks freeze. Driven by the processor
--                      FSM during execution wait states (EXEC_WAIT, FETCH_1).
--                      The IFU resumes on the cycle stall goes to '0'.
--   pc_ctrl          - Branch control record from instruction_decoder. Contains
--                      branch_type (JMP/BRA_Z/BRA_NZ/BRA_DIV/SSY/SYNC/NONE),
--                      target_addr (16-bit branch destination), predicate_sel,
--                      and predicate_mod. Sampled when stall='0'.
--   predicate_mask   - WARP_SIZE-bit per-thread predicate evaluation result read
--                      combinationally from the PRF collapse port. Each bit
--                      reflects one thread's predicate register value for the
--                      register selected by pc_ctrl.predicate_sel. Sampled on
--                      the same cycle as pc_ctrl.
--   instruction_out  - Registered instruction word forwarded to the decode stage.
--                      (Currently = imem_data, combinationally; the BRAM adds
--                      the one-cycle latency implicitly.)
--   exec_mask_out    - Active thread mask for the instruction currently being
--                      fetched. Driven from fetch_mask_reg, which is updated
--                      coincident with the PC to track the correct mask.
--   fetch_valid      - Asserted when a valid instruction is available and the
--                      pipeline is not stalled. The processor FSM uses this to
--                      decide when to advance the decode stage.
--
-- GENERICS:
--   PC_WIDTH    - Width of the program counter and instruction memory address.
--                 Default 16 gives a 64K instruction address space.
--   WARP_SIZE   - Number of threads per warp. Default 32.
--   STACK_DEPTH - Maximum depth of the SIMT divergence stack (max nested if/else).
--                 Default 16.
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_fetch_unit is
    generic (
        PC_WIDTH    : integer := 16; -- 64K Instruction Address Space
        WARP_SIZE   : integer := 32; -- 32 Threads per Warp
        STACK_DEPTH : integer := 16  -- Max depth of nested if/else statements
    );
    port (
        clk                : in  std_logic;
        reset              : in  std_logic;

        -- ==========================================
        -- External Instruction Memory Interface
        -- ==========================================
        imem_addr          : out std_logic_vector(PC_WIDTH-1 downto 0);
        imem_data          : in  word_t;      
        imem_valid         : in  std_logic;   

        -- ==========================================
        -- Pipeline Control
        -- ==========================================
        stall              : in  std_logic;   

        -- ==========================================
        -- Branch & SIMT Control
        -- ==========================================
        pc_ctrl            : in  pc_ctrl_t;
        predicate_mask     : in  std_logic_vector(WARP_SIZE-1 downto 0); -- Evaluated conditionals from threads

        -- ==========================================
        -- Outputs to the Barrel Scheduler
        -- ==========================================
        instruction_out    : out word_t;
        exec_mask_out      : out std_logic_vector(WARP_SIZE-1 downto 0);
        fetch_valid        : out std_logic
    );
end entity;

architecture rtl of instruction_fetch_unit is

    -- -------------------------------------------------------------------------
    -- SIMT Stack Type Definition
    -- Each stack entry stores the full context for one level of if/else nesting.
    --
    --   reconv_pc    : The instruction address where both the IF and ELSE paths
    --                  rejoin after the second SYNC. Set by the preceding SSY.
    --   deferred_pc  : The start of the ELSE (not-taken) path. Set to pc+1 when
    --                  BRA_DIV diverges. After the IF body's SYNC consumes this,
    --                  deferred_mask is zeroed to indicate the entry is "used".
    --   deferred_mask: The thread mask for the ELSE path. Non-zero = ELSE path
    --                  is still pending. Zero = ELSE path already executed (or
    --                  there was no ELSE, i.e., all-taken branch).
    --   outer_mask   : The full active thread mask that existed BEFORE this
    --                  if/else began (i.e., before BRA_DIV split the warp).
    --                  Restored when the second SYNC pops the stack so all
    --                  threads that were active originally rejoin at reconv_pc.
    -- -------------------------------------------------------------------------
    type simt_entry_t is record
        reconv_pc     : unsigned(PC_WIDTH-1 downto 0);
        deferred_pc   : unsigned(PC_WIDTH-1 downto 0);
        deferred_mask : std_logic_vector(WARP_SIZE-1 downto 0);
        outer_mask    : std_logic_vector(WARP_SIZE-1 downto 0);
    end record;

    type simt_stack_t is array (0 to STACK_DEPTH-1) of simt_entry_t;

    -- -------------------------------------------------------------------------
    -- Hardware Registers
    -- -------------------------------------------------------------------------
    -- pc: current program counter. Drives imem_addr combinationally so the
    -- BRAM sees the new address on the same cycle the PC is updated.
    signal pc              : unsigned(PC_WIDTH-1 downto 0);
    -- active_mask: which threads in the warp are currently executing. Updated
    -- by BRA_DIV (may narrow the mask) and SYNC (restores from stack or widens).
    signal active_mask     : std_logic_vector(WARP_SIZE-1 downto 0);
    -- stack/sp: the SIMT divergence stack and its stack pointer.
    signal stack           : simt_stack_t;
    signal sp              : integer range 0 to STACK_DEPTH;
    -- saved_reconv_pc: holds the reconvergence PC written by SSY until BRA_DIV
    -- pushes it onto the stack. Separate from the stack so SSY can set it
    -- one instruction before BRA_DIV without consuming a stack slot prematurely.
    signal saved_reconv_pc : unsigned(PC_WIDTH-1 downto 0);

    -- -------------------------------------------------------------------------
    -- fetch_mask_reg: one-cycle delay register for the execution mask.
    -- WHY: The mask for the instruction currently being fetched must track the
    -- PC that was driven to BRAM on the previous cycle, not the PC being driven
    -- now. fetch_mask_reg is loaded with next_mask on the same edge that the PC
    -- advances, so exec_mask_out is always aligned with the instruction word
    -- that arrives from BRAM one cycle later.
    -- -------------------------------------------------------------------------
    signal fetch_mask_reg  : std_logic_vector(WARP_SIZE-1 downto 0);

begin

    -- Drive instruction memory address directly from PC (combinational).
    -- WHY no register between pc and imem_addr: the BRAM's output-register
    -- mode already adds one pipeline stage, so we do not want an extra stage
    -- here. The BRAM address-to-data latency gives us fetch_valid alignment.
    imem_addr <= std_logic_vector(pc);

    process(clk)
        -- taken_mask: threads that evaluated the predicate as TRUE (will branch).
        -- Computed as active_mask AND predicate_mask so only live threads count.
        variable taken_mask     : std_logic_vector(WARP_SIZE-1 downto 0);
        -- not_taken_mask: threads that evaluated the predicate as FALSE (fall-through).
        variable not_taken_mask : std_logic_vector(WARP_SIZE-1 downto 0);
        -- all_taken: TRUE if every active thread will take the branch (uniform branch).
        -- In this case BRA_DIV still pushes a dummy stack entry to preserve the
        -- reconvergence point, but no threads are deferred.
        variable all_taken      : boolean;
        -- none_taken: TRUE if no active thread takes the branch.
        -- In this case BRA_DIV falls through and pushes a dummy entry.
        variable none_taken     : boolean;
        -- is_divergent: TRUE when BOTH taken_mask and not_taken_mask are non-zero,
        -- meaning different threads want to go to different PCs. This triggers the
        -- real divergence path: push the ELSE (not-taken) path and jump to IF.
        variable is_divergent   : boolean;
        -- target_u: pc_ctrl.target_addr resized to PC_WIDTH for arithmetic.
        variable target_u       : unsigned(PC_WIDTH-1 downto 0);
        -- next_mask: the execution mask to use for the NEXT instruction. Computed
        -- here so fetch_mask_reg can be loaded in the same clock cycle as the PC.
        variable next_mask      : std_logic_vector(WARP_SIZE-1 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pc              <= (others => '0');
                -- Start with all threads active. The scheduler will narrow the
                -- mask later if fewer than WARP_SIZE threads are in the warp.
                active_mask     <= (others => '1');
                sp              <= 0;
                saved_reconv_pc <= (others => '0');
                fetch_mask_reg  <= (others => '1');

            elsif stall = '0' then
                -- ---------------------------------------------------------------
                -- Combinational condition evaluations (computed inside the clocked
                -- process but before any state is updated, so they act as if
                -- combinational with respect to the current-cycle values).
                -- ---------------------------------------------------------------
                taken_mask     := active_mask and predicate_mask;
                not_taken_mask := active_mask and (not predicate_mask);
                all_taken      := (active_mask /= x"00000000") and (not_taken_mask = x"00000000");
                none_taken     := (active_mask /= x"00000000") and (taken_mask = x"00000000");
                is_divergent   := (not_taken_mask /= x"00000000") and (taken_mask /= x"00000000");

                -- Edge case: if active_mask is entirely zero (all threads masked),
                -- treat as none_taken to prevent the PC from jumping erroneously.
                if active_mask = x"00000000" then
                    all_taken := false; none_taken := true; is_divergent := false;
                end if;

                -- ---------------------------------------------------------------
                -- Pre-compute next_mask so it can be stored into fetch_mask_reg
                -- on the same rising edge that updates PC. This ensures the mask
                -- delivered to the execute stage is always aligned with the
                -- instruction that the BRAM will return one cycle after the PC
                -- that was driven to imem_addr this cycle.
                -- Default: mask does not change (sequential instruction).
                -- ---------------------------------------------------------------
                next_mask := active_mask;

                if pc_ctrl.branch_type = BR_SYNC then
                    if sp > 0 then
                        if stack(sp-1).deferred_mask /= x"00000000" then
                            -- SYNC first encounter (end of IF body): next instruction
                            -- is the start of the ELSE path → use deferred_mask.
                            next_mask := stack(sp-1).deferred_mask;
                        else
                            -- SYNC second encounter (end of ELSE body): next instruction
                            -- is post-reconvergence → restore full warp (outer_mask).
                            next_mask := stack(sp-1).outer_mask;
                        end if;
                    end if;
                elsif pc_ctrl.branch_type = BR_BRA_DIV then
                    if is_divergent then
                        -- Only narrow the mask on a true divergence. All-taken and
                        -- none-taken cases keep the same mask (uniform branches).
                        next_mask := taken_mask;
                    end if;
                end if;

                -- Store next_mask so exec_mask_out tracks the instruction being
                -- fetched (the instruction whose address just appeared on imem_addr).
                fetch_mask_reg <= next_mask;

                -- Resize target_addr from its encoded width to PC_WIDTH.
                -- resize() zero-extends, so branches into the lower address space
                -- work correctly regardless of PC_WIDTH generic value.
                target_u       := resize(unsigned(pc_ctrl.target_addr), PC_WIDTH);

                -- =======================================================
                -- 1. SIMT Reconvergence (SYNC)
                -- WHY two-phase SYNC: A single SYNC instruction serves as both
                -- the end-of-IF marker and the end-of-ELSE marker. The IFU
                -- distinguishes them by checking whether deferred_mask is
                -- non-zero (ELSE path still pending) or zero (ELSE path done).
                -- This avoids needing separate SYNC_IF and SYNC_ELSE opcodes.
                -- =======================================================
                if pc_ctrl.branch_type = BR_SYNC then
                    if sp > 0 then
                        if stack(sp-1).deferred_mask /= x"00000000" then
                            -- Phase 1: End of IF body. deferred_mask is non-zero,
                            -- meaning the ELSE path hasn't run yet. Switch to the
                            -- ELSE path's start address and make those threads active.
                            -- Zero deferred_mask to mark it as consumed so the next
                            -- SYNC (at the end of ELSE) takes the Phase 2 path.
                            pc <= stack(sp-1).deferred_pc;
                            active_mask <= stack(sp-1).deferred_mask;
                            stack(sp-1).deferred_mask <= (others => '0');
                        else
                            -- Phase 2: End of ELSE body. deferred_mask=0 means ELSE
                            -- already ran (or there was no ELSE). Pop the stack entry,
                            -- restore the full pre-divergence mask, and jump to the
                            -- reconvergence point where all threads rejoin.
                            pc <= stack(sp-1).reconv_pc;
                            active_mask <= stack(sp-1).outer_mask;
                            sp <= sp - 1;
                        end if;
                    else
                        -- SYNC with empty stack: no divergence was in progress.
                        -- Restore full mask (defensive) and step to next instruction.
                        active_mask <= (others => '1');
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 2. Set Sync Point (SSY)
                -- WHY separate from BRA_DIV: SSY and BRA_DIV are always paired
                -- but may be separated by several instructions in the binary
                -- (compiler may insert instructions between them). Storing the
                -- reconvergence PC in saved_reconv_pc one instruction before
                -- BRA_DIV avoids requiring the assembler to encode it twice or
                -- requiring the IFU to look ahead.
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_SSY then
                    saved_reconv_pc <= target_u;
                    pc <= pc + 1;

                -- =======================================================
                -- 3. Divergent Branch (BRA_DIV)
                -- WHY always push even for uniform branches: the SYNC logic
                -- relies on a matching stack entry for every BRA_DIV. Pushing
                -- a dummy entry (deferred_mask=0) for uniform cases lets SYNC
                -- use the same pop logic unconditionally, greatly simplifying
                -- the reconvergence state machine.
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_DIV then
                    if is_divergent then
                        -- True divergence: some threads take the branch (IF),
                        -- some do not (ELSE). Push the ELSE path onto the stack
                        -- so SYNC can switch to it after the IF body completes.
                        -- deferred_pc = pc+1 because the fall-through (ELSE) path
                        -- starts at the instruction immediately after BRA_DIV.
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= pc + 1;
                        stack(sp).deferred_mask <= not_taken_mask;
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        -- Activate only the IF (taken) threads and jump to the
                        -- IF body start address.
                        pc <= target_u;
                        active_mask <= taken_mask;
                    elsif all_taken then
                        -- Uniform branch: all active threads take the branch.
                        -- Push a dummy entry (deferred_mask=0) so SYNC has a
                        -- matching pop. No threads are deferred.
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= (others => '0');
                        stack(sp).deferred_mask <= (others => '0');
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        pc <= target_u;
                    else
                        -- Uniform not-taken: no active thread takes the branch.
                        -- Push a dummy entry and fall through. active_mask unchanged.
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= (others => '0');
                        stack(sp).deferred_mask <= (others => '0');
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 4. Branch if Zero (BRA_Z)
                -- WHY "none_taken" not "all NOT taken": active threads that did
                -- not evaluate the predicate as TRUE constitute the none_taken
                -- condition. The branch fires only when every active thread sees
                -- predicate=0, making it a WARP-level convergent branch where
                -- the entire warp moves together. No divergence stack push needed
                -- because this branch never splits the warp.
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_Z then
                    if none_taken then
                        pc <= target_u;
                    else
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 5. Branch if Not Zero (BRA_NZ)
                -- Same warp-level uniform semantics as BRA_Z, inverted: the
                -- branch fires as long as at least one active thread sees
                -- predicate=1. No divergence stack interaction.
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_NZ then
                    if not none_taken then
                        pc <= target_u;
                    else
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 6. Unconditional Jump
                -- Used for subroutine calls and loops. No mask changes.
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_JMP then
                    pc <= target_u;

                -- =======================================================
                -- 7. Standard Sequential Fetch
                -- Default case: just advance PC by 1. The active_mask and
                -- stack are unchanged.
                -- =======================================================
                else
                    pc <= pc + 1;
                end if;
                
            end if;
        end if;
    end process;

    -- Pass instruction data directly to the decode stage. The BRAM's output
    -- register provides the one-cycle fetch latency; no additional buffering here.
    instruction_out <= imem_data;

    -- exec_mask_out comes from fetch_mask_reg (registered), not active_mask
    -- (which reflects the NEXT fetch). This alignment is critical: the decode
    -- and execute stages must see the mask that was active when THIS instruction
    -- was fetched, not the mask for the instruction being fetched right now.
    exec_mask_out   <= fetch_mask_reg;

    -- fetch_valid: deasserted while stall='1' so the decode stage does not
    -- consume stale instruction data held on imem_data during wait cycles.
    -- imem_valid is currently always '1' (tied high at the top level).
    fetch_valid     <= imem_valid and not stall;

end architecture rtl;
