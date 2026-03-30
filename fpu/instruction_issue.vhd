library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_issue is
    generic (
        THREAD_WIDTH : integer := 5; -- 32 Hardware Threads
        REG_WIDTH    : integer := 2  -- 4 Vector Registers per thread (v0 to v3)
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;
        
        -- Inputs from Instruction Decoder
        fpu_ctrl_in     : in  fpu_ctrl_t;
        valid_in        : in  std_logic;
        
        -- State Output
        current_thread  : out std_logic_vector(THREAD_WIDTH-1 downto 0);
        
        -- Decoded Execution Outputs
        opcode_out      : out std_logic_vector(5 downto 0);
        
        -- Flattened Global Addresses (Thread ID concatenated with Register ID)
        rs1_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs2_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs3_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rd_addr_global  : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        
        -- Modifiers
        swiz_sel_a      : out swizzle_sel_t;
        swiz_sel_b      : out swizzle_sel_t;
        swiz_sel_c      : out swizzle_sel_t;
        inst_write_mask : out std_logic_vector(3 downto 0);
        cmp_invert      : out std_logic;
        cmp_swap        : out std_logic;
        
        -- Top-Level Control Signals
        wb_mux_sel      : out std_logic_vector(1 downto 0);
        reg_we          : out std_logic;
        
        -- Pipeline Control
        issue_valid     : out std_logic 
    );
end entity;

architecture rtl of instruction_issue is

    signal count : unsigned(5 downto 0);
    
    -- Explicitly initialize the record to prevent 'U' states
    signal latched_ctrl : fpu_ctrl_t := (
        opcode         => OP_NOP,
        rs1_addr_local => "00", rs2_addr_local => "00", rs3_addr_local => "00", rd_addr_local => "00",
        swiz_sel_a     => ("00", "00", "00", "00"), swiz_sel_b => ("00", "00", "00", "00"), swiz_sel_c => ("00", "00", "00", "00"),
        write_mask     => "0000", wb_mux_sel => "00", reg_we => '0',
        cmp_invert     => '0', cmp_swap => '0'
    );
    
    signal current_thread_int : std_logic_vector(THREAD_WIDTH-1 downto 0);
    signal ctrl_out           : fpu_ctrl_t;

begin

    -- ========================================================================
    -- 1. STATE MACHINE & INSTRUCTION LATCH
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count <= to_unsigned(32, 6); -- Idle state
                
                -- Explicitly reset the latch to prevent hazard propagation
                latched_ctrl.opcode         <= OP_NOP;
                latched_ctrl.rs1_addr_local <= "00";
                latched_ctrl.rs2_addr_local <= "00";
                latched_ctrl.rs3_addr_local <= "00";
                latched_ctrl.rd_addr_local  <= "00";
                latched_ctrl.swiz_sel_a     <= ("00", "00", "00", "00");
                latched_ctrl.swiz_sel_b     <= ("00", "00", "00", "00");
                latched_ctrl.swiz_sel_c     <= ("00", "00", "00", "00");
                latched_ctrl.write_mask     <= "0000";
                latched_ctrl.wb_mux_sel     <= "00";
                latched_ctrl.reg_we         <= '0';
                latched_ctrl.cmp_invert     <= '0';
                latched_ctrl.cmp_swap       <= '0';
            else
                -- Immediate latch and queue Thread 1
                if valid_in = '1' then
                    count <= to_unsigned(1, 6); 
                    latched_ctrl <= fpu_ctrl_in;
                    
                -- Keep incrementing until 32
                elsif count < 32 then
                    count <= count + 1;
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- 2. COMBINATIONAL OUTPUT MULTIPLEXING (Zero-Latency Issue)
    -- ========================================================================
    current_thread_int <= (others => '0') when valid_in = '1' 
                          else std_logic_vector(count(THREAD_WIDTH-1 downto 0));
                          
    ctrl_out           <= fpu_ctrl_in when valid_in = '1' else latched_ctrl;
    issue_valid        <= '1' when (valid_in = '1') or (count < 32) else '0';

    -- ========================================================================
    -- 3. SIGNAL ROUTING & GLOBAL ADDRESS GENERATION
    -- ========================================================================
    current_thread  <= current_thread_int;
    
    rs1_addr_global <= current_thread_int & ctrl_out.rs1_addr_local;
    rs2_addr_global <= current_thread_int & ctrl_out.rs2_addr_local;
    rs3_addr_global <= current_thread_int & ctrl_out.rs3_addr_local;
    rd_addr_global  <= current_thread_int & ctrl_out.rd_addr_local;

    opcode_out      <= ctrl_out.opcode;
    swiz_sel_a      <= ctrl_out.swiz_sel_a;
    swiz_sel_b      <= ctrl_out.swiz_sel_b;
    swiz_sel_c      <= ctrl_out.swiz_sel_c;
    inst_write_mask <= ctrl_out.write_mask;
    cmp_invert      <= ctrl_out.cmp_invert;
    cmp_swap        <= ctrl_out.cmp_swap;
    wb_mux_sel      <= ctrl_out.wb_mux_sel;
    reg_we          <= ctrl_out.reg_we;

end architecture rtl;
