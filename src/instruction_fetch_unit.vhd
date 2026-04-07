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

    -- Enhanced SIMT Stack Definition
    type simt_entry_t is record
        reconv_pc     : unsigned(PC_WIDTH-1 downto 0);
        deferred_pc   : unsigned(PC_WIDTH-1 downto 0);
        deferred_mask : std_logic_vector(WARP_SIZE-1 downto 0);
        outer_mask    : std_logic_vector(WARP_SIZE-1 downto 0);
    end record;
    
    type simt_stack_t is array (0 to STACK_DEPTH-1) of simt_entry_t;
    
    -- Hardware Registers
    signal pc              : unsigned(PC_WIDTH-1 downto 0);
    signal active_mask     : std_logic_vector(WARP_SIZE-1 downto 0);
    signal stack           : simt_stack_t;
    signal sp              : integer range 0 to STACK_DEPTH; 
    signal saved_reconv_pc : unsigned(PC_WIDTH-1 downto 0);
    
    -- Delay registers to align with memory read latency
    signal fetch_mask_reg  : std_logic_vector(WARP_SIZE-1 downto 0);

begin

    imem_addr <= std_logic_vector(pc);

    process(clk)
        variable taken_mask     : std_logic_vector(WARP_SIZE-1 downto 0);
        variable not_taken_mask : std_logic_vector(WARP_SIZE-1 downto 0);
        variable all_taken      : boolean;
        variable none_taken     : boolean;
        variable is_divergent   : boolean;
        variable target_u       : unsigned(PC_WIDTH-1 downto 0);
        
        variable next_mask      : std_logic_vector(WARP_SIZE-1 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pc              <= (others => '0');
                active_mask     <= (others => '1'); 
                sp              <= 0;
                saved_reconv_pc <= (others => '0');
                fetch_mask_reg  <= (others => '1');
                
            elsif stall = '0' then
                -- Combinational Condition Evaluations
                taken_mask     := active_mask and predicate_mask;
                not_taken_mask := active_mask and (not predicate_mask);
                all_taken      := (active_mask /= x"00000000") and (not_taken_mask = x"00000000");
                none_taken     := (active_mask /= x"00000000") and (taken_mask = x"00000000");
                is_divergent   := (not_taken_mask /= x"00000000") and (taken_mask /= x"00000000");
                
                if active_mask = x"00000000" then
                    all_taken := false; none_taken := true; is_divergent := false;
                end if;
                
                -- Determine NEXT MASK instantly to align with NEXT instruction fetched
                next_mask := active_mask; -- Default

                if pc_ctrl.branch_type = BR_SYNC then
                    if sp > 0 then
                        if stack(sp-1).deferred_mask /= x"00000000" then
                            next_mask := stack(sp-1).deferred_mask;
                        else
                            next_mask := stack(sp-1).outer_mask;
                        end if;
                    end if;
                elsif pc_ctrl.branch_type = BR_BRA_DIV then
                    if is_divergent then
                        next_mask := taken_mask;
                    end if;
                end if;

                -- fetch_mask_reg gets the mask for the instruction CURRENTLY being fetched.
                -- That's next_mask!
                fetch_mask_reg <= next_mask;

                -- Pad target_addr safely depending on PC_WIDTH
                target_u       := resize(unsigned(pc_ctrl.target_addr), PC_WIDTH);

                -- =======================================================
                -- 1. SIMT Reconvergence (SYNC)
                -- =======================================================
                if pc_ctrl.branch_type = BR_SYNC then
                    if sp > 0 then
                        if stack(sp-1).deferred_mask /= x"00000000" then
                            -- Phase 1: End of IF block. Switch to ELSE path.
                            pc <= stack(sp-1).deferred_pc;
                            active_mask <= stack(sp-1).deferred_mask;
                            stack(sp-1).deferred_mask <= (others => '0'); -- Mark as consumed
                        else
                            -- Phase 2: End of ELSE block. Reconverge full warp.
                            pc <= stack(sp-1).reconv_pc;
                            active_mask <= stack(sp-1).outer_mask;
                            sp <= sp - 1;
                        end if;
                    else
                        active_mask <= (others => '1');
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 2. Set Sync (SSY) - Marks the Reconvergence Point
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_SSY then
                    saved_reconv_pc <= target_u;
                    pc <= pc + 1;

                -- =======================================================
                -- 3. Divergent Branch (BRA_DIV)
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_DIV then
                    if is_divergent then
                        -- Push deferred 'Else' path to stack
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= pc + 1;
                        stack(sp).deferred_mask <= not_taken_mask;
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        
                        -- Jump to 'If' path
                        pc <= target_u;
                        active_mask <= taken_mask;
                    elsif all_taken then
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= (others => '0'); 
                        stack(sp).deferred_mask <= (others => '0');
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        pc <= target_u;
                    else
                        stack(sp).reconv_pc     <= saved_reconv_pc;
                        stack(sp).deferred_pc   <= (others => '0'); 
                        stack(sp).deferred_mask <= (others => '0');
                        stack(sp).outer_mask    <= active_mask;
                        sp <= sp + 1;
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 4. Branch if Zero (BRA_Z)
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_Z then
                    if none_taken then -- All active predicates evaluated to 0
                        pc <= target_u;
                    else
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 5. Branch if Not Zero (BRA_NZ)
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_BRA_NZ then
                    if not none_taken then -- At least one active predicate evaluated to 1
                        pc <= target_u;
                    else
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 6. Unconditional Jump
                -- =======================================================
                elsif pc_ctrl.branch_type = BR_JMP then
                    pc <= target_u;

                -- =======================================================
                -- 7. Standard Sequential Fetch
                -- =======================================================
                else
                    pc <= pc + 1;
                end if;
                
            end if;
        end if;
    end process;

    instruction_out <= imem_data;
    exec_mask_out   <= fetch_mask_reg;
    fetch_valid     <= imem_valid and not stall;

end architecture rtl;
