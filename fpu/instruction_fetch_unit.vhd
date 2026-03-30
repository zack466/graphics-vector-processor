library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

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
        imem_data          : in  word_t;      -- Arrives 1 cycle after imem_addr
        imem_valid         : in  std_logic;   -- '1' if memory successfully read

        -- ==========================================
        -- Pipeline Control
        -- ==========================================
        stall              : in  std_logic;   -- Freezes PC (e.g., waiting on memory or hazard)

        -- ==========================================
        -- Branch & SIMT Control (From Decoder)
        -- ==========================================
        branch_en          : in  std_logic;   -- Standard jump
        branch_target      : in  std_logic_vector(PC_WIDTH-1 downto 0);

        -- SIMT Divergence (Push to Stack)
        simt_push_en       : in  std_logic;   
        simt_reconv_pc     : in  std_logic_vector(PC_WIDTH-1 downto 0); -- The meetup point
        simt_deferred_pc   : in  std_logic_vector(PC_WIDTH-1 downto 0); -- Where the 'else' block starts
        simt_deferred_mask : in  std_logic_vector(WARP_SIZE-1 downto 0);-- Threads running the 'else'
        simt_active_mask   : in  std_logic_vector(WARP_SIZE-1 downto 0);-- Threads running the 'if'

        -- SIMT Reconvergence (Pop from Stack)
        simt_sync_en       : in  std_logic;   -- Triggers a stack pop

        -- ==========================================
        -- Outputs to the Barrel Scheduler
        -- ==========================================
        instruction_out    : out word_t;
        exec_mask_out      : out std_logic_vector(WARP_SIZE-1 downto 0);
        fetch_valid        : out std_logic
    );
end entity;

architecture rtl of instruction_fetch_unit is

    -- SIMT Stack Definition
    type simt_entry_t is record
        reconv_pc     : unsigned(PC_WIDTH-1 downto 0);
        deferred_pc   : unsigned(PC_WIDTH-1 downto 0);
        deferred_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    end record;
    
    type simt_stack_t is array (0 to STACK_DEPTH-1) of simt_entry_t;
    
    -- Hardware Registers
    signal pc          : unsigned(PC_WIDTH-1 downto 0);
    signal active_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal stack       : simt_stack_t;
    signal sp          : integer range 0 to STACK_DEPTH; -- Stack Pointer
    
    -- Delay registers to align with memory read latency
    signal fetch_mask_reg : std_logic_vector(WARP_SIZE-1 downto 0);

begin

    -- Continuously drive the instruction memory address
    imem_addr <= std_logic_vector(pc);

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pc          <= (others => '0');
                active_mask <= (others => '1'); -- All threads active by default
                sp          <= 0;
                fetch_mask_reg <= (others => '1');
                
            elsif stall = '0' then
                
                -- Shift the active mask into the delay register to align with imem_data
                fetch_mask_reg <= active_mask;

                -- =======================================================
                -- 1. SIMT Reconvergence (Pop Stack)
                -- =======================================================
                if simt_sync_en = '1' then
                    if sp > 0 then
                        -- Restore the deferred threads and jump to their code block
                        sp <= sp - 1;
                        pc <= stack(sp - 1).deferred_pc;
                        active_mask <= stack(sp - 1).deferred_mask;
                    else
                        -- Failsafe: If stack is empty, reset to full warp
                        active_mask <= (others => '1');
                        pc <= pc + 1;
                    end if;

                -- =======================================================
                -- 2. SIMT Divergence (Push Stack)
                -- =======================================================
                elsif simt_push_en = '1' then
                    if sp < STACK_DEPTH then
                        -- Save the deferred path for later
                        stack(sp).reconv_pc     <= unsigned(simt_reconv_pc);
                        stack(sp).deferred_pc   <= unsigned(simt_deferred_pc);
                        stack(sp).deferred_mask <= simt_deferred_mask;
                        sp <= sp + 1;
                    end if;
                    
                    -- Jump to the active path and apply the new mask
                    pc <= unsigned(branch_target);
                    active_mask <= simt_active_mask;

                -- =======================================================
                -- 3. Standard Branching
                -- =======================================================
                elsif branch_en = '1' then
                    pc <= unsigned(branch_target);

                -- =======================================================
                -- 4. Standard Sequential Fetch
                -- =======================================================
                else
                    pc <= pc + 1;
                end if;
                
            end if;
        end if;
    end process;

    -- Map outputs to the pipeline
    instruction_out <= imem_data;
    exec_mask_out   <= fetch_mask_reg;
    fetch_valid     <= imem_valid and not stall;

end architecture rtl;
