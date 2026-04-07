library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity processor is
    generic (
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- ==========================================
        -- Avalon-MM Master (To DDR3 via Memory Unit)
        -- ==========================================
        avm_address       : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        avm_burstcount    : out std_logic_vector(7 downto 0);
        avm_write         : out std_logic;
        avm_writedata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_byteenable    : out std_logic_vector((DATA_WIDTH/8)-1 downto 0);
        avm_read          : out std_logic;
        avm_readdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        avm_readdatavalid : in  std_logic;
        avm_waitrequest   : in  std_logic;

        -- ==========================================
        -- Instruction Memory Programming Interface
        -- ==========================================
        prog_we           : in  std_logic;
        prog_wr_addr      : in  std_logic_vector(IMEM_ADDR_WIDTH-1 downto 0);
        prog_wr_data      : in  word_t;

        -- ==========================================
        -- CSR Avalon-MM Slave (External Control)
        -- ==========================================
        csr_address       : in  std_logic_vector(2 downto 0);
        csr_write         : in  std_logic;
        csr_writedata     : in  std_logic_vector(31 downto 0);
        csr_read          : in  std_logic;
        csr_readdata      : out std_logic_vector(31 downto 0);
        host_irq_out      : out std_logic
    );
end entity processor;

architecture structural of processor is

    -- ========================================================================
    -- PROCESSOR STATE MACHINE
    -- ========================================================================
    -- FIX: Added MEM_WAIT_START to handle the 1-cycle MCU acknowledgement delay
    type proc_state_t is (HALTED, FETCH_1, FETCH_2, DECODE, EXEC_WAIT, MEM_WAIT_START, MEM_WAIT, ADVANCE_PC);
    signal state, next_state : proc_state_t;

    -- ========================================================================
    -- CSR & CONTROL SIGNALS
    -- ========================================================================
    signal csr_run         : std_logic := '0';
    signal csr_start_pc    : std_logic_vector(15 downto 0) := (others => '0');
    signal csr_warp_offset : std_logic_vector(31 downto 0) := (others => '0');
    signal do_force_pc     : std_logic := '0';
    signal irq_pending     : std_logic := '0'; -- Interrupt raised
    signal break_hit       : std_logic := '0'; -- Breakpoint flag

    -- ========================================================================
    -- INTERCONNECT SIGNALS
    -- ========================================================================
    signal ifu_imem_addr   : std_logic_vector(PC_WIDTH-1 downto 0);
    signal imem_rd_data    : word_t;

    signal ifu_stall       : std_logic;
    signal ifu_inst_out    : word_t;
    signal ifu_exec_mask   : std_logic_vector(WARP_SIZE-1 downto 0);
    signal ifu_fetch_valid : std_logic;

    signal dec_fpu  : fpu_ctrl_t;
    signal dec_red  : red_ctrl_t;
    signal dec_alu  : alu_ctrl_t;
    signal dec_pc   : pc_ctrl_t;
    signal dec_mem  : mem_ctrl_t;
    
    signal active_pc_ctrl : pc_ctrl_t;
    signal exec_mux_ctrl  : exec_ctrl_t;
    
    signal iss_exec_record : exec_ctrl_t;
    signal iss_valid_in    : std_logic;
    signal iss_issue_valid : std_logic;
    signal iss_opcode      : std_logic_vector(5 downto 0);
    signal iss_thread_id   : std_logic_vector(4 downto 0);
    signal iss_rs1_global  : std_logic_vector(6 downto 0);
    signal iss_rs2_global  : std_logic_vector(6 downto 0);
    signal iss_rs3_global  : std_logic_vector(6 downto 0);
    signal iss_rd_global   : std_logic_vector(6 downto 0);
    
    signal iss_swiz_a      : swizzle_sel_t;
    signal iss_swiz_b      : swizzle_sel_t;
    signal iss_swiz_c      : swizzle_sel_t;
    signal iss_mask        : std_logic_vector(3 downto 0);
    signal iss_cmp_inv     : std_logic;
    signal iss_cmp_swap    : std_logic;
    signal iss_is_log      : std_logic;
    signal iss_is_ld       : std_logic;
    signal iss_imm         : std_logic_vector(15 downto 0);
    signal iss_wb_mux      : std_logic_vector(1 downto 0);
    signal iss_vrf_we      : std_logic;
    signal iss_prf_we      : std_logic;

    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    signal prf_mask_out                             : std_logic_vector(WARP_SIZE-1 downto 0);

    signal exec_wb_rd_addr : std_logic_vector(6 downto 0);
    signal exec_wb_vrf_data: vector_t;
    signal exec_wb_prf_data: std_logic_vector(3 downto 0);
    signal exec_wb_vrf_we  : std_logic;
    signal exec_wb_prf_we  : std_logic;
    signal exec_wb_mask    : std_logic_vector(3 downto 0);

    signal mem_op_valid    : std_logic;
    signal mem_stall       : std_logic;
    signal mem_vrf_rd_addr : std_logic_vector(6 downto 0);
    signal mem_vrf_rd_data : vector_t;
    signal mem_vrf_wr_addr : std_logic_vector(6 downto 0);
    signal mem_vrf_wr_data : vector_t;
    signal mem_vrf_we      : std_logic;

    signal exec_flush_active : std_logic;

begin

    -- ========================================================================
    -- SIMULATION DEBUG MONITOR
    -- ========================================================================
    -- synthesis translate_off
    process(clk)
    begin
        if rising_edge(clk) then
            -- We log ONLY when the FSM explicitly commits an instruction 
            -- from the Decode stage into the Execution Unit.
            if state = DECODE and csr_run = '1' then
                report "[EXEC COMMIT] PC: " & integer'image(to_integer(unsigned(ifu_imem_addr))) & 
                       " | Instr: 0x" & to_hstring(ifu_inst_out);
            end if;
        end if;
    end process;
    -- synthesis translate_on

    -- ========================================================================
    -- 1. CSR INTERFACE & HARDWARE HANDSHAKES
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                csr_run         <= '0';
                do_force_pc     <= '0';
                irq_pending     <= '0';
                break_hit       <= '0';
                csr_warp_offset <= (others => '0');
            else
                -- [A] HOST AVALON WRITES
                if csr_write = '1' then
                    case csr_address is
                        when CSR_ADDR_RUN => 
                            csr_run <= csr_writedata(0);
                            
                        when CSR_ADDR_START_PC => 
                            csr_start_pc <= csr_writedata(15 downto 0);
                            do_force_pc <= '1'; 
                            
                        when CSR_ADDR_IRQ_ACK => 
                            if csr_writedata(0) = '1' then irq_pending <= '0'; end if;
                        
                        when CSR_ADDR_BREAK =>
                            if csr_writedata(0) = '1' then break_hit <= '0'; end if;

                        when CSR_ADDR_WARP_OFFSET =>
                            csr_warp_offset <= csr_writedata;

                        -- Read-only addresses are ignored on write
                        when others => null;
                    end case;
                end if;
                
                -- Clear force PC flag once consumed by FSM
                if state = ADVANCE_PC and do_force_pc = '1' then 
                    do_force_pc <= '0'; 
                end if;

                -- [B] GPU HARDWARE EVENTS
                if state = DECODE and ifu_inst_out(3 downto 0) = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        csr_run <= '0';
                        
                    elsif ifu_inst_out(31 downto 26) = OP_BREAK then
                        csr_run <= '0';
                        break_hit <= '1';
                        
                    elsif ifu_inst_out(31 downto 26) = OP_INT then
                        irq_pending <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    -- ========================================================================
    -- CSR AVALON READ MULTIPLEXER
    -- ========================================================================
    csr_readdata <=
        x"0000000" & "000" & csr_run      when csr_address = CSR_ADDR_RUN else
        x"0000"    & csr_start_pc         when csr_address = CSR_ADDR_START_PC else
        x"0000000" & "000" & irq_pending  when csr_address = CSR_ADDR_IRQ_ACK else
        x"0000000" & "000" & break_hit    when csr_address = CSR_ADDR_BREAK else
        x"0000"    & ifu_imem_addr        when csr_address = CSR_ADDR_CURR_PC else
        x"00000000"                       when csr_address = CSR_ADDR_EXEC_MASK else -- Pad upper bits if WARP_SIZE is 32
        csr_warp_offset                   when csr_address = CSR_ADDR_WARP_OFFSET else
        (others => '0');

    host_irq_out <= irq_pending;

    -- ========================================================================
    -- 2. TOP-LEVEL STATE MACHINE (Two-Process Methodology)
    -- ========================================================================

    -- Process A: Synchronous State Register
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= HALTED;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    -- Process B: Combinational Next-State & Output Routing
    process(state, csr_run, do_force_pc, ifu_inst_out, iss_issue_valid, mem_stall, exec_flush_active)
        variable v_inst_type : std_logic_vector(3 downto 0);
    begin
        -- Default Combinational Outputs (Prevents Latches)
        next_state   <= state;
        ifu_stall    <= '1'; 
        iss_valid_in <= '0';
        mem_op_valid <= '0';

        v_inst_type := ifu_inst_out(3 downto 0);

        case state is
            when HALTED =>
                if csr_run = '1' then
                    if do_force_pc = '1' then next_state <= ADVANCE_PC; else next_state <= FETCH_1; end if;
                end if;

            when FETCH_1 => next_state <= FETCH_2;
            when FETCH_2 => next_state <= DECODE;

            when DECODE =>
                if csr_run = '0' then
                    next_state <= HALTED;
                    
                elsif v_inst_type = INST_TYPE_MEM then
                    mem_op_valid <= '1';            
                    next_state <= MEM_WAIT_START;
                    
                elsif v_inst_type = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        next_state <= HALTED;
                    elsif ifu_inst_out(31 downto 26) = OP_BREAK then
                        -- FIX: Advance the PC before halting! 
                        -- The FSM will step the PC, fetch the next instruction, 
                        -- and naturally halt upon arriving back at DECODE because csr_run is 0.
                        next_state <= ADVANCE_PC;
                    elsif ifu_inst_out(31 downto 26) = OP_FLUSH then
                        iss_valid_in <= '1';       
                        next_state <= EXEC_WAIT;   
                    else
                        -- OP_INT falls through here! It fires the IRQ but doesn't stop the PC!
                        next_state <= ADVANCE_PC;
                    end if;
                    
                elsif v_inst_type = INST_TYPE_CTRL then
                    next_state <= ADVANCE_PC;
                    
                elsif v_inst_type = INST_TYPE_FPU or v_inst_type = INST_TYPE_ALU or 
                      v_inst_type = INST_TYPE_IMM or v_inst_type = INST_TYPE_RED then
                    iss_valid_in <= '1';
                    next_state <= EXEC_WAIT;
                    
                else
                    next_state <= ADVANCE_PC;
                end if;

            when EXEC_WAIT =>
                -- Wait until the token finishes issuing AND clears the pipeline
                if iss_issue_valid = '0' and exec_flush_active = '0' then 
                    next_state <= ADVANCE_PC; 
                end if;

            when MEM_WAIT_START =>
                next_state <= MEM_WAIT;

            when MEM_WAIT =>
                if mem_stall = '0' then next_state <= ADVANCE_PC; end if;

            when ADVANCE_PC =>
                ifu_stall <= '0';                   -- Combinatorially unstall the IFU instantly
                next_state <= FETCH_1;

        end case;
    end process;

    active_pc_ctrl <= (
        branch_type   => BR_JMP, target_addr => csr_start_pc,
        predicate_sel => "00", predicate_mod => PRED_MOD_ANY
    ) when do_force_pc = '1' else dec_pc;

    -- ========================================================================
    -- 3. DECODER RECORD MULTIPLEXER
    -- ========================================================================
    process(ifu_inst_out, dec_fpu, dec_alu, dec_red)
        variable v_type : std_logic_vector(3 downto 0);
    begin
        v_type := ifu_inst_out(3 downto 0);
        
        exec_mux_ctrl.opcode         <= dec_fpu.opcode;
        exec_mux_ctrl.rs1_addr_local <= dec_fpu.rs1_addr_local;
        exec_mux_ctrl.rs2_addr_local <= dec_fpu.rs2_addr_local;
        exec_mux_ctrl.rs3_addr_local <= dec_fpu.rs3_addr_local;
        exec_mux_ctrl.rd_addr_local  <= dec_fpu.rd_addr_local;
        exec_mux_ctrl.swiz_sel_a     <= dec_fpu.swiz_sel_a;
        exec_mux_ctrl.swiz_sel_b     <= dec_fpu.swiz_sel_b;
        exec_mux_ctrl.swiz_sel_c     <= dec_fpu.swiz_sel_c;
        exec_mux_ctrl.write_mask     <= dec_fpu.write_mask;
        exec_mux_ctrl.wb_mux_sel     <= dec_fpu.wb_mux_sel;
        exec_mux_ctrl.cmp_invert     <= dec_fpu.cmp_invert;
        exec_mux_ctrl.cmp_swap       <= dec_fpu.cmp_swap;
        exec_mux_ctrl.is_logic_op    <= dec_fpu.is_logic_op;
        exec_mux_ctrl.vrf_we         <= dec_fpu.vrf_we;
        exec_mux_ctrl.prf_we         <= dec_fpu.prf_we;
        exec_mux_ctrl.is_load        <= '0';
        exec_mux_ctrl.imm_data       <= (others => '0');

        if v_type = INST_TYPE_ALU or v_type = INST_TYPE_IMM then
            exec_mux_ctrl.opcode         <= dec_alu.opcode;
            exec_mux_ctrl.rs1_addr_local <= dec_alu.rs1_addr_local;
            exec_mux_ctrl.rs2_addr_local <= dec_alu.rs2_addr_local;
            exec_mux_ctrl.rd_addr_local  <= dec_alu.rd_addr_local;
            exec_mux_ctrl.swiz_sel_a     <= dec_alu.swiz_sel_a;
            exec_mux_ctrl.swiz_sel_b     <= dec_alu.swiz_sel_b;
            exec_mux_ctrl.write_mask     <= dec_alu.write_mask;
            exec_mux_ctrl.wb_mux_sel     <= dec_alu.wb_mux_sel;
            exec_mux_ctrl.vrf_we         <= dec_alu.vrf_we;
            exec_mux_ctrl.prf_we         <= dec_alu.prf_we;
            exec_mux_ctrl.is_load        <= dec_alu.is_load;
            exec_mux_ctrl.imm_data       <= dec_alu.imm_data;
            
        elsif v_type = INST_TYPE_RED then
            exec_mux_ctrl.rs1_addr_local <= dec_red.rs1_addr_local;
            exec_mux_ctrl.rs2_addr_local <= dec_red.rs2_addr_local;
            exec_mux_ctrl.rd_addr_local  <= dec_red.rd_addr_local;
            exec_mux_ctrl.swiz_sel_a     <= dec_red.swiz_sel_a;
            exec_mux_ctrl.swiz_sel_b     <= dec_red.swiz_sel_b;
            exec_mux_ctrl.wb_mux_sel     <= dec_red.wb_mux_sel;
            exec_mux_ctrl.vrf_we         <= dec_red.vrf_we;
        end if;
    end process;


    -- ========================================================================
    -- 4. COMPONENT INSTANTIATIONS
    -- ========================================================================
    u_imem : entity work.instruction_memory
        generic map ( ADDR_WIDTH => IMEM_ADDR_WIDTH )
        port map (
            clk      => clk,
            we       => prog_we,
            wr_addr  => prog_wr_addr,
            wr_data  => prog_wr_data,
            rd_addr  => ifu_imem_addr(IMEM_ADDR_WIDTH-1 downto 0),
            rd_data  => imem_rd_data
        );

    u_ifu : entity work.instruction_fetch_unit
        generic map ( PC_WIDTH => PC_WIDTH, WARP_SIZE => WARP_SIZE )
        port map (
            clk             => clk, reset => reset,
            imem_addr       => ifu_imem_addr,
            imem_data       => imem_rd_data,
            imem_valid      => '1',
            stall           => ifu_stall,
            pc_ctrl         => active_pc_ctrl,
            predicate_mask  => prf_mask_out,
            instruction_out => ifu_inst_out,
            exec_mask_out   => ifu_exec_mask,
            fetch_valid     => ifu_fetch_valid
        );

    u_decode : entity work.instruction_decoder
        port map (
            instruction => ifu_inst_out, fpu_ctrl => dec_fpu, red_ctrl => dec_red,
            alu_ctrl => dec_alu, pc_ctrl => dec_pc, mem_ctrl => dec_mem
        );

    u_issue : entity work.instruction_issue
        port map (
            clk             => clk, reset => reset, exec_ctrl_in => exec_mux_ctrl,
            valid_in        => iss_valid_in, current_thread => iss_thread_id,
            opcode_out      => iss_opcode, rs1_addr_global => iss_rs1_global,
            rs2_addr_global => iss_rs2_global, rs3_addr_global => iss_rs3_global,
            rd_addr_global  => iss_rd_global, swiz_sel_a => iss_swiz_a,
            swiz_sel_b      => iss_swiz_b, swiz_sel_c => iss_swiz_c,
            inst_write_mask => iss_mask, cmp_invert => iss_cmp_inv,
            cmp_swap        => iss_cmp_swap, is_logic_op => iss_is_log,
            is_load         => iss_is_ld, imm_data => iss_imm,
            wb_mux_sel      => iss_wb_mux, vrf_we => iss_vrf_we,
            prf_we          => iss_prf_we, issue_valid => iss_issue_valid
        );

    iss_exec_record.opcode      <= iss_opcode;
    iss_exec_record.swiz_sel_a  <= iss_swiz_a;
    iss_exec_record.swiz_sel_b  <= iss_swiz_b;
    iss_exec_record.swiz_sel_c  <= iss_swiz_c;
    iss_exec_record.write_mask  <= iss_mask;
    iss_exec_record.cmp_invert  <= iss_cmp_inv;
    iss_exec_record.cmp_swap    <= iss_cmp_swap;
    iss_exec_record.is_logic_op <= iss_is_log;
    iss_exec_record.is_load     <= iss_is_ld;
    iss_exec_record.imm_data    <= iss_imm;
    iss_exec_record.wb_mux_sel  <= iss_wb_mux;
    iss_exec_record.vrf_we      <= iss_vrf_we;
    iss_exec_record.prf_we      <= iss_prf_we;
    iss_exec_record.rs1_addr_local <= "00"; iss_exec_record.rs2_addr_local <= "00";
    iss_exec_record.rs3_addr_local <= "00"; iss_exec_record.rd_addr_local  <= "00";

    u_exec : entity work.execution_unit
        port map (
            clk               => clk, reset => reset, exec_ctrl_in => iss_exec_record,
            valid_in          => iss_issue_valid, inst_type_in => ifu_inst_out(3 downto 0),
            red_mode_in       => dec_red.red_mode, red_mask_in => dec_red.red_mask,
            rd_addr_global_in => iss_rd_global, vrf_rs1_data => vrf_rs1_data,
            vrf_rs2_data      => vrf_rs2_data, vrf_rs3_data => vrf_rs3_data,
            prf_rs1_data      => prf_rs1_data, prf_rs2_data => prf_rs2_data,
            warp_offset_in    => csr_warp_offset, thread_id_in => iss_thread_id,
            wb_rd_addr_out    => exec_wb_rd_addr, wb_vrf_data_out => exec_wb_vrf_data,
            wb_prf_data_out   => exec_wb_prf_data, wb_vrf_we_out => exec_wb_vrf_we,
            wb_prf_we_out     => exec_wb_prf_we, wb_mask_out => exec_wb_mask,
            flush_active_out  => exec_flush_active
        );

    u_mem : entity work.memory_unit
        generic map ( WARP_SIZE => WARP_SIZE, ADDR_WIDTH => ADDR_WIDTH, DATA_WIDTH => DATA_WIDTH )
        port map (
            clk               => clk, reset => reset, mem_op_valid => mem_op_valid,
            is_store          => dec_mem.is_store, base_addr => dec_mem.base_addr & x"0000", 
            offset_reg_idx    => dec_mem.offset_reg_idx, dest_src_reg_idx => dec_mem.dest_src_reg_idx,
            exec_mask         => ifu_exec_mask, mem_stall => mem_stall,
            reg_read_addr     => mem_vrf_rd_addr, reg_read_data => mem_vrf_rd_data,
            reg_write_addr    => mem_vrf_wr_addr, reg_write_data => mem_vrf_wr_data,
            reg_write_en      => mem_vrf_we, avm_address => avm_address,
            avm_burstcount    => avm_burstcount, avm_write => avm_write,
            avm_writedata     => avm_writedata, avm_byteenable => avm_byteenable,
            avm_read          => avm_read, avm_readdata => avm_readdata,
            avm_readdatavalid => avm_readdatavalid, avm_waitrequest => avm_waitrequest
        );

    u_vrf : entity work.vector_reg_file
        port map (
            clk => clk, reset => reset, rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs3_addr => iss_rs3_global, rs1_data => vrf_rs1_data, rs2_data => vrf_rs2_data,
            rs3_data => vrf_rs3_data, rd_addr_A => exec_wb_rd_addr, rd_data_A => exec_wb_vrf_data,
            write_mask_A => exec_wb_mask, we_A => exec_wb_vrf_we, rd_addr_B => mem_vrf_rd_addr,
            rd_data_B => mem_vrf_rd_data, wr_addr_B => mem_vrf_wr_addr, wr_data_B => mem_vrf_wr_data,
            write_mask_B => "1111", we_B => mem_vrf_we
        );

    u_prf : entity work.predicate_reg_file
        port map (
            clk => clk, reset => reset, rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs1_data => prf_rs1_data, rs2_data => prf_rs2_data, wr_addr => exec_wb_rd_addr,
            wr_data => exec_wb_prf_data, we => exec_wb_prf_we, wr_mask => exec_wb_mask,
            ifu_pred_sel => dec_pc.predicate_sel, ifu_pred_mod => dec_pc.predicate_mod,
            ifu_mask_out => prf_mask_out
        );

end architecture structural;
