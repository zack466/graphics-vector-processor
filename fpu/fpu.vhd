--------------------------------------------------------------------------------
-- TOP LEVEL PROCESSOR ENTITY & ARCHITECTURE
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vector_types_pkg.all;

entity graphics_vector_processor is
    generic (
        THREAD_WIDTH : integer := 5; -- 32 Threads
        REG_WIDTH    : integer := 2; -- 4 vector registers per thread
        MAX_LATENCY  : integer := 24 -- Rigid pipeline depth
    );
    port (
        clk             : in std_logic;
        reset           : in std_logic;
        
        -- Instruction Fetch Interface
        instruction     : in word_t;
        fetch_valid     : in std_logic;
        current_thread  : out std_logic_vector(THREAD_WIDTH-1 downto 0)
    );
end entity;

architecture Structural of graphics_vector_processor is

    constant GLOBAL_ADDR_WIDTH : integer := THREAD_WIDTH + REG_WIDTH;

    -- ========================================================================
    -- INTERNAL SIGNALS
    -- ========================================================================
    
    -- Instruction Issuer Decoded Outputs
    signal dec_opcode      : std_logic_vector(5 downto 0);
    signal rs1_global      : std_logic_vector(GLOBAL_ADDR_WIDTH-1 downto 0);
    signal rs2_global      : std_logic_vector(GLOBAL_ADDR_WIDTH-1 downto 0);
    signal rs3_global      : std_logic_vector(GLOBAL_ADDR_WIDTH-1 downto 0);
    signal rd_global       : std_logic_vector(GLOBAL_ADDR_WIDTH-1 downto 0);
    
    signal swiz_sel_a      : swizzle_sel_t;
    signal swiz_sel_b      : swizzle_sel_t;
    signal swiz_sel_c      : swizzle_sel_t;
    signal inst_write_mask : std_logic_vector(3 downto 0);
    signal issue_valid     : std_logic;
    signal dec_wb_mux_sel  : std_logic_vector(1 downto 0);
    signal dec_reg_we      : std_logic;
    signal sfu_target_lane : std_logic_vector(1 downto 0);
    
    -- Register File & Swizzle Outputs
    signal reg_rs1_data, reg_rs2_data, reg_rs3_data : vector_t;
    signal swiz_a_data, swiz_b_data, swiz_c_data    : vector_t;
    
    -- Execution Unit Outputs (Arriving MAX_LATENCY cycles later)
    signal fpu_results   : vector_t;
    signal sfu_result    : word_t;
    signal sfu_dest_lane : std_logic_vector(1 downto 0);
    signal red_result    : word_t;
    
    -- Final Writeback signal
    signal wb_data : vector_t;

    -- ========================================================================
    -- CONTROL DELAY LINE (Shift Registers)
    -- ========================================================================
    -- These arrays carry the writeback instructions down the pipeline alongside the data
    type addr_array_t is array (0 to MAX_LATENCY-1) of std_logic_vector(GLOBAL_ADDR_WIDTH-1 downto 0);
    type mask_array_t is array (0 to MAX_LATENCY-1) of std_logic_vector(3 downto 0);
    type mux_array_t  is array (0 to MAX_LATENCY-1) of std_logic_vector(1 downto 0);
    
    signal delay_rd_addr   : addr_array_t;
    signal delay_mask      : mask_array_t;
    signal delay_wb_mux    : mux_array_t;
    signal delay_we        : std_logic_vector(MAX_LATENCY-1 downto 0);

begin

    -- 1. INSTRUCTION ISSUE (Round-Robin Barrel Scheduler)
    u_issue : entity work.instruction_issue
        generic map ( THREAD_WIDTH => THREAD_WIDTH, REG_WIDTH => REG_WIDTH )
        port map (
            clk             => clk,
            reset           => reset,
            instruction     => instruction,
            fetch_valid     => fetch_valid,
            current_thread  => current_thread,
            opcode_out      => dec_opcode,
            rs1_addr_global => rs1_global,
            rs2_addr_global => rs2_global,
            rs3_addr_global => rs3_global,
            rd_addr_global  => rd_global,
            swiz_sel_a      => swiz_sel_a,
            swiz_sel_b      => swiz_sel_b,
            swiz_sel_c      => swiz_sel_c,
            inst_write_mask => inst_write_mask,
            issue_valid     => issue_valid
            -- Note: Assume wb_mux_sel, reg_we, and sfu_target_lane are also decoded here
        );

    -- 2. CENTRAL REGISTER FILE (Massively Multithreaded)
    u_reg_file : entity work.vector_reg_file
        generic map ( ADDR_WIDTH => GLOBAL_ADDR_WIDTH )
        port map (
            clk        => clk,
            reset      => reset,
            rs1_addr   => rs1_global,
            rs2_addr   => rs2_global,
            rs3_addr   => rs3_global,
            rs1_data   => reg_rs1_data,
            rs2_data   => reg_rs2_data,
            rs3_data   => reg_rs3_data,
            -- Write port uses the DELAYED signals that match the math output
            rd_addr    => delay_rd_addr(MAX_LATENCY-1),
            rd_data    => wb_data,           
            write_mask => delay_mask(MAX_LATENCY-1),   
            we         => delay_we(MAX_LATENCY-1)
        );

    -- 3. SWIZZLE NETWORKS
    u_swiz_a : entity work.swizzle_network port map ( vec_in => reg_rs1_data, swizzle_sel => swiz_sel_a, vec_out => swiz_a_data );
    u_swiz_b : entity work.swizzle_network port map ( vec_in => reg_rs2_data, swizzle_sel => swiz_sel_b, vec_out => swiz_b_data );
    u_swiz_c : entity work.swizzle_network port map ( vec_in => reg_rs3_data, swizzle_sel => swiz_sel_c, vec_out => swiz_c_data );

    -- 4. QUAD-FPU LANES
    GEN_FPU_LANES: for i in 0 to 3 generate
        u_fpu_lane : entity work.fpu_lane
            generic map ( MAX_LATENCY => MAX_LATENCY )
            port map (
                clk       => clk,
                reset     => reset,
                opcode    => dec_opcode,
                valid_in  => issue_valid,
                op_a      => swiz_a_data(i),
                op_b      => swiz_b_data(i),
                op_c      => swiz_c_data(i),
                result    => fpu_results(i)
                -- comp_flag and valid_out omitted for brevity
            );
    end generate GEN_FPU_LANES;

    -- 5. SHARED SCALAR SFU
    u_shared_sfu : entity work.shared_sfu
        generic map ( MAX_LATENCY => MAX_LATENCY )
        port map (
            clk             => clk,
            reset           => reset,
            opcode          => dec_opcode,
            valid_in        => issue_valid,
            -- The compiler swizzles the required scalar into the 'X' slot (index 0)
            op_in           => swiz_a_data(0), 
            target_lane_in  => sfu_target_lane,
            result          => sfu_result,
            target_lane_out => sfu_dest_lane
        );

    -- 6. VECTOR REDUCTION UNIT
    u_vector_reduction : entity work.vector_reduction_unit
        generic map ( MAX_LATENCY => MAX_LATENCY )
        port map (
            clk       => clk,
            reset     => reset,
            opcode    => dec_opcode,
            valid_in  => issue_valid,
            vec_a     => swiz_a_data,
            vec_b     => swiz_b_data,
            result    => red_result
        );

    -- ========================================================================
    -- PIPELINE SYNCHRONIZATION: The Control Delay Line
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                delay_we <= (others => '0');
            else
                -- Inject current decoded instructions into stage 0
                delay_rd_addr(0) <= rd_global;
                delay_mask(0)    <= inst_write_mask;
                delay_wb_mux(0)  <= dec_wb_mux_sel;
                delay_we(0)      <= dec_reg_we and issue_valid;
                
                -- Shift all control signals down by 1 cycle
                for i in 1 to MAX_LATENCY-1 loop
                    delay_rd_addr(i) <= delay_rd_addr(i-1);
                    delay_mask(i)    <= delay_mask(i-1);
                    delay_wb_mux(i)  <= delay_wb_mux(i-1);
                    delay_we(i)      <= delay_we(i-1);
                end loop;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- WRITEBACK MULTIPLEXER (Using Delayed Selection)
    -- ========================================================================
    process(delay_wb_mux(MAX_LATENCY-1), fpu_results, red_result, sfu_result, sfu_dest_lane)
    begin
        wb_data <= fpu_results; -- Default
        
        -- Use the control signal that was delayed to match this exact clock cycle
        case delay_wb_mux(MAX_LATENCY-1) is
            when "00" => 
                wb_data <= fpu_results;
                
            when "01" => 
                wb_data(0) <= red_result;
                wb_data(1) <= red_result;
                wb_data(2) <= red_result;
                wb_data(3) <= red_result;
                
            when "10" => 
                wb_data(0) <= (others => '0');
                wb_data(1) <= (others => '0');
                wb_data(2) <= (others => '0');
                wb_data(3) <= (others => '0');
                
                if sfu_dest_lane = "00" then wb_data(0) <= sfu_result; end if;
                if sfu_dest_lane = "01" then wb_data(1) <= sfu_result; end if;
                if sfu_dest_lane = "10" then wb_data(2) <= sfu_result; end if;
                if sfu_dest_lane = "11" then wb_data(3) <= sfu_result; end if;
                
            when others =>
                wb_data <= fpu_results;
        end case;
    end process;

end architecture Structural;
