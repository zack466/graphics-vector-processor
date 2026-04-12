-- ============================================================================
-- COMPONENT: warp_unit
-- ============================================================================
-- PURPOSE:
--   Self-contained execution unit for a single SIMT warp.  Encapsulates all
--   per-warp state: instruction fetch (IFU + PC + divergence stack), decode,
--   32-thread issue, FPU/ALU/RED execution, VRF, PRF, and the pixel snoop
--   buffer that accumulates packed RGBA pixels during a MEM instruction's
--   EXEC_WAIT phase.
--
--   warp_unit intentionally has NO host CSR interface and NO embedded Avalon
--   memory controller.  The host-facing control (frame iteration, warp_offset
--   sequencing) is the responsibility of warp_scheduler.  The Avalon burst
--   write is the responsibility of mcu_block_transfer + avm_burst_bridge at
--   the frame_processor level.  This separation allows the scheduler to
--   context-switch between multiple warp_unit instances (latency hiding) and
--   allows the MCU to service multiple warps' pixel buffers independently.
--
-- INSTRUCTION MEMORY:
--   The IFU drives imem_addr (a PC-width address) outward.  The caller
--   (frame_processor or a testbench) owns the instruction memory and connects
--   imem_data back.  All warps share the same program image, so a single
--   IMEM at the frame_processor level serves all warp_unit instances.
--
-- WARP CONTROL:
--   warp_start  : 1-cycle pulse that starts execution.  The warp latches
--                 warp_offset on the same cycle and begins fetching.
--   warp_halted : level signal, '1' while the warp FSM is in HALTED state.
--                 Deasserts as soon as the warp starts running (the cycle
--                 after warp_start).  Re-asserts when OP_RETURN executes.
--   warp_break  : 1-cycle registered pulse when OP_BREAK executes.
--
-- PIXEL BUFFER HANDSHAKE:
--   The warp_unit does NOT contain mcu_block_transfer.  Instead it exposes:
--     pixel_buf_valid : 1-cycle pulse after EXEC_WAIT completes for a MEM/RETURN
--                       instruction.
--     pixel_buf_addr  : computed DDR3 byte address:
--                         STORE — (embedded base_addr << 16) + warp_offset*4
--                         RETURN — (fb_base_addr << 16) + warp_offset*4
--     pixel_buf_data  : flat 1024-bit snoop buffer.
--     pixel_exec_mask : ifu_exec_mask (for MCU byte-enable calculation).
--     mem_stall       : input from external MCU; FSM holds MEM_WAIT until '0'.
--
-- RETURN INSTRUCTION (combined store + halt):
--   RETURN reg encodes the source register index in bits[7:4] of the instruction
--   word (same position as STORE's dest_src_reg_idx, but in the SYS type field).
--   Execution: issues through barrel scheduler → EXEC_WAIT (fills pixel_snoop) →
--   MEM_WAIT (holds until mem_stall='0') → HALTED.
--   The DDR3 address uses fb_base_addr from warp_scheduler (not an embedded
--   immediate), enabling double-buffering without changing the shader program.
--
-- FSM STATES:
--   Identical to processor.vhd: HALTED, FETCH_ADDR, FETCH_DATA, DECODE,
--   EXEC_WAIT, MEM_WAIT, ADVANCE_PC.  The only change is that the HALTED
--   guard uses the internal `running` register (set by warp_start, cleared
--   by OP_RETURN) instead of csr_run from a CSR slave.
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity warp_unit is
    generic (
        PC_WIDTH        : integer := 16;
        IMEM_ADDR_WIDTH : integer := 8;
        WARP_SIZE       : integer := 32;
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 128;
        REG_WIDTH       : integer := 4
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- ==========================================
        -- Instruction Memory Read Port (IMEM is external / shared)
        -- ==========================================
        imem_addr       : out std_logic_vector(PC_WIDTH-1 downto 0);
        imem_data       : in  std_logic_vector(31 downto 0);

        -- ==========================================
        -- Warp Control (from warp_scheduler)
        -- ==========================================
        warp_start      : in  std_logic;   -- 1-cycle pulse: begin execution from PC 0
        warp_offset     : in  std_logic_vector(31 downto 0); -- pixel index for DDR3 addr calc
        fb_base_addr    : in  std_logic_vector(15 downto 0); -- framebuffer base (upper 16 bits of DDR3 byte addr)
        warp_halted     : out std_logic;   -- '1' while FSM is in HALTED state
        warp_break      : out std_logic;   -- 1-cycle pulse when OP_BREAK executes

        -- ==========================================
        -- Pixel Buffer Output (to mcu_block_transfer)
        -- ==========================================
        pixel_buf_valid : out std_logic;                       -- 1-cycle trigger: buffer full
        pixel_buf_addr  : out std_logic_vector(31 downto 0);  -- computed DDR3 byte address
        pixel_buf_data  : out std_logic_vector(1023 downto 0);-- 32 packed pixels (flat)
        pixel_exec_mask : out std_logic_vector(WARP_SIZE-1 downto 0); -- per-thread enable mask
        mem_stall       : in  std_logic    -- MCU busy; hold FSM in MEM_WAIT
    );
end entity warp_unit;

architecture structural of warp_unit is

    -- ========================================================================
    -- PROCESSOR FSM STATES
    -- ========================================================================
    type proc_state_t is (HALTED, FETCH_ADDR, FETCH_DATA, DECODE, EXEC_WAIT, MEM_WAIT, ADVANCE_PC);
    signal state, next_state : proc_state_t;

    -- ========================================================================
    -- WARP CONTROL REGISTERS
    -- ========================================================================
    -- running: replaces csr_run.  Set by warp_start, cleared by OP_RETURN.
    signal running         : std_logic := '0';
    -- reg_warp_offset: latched from warp_offset on warp_start.
    signal reg_warp_offset : std_logic_vector(31 downto 0) := (others => '0');
    -- do_reset_pc: set by warp_start, cleared after ADVANCE_PC applies the
    -- PC=0 jump.  Ensures every warp run starts from the first instruction
    -- regardless of where the previous run's PC was left.
    signal do_reset_pc     : std_logic := '0';

    -- ========================================================================
    -- INTERCONNECT SIGNALS
    -- ========================================================================

    -- Instruction fetch
    signal ifu_imem_addr   : std_logic_vector(PC_WIDTH-1 downto 0);
    signal ifu_stall       : std_logic;
    signal ifu_inst_out    : std_logic_vector(31 downto 0);
    signal ifu_exec_mask   : std_logic_vector(WARP_SIZE-1 downto 0);
    signal ifu_fetch_valid : std_logic;

    -- Decoder outputs
    signal dec_fpu  : fpu_ctrl_t;
    signal dec_red  : red_ctrl_t;
    signal dec_alu  : alu_ctrl_t;
    signal dec_pc   : pc_ctrl_t;
    signal dec_mem  : mem_ctrl_t;

    -- PC control mux (no do_force_pc in warp_unit — PC always resets to 0)
    signal active_pc_ctrl : pc_ctrl_t;

    -- Exec ctrl mux
    signal exec_mux_ctrl  : exec_ctrl_t;

    -- Issuer outputs
    signal iss_exec_record : exec_ctrl_t;
    signal iss_valid_in    : std_logic;
    signal iss_issue_valid : std_logic;
    signal iss_opcode      : std_logic_vector(5 downto 0);
    signal iss_thread_id   : std_logic_vector(4 downto 0);
    signal iss_rs1_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs2_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs3_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rd_global   : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
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

    -- VRF/PRF read data
    signal vrf_rs1_data, vrf_rs2_data, vrf_rs3_data : vector_t;
    signal prf_rs1_data, prf_rs2_data               : std_logic_vector(3 downto 0);
    signal prf_mask_out                             : std_logic_vector(WARP_SIZE-1 downto 0);

    -- Execution unit writeback
    signal exec_wb_rd_addr  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal exec_wb_vrf_data : vector_t;
    signal exec_wb_prf_data : std_logic_vector(3 downto 0);
    signal exec_wb_vrf_we   : std_logic;
    signal exec_wb_prf_we   : std_logic;
    signal exec_wb_mask     : std_logic_vector(3 downto 0);
    signal exec_flush_active: std_logic;

    -- Execution unit memory snoop outputs
    signal exec_mem_store_valid     : std_logic;
    signal exec_mem_store_data      : vector_t;
    signal exec_mem_store_thread_id : std_logic_vector(4 downto 0);

    -- Pixel snoop buffer (32 entries × 32-bit packed RGBA)
    type snoop_buf_t is array(0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal pixel_snoop : snoop_buf_t := (others => (others => '0'));

    -- Computed physical DDR3 address:
    -- base_addr << 16 + reg_warp_offset * 4 (bytes per pixel).
    -- For OP_STORE: base_addr comes from the instruction's embedded immediate.
    -- For OP_RETURN: base_addr comes from fb_base_addr (set by warp_scheduler,
    --   enables double-buffering by toggling between two framebuffer addresses).
    signal mem_phys_base : std_logic_vector(15 downto 0);
    signal mem_phys_addr : std_logic_vector(31 downto 0);

begin

    -- ========================================================================
    -- DDR3 ADDRESS CALCULATION
    -- ========================================================================
    -- Select base: RETURN uses fb_base_addr from the scheduler (supports double-
    -- buffering); STORE uses the embedded instruction immediate.
    mem_phys_base <= fb_base_addr when ifu_inst_out(31 downto 26) = OP_RETURN
                     else dec_mem.base_addr;
    mem_phys_addr <= std_logic_vector(
        unsigned(std_logic_vector'(mem_phys_base & x"0000")) +
        unsigned(std_logic_vector'(reg_warp_offset(29 downto 0) & "00"))
    );

    -- ========================================================================
    -- PIXEL BUFFER OUTPUT WIRING
    -- ========================================================================
    pixel_buf_addr  <= mem_phys_addr;
    pixel_exec_mask <= ifu_exec_mask;

    -- Expose IMEM address upward (IFU drives it, frame_processor wires it to shared IMEM)
    imem_addr <= ifu_imem_addr;

    -- warp_halted: level signal reflecting FSM state
    warp_halted <= '1' when state = HALTED else '0';

    -- ========================================================================
    -- PIXEL SNOOP BUFFER
    -- ========================================================================
    -- Accumulates packed RGBA pixels from execution unit writeback events.
    -- Written during EXEC_WAIT as the barrel scheduler issues threads 0-31.
    -- Not cleared between warps — overwritten each time.
    process(clk)
    begin
        if rising_edge(clk) then
            if exec_mem_store_valid = '1' then
                pixel_snoop(to_integer(unsigned(exec_mem_store_thread_id))) <=
                    exec_mem_store_data(3)(7 downto 0) &
                    exec_mem_store_data(2)(7 downto 0) &
                    exec_mem_store_data(1)(7 downto 0) &
                    exec_mem_store_data(0)(7 downto 0);
            end if;
        end if;
    end process;

    -- Flatten snoop buffer into pixel_buf_data output.
    -- pixel_buf_data[i*32+31 : i*32] = pixel_snoop(i) = thread i's packed pixel.
    gen_pixel_buf : for i in 0 to WARP_SIZE-1 generate
        pixel_buf_data(i*32+31 downto i*32) <= pixel_snoop(i);
    end generate;

    -- ========================================================================
    -- WARP CONTROL REGISTERS
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                running         <= '0';
                reg_warp_offset <= (others => '0');
                do_reset_pc     <= '0';
                warp_break      <= '0';
            else
                -- Latch offset and start running on warp_start pulse.
                -- Also set do_reset_pc so the FSM applies a JMP-to-0 before
                -- the first FETCH_ADDR, ensuring each warp run starts from
                -- instruction address 0 regardless of where the previous run ended.
                if warp_start = '1' then
                    running         <= '1';
                    reg_warp_offset <= warp_offset;
                    do_reset_pc     <= '1';
                end if;

                -- Clear do_reset_pc once the forced jump has been applied.
                -- ADVANCE_PC is the cycle the IFU samples active_pc_ctrl.
                if state = ADVANCE_PC and do_reset_pc = '1' then
                    do_reset_pc <= '0';
                end if;

                -- OP_RETURN: halt the warp
                if state = DECODE and ifu_inst_out(3 downto 0) = INST_TYPE_SYS and
                   ifu_inst_out(31 downto 26) = OP_RETURN then
                    running <= '0';
                end if;

                -- OP_BREAK: halt + emit 1-cycle pulse
                if state = DECODE and ifu_inst_out(3 downto 0) = INST_TYPE_SYS and
                   ifu_inst_out(31 downto 26) = OP_BREAK then
                    running    <= '0';
                    warp_break <= '1';
                else
                    warp_break <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- FSM — Process A: Synchronous State Register
    -- ========================================================================
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

    -- ========================================================================
    -- FSM — Process B: Combinational Next-State & Output Routing
    -- ========================================================================
    process(state, running, ifu_inst_out, iss_issue_valid, mem_stall, exec_flush_active,
            exec_mem_store_valid)
        variable v_inst_type : std_logic_vector(3 downto 0);
    begin
        -- Defaults
        next_state      <= state;
        ifu_stall       <= '1';
        iss_valid_in    <= '0';
        pixel_buf_valid <= '0';

        v_inst_type := ifu_inst_out(3 downto 0);

        case state is
            when HALTED =>
                -- When warp_start fires, running and do_reset_pc are both set.
                -- Go through ADVANCE_PC first so the IFU applies the JMP-to-0
                -- (via active_pc_ctrl) before we start fetching, ensuring PC=0.
                if running = '1' then
                    if do_reset_pc = '1' then
                        next_state <= ADVANCE_PC;
                    else
                        next_state <= FETCH_ADDR;
                    end if;
                end if;

            when FETCH_ADDR => next_state <= FETCH_DATA;
            when FETCH_DATA => next_state <= DECODE;

            when DECODE =>
                if running = '0' then
                    next_state <= HALTED;

                elsif v_inst_type = INST_TYPE_MEM then
                    iss_valid_in <= '1';
                    next_state   <= EXEC_WAIT;

                elsif v_inst_type = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- Issue through barrel scheduler so execution_unit snoops the
                        -- source register and fills pixel_snoop for all 32 threads.
                        -- After EXEC_WAIT the FSM goes to MEM_WAIT (stall until the
                        -- MCU accepts the pixel buffer), then HALTED.
                        -- running is cleared synchronously this cycle (control process).
                        iss_valid_in <= '1';
                        next_state   <= EXEC_WAIT;
                    elsif ifu_inst_out(31 downto 26) = OP_BREAK then
                        -- running cleared in control process; PC advances so BREAK
                        -- is not re-hit if the warp is somehow restarted.
                        next_state <= ADVANCE_PC;
                    elsif ifu_inst_out(31 downto 26) = OP_FLUSH then
                        iss_valid_in <= '1';
                        next_state   <= EXEC_WAIT;
                    else
                        -- OP_INT or other non-halting SYS: just advance PC
                        next_state <= ADVANCE_PC;
                    end if;

                elsif v_inst_type = INST_TYPE_CTRL then
                    next_state <= ADVANCE_PC;

                elsif v_inst_type = INST_TYPE_FPU or v_inst_type = INST_TYPE_ALU or
                      v_inst_type = INST_TYPE_IMM or v_inst_type = INST_TYPE_RED then
                    iss_valid_in <= '1';
                    next_state   <= EXEC_WAIT;

                else
                    next_state <= ADVANCE_PC;
                end if;

            when EXEC_WAIT =>
                if iss_issue_valid = '0' and
                   (ifu_inst_out(31 downto 26) /= OP_FLUSH or exec_flush_active = '0') then
                    if ifu_inst_out(3 downto 0) = INST_TYPE_MEM or
                       ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- WHY wait for exec_mem_store_valid='0':
                        -- When iss_issue_valid drops (thread 31 has been issued),
                        -- the S1 stage still holds thread 31's snoop data for one
                        -- more cycle (exec_mem_store_valid='1').  pixel_snoop[31]
                        -- is not written until the rising edge of that cycle.
                        -- If we assert pixel_buf_valid immediately, the MCU latches
                        -- pixel_buf_data before pixel_snoop[31] is updated, producing
                        -- a stale (wrong) value for thread 31.  Waiting one extra
                        -- cycle (until exec_mem_store_valid='0') ensures all 32
                        -- snoop entries are committed before the MCU reads the buffer.
                        -- This logic applies equally to OP_RETURN (combined store+halt).
                        if exec_mem_store_valid = '0' then
                            pixel_buf_valid <= '1';
                            next_state      <= MEM_WAIT;
                        end if;
                    else
                        next_state <= ADVANCE_PC;
                    end if;
                end if;

            when MEM_WAIT =>
                if mem_stall = '0' then
                    -- RETURN reg: MCU has accepted the pixel buffer; warp halts.
                    -- STORE: continue to ADVANCE_PC (RETURN is a separate instruction).
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        next_state <= HALTED;
                    else
                        next_state <= ADVANCE_PC;
                    end if;
                end if;

            when ADVANCE_PC =>
                ifu_stall  <= '0';
                next_state <= FETCH_ADDR;

        end case;
    end process;

    -- ========================================================================
    -- DECODER RECORD MULTIPLEXER
    -- ========================================================================
    -- Identical logic to processor.vhd: picks the right exec_ctrl_t fields
    -- from dec_fpu / dec_alu / dec_red based on the current instruction type.
    -- WHY dec_fpu is the default: see processor.vhd for full rationale.
    process(ifu_inst_out, dec_fpu, dec_alu, dec_red)
        variable v_type : std_logic_vector(3 downto 0);
    begin
        v_type := ifu_inst_out(3 downto 0);

        -- Default: FPU fields
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

        elsif v_type = INST_TYPE_MEM then
            -- For MEM instructions, route the source register through the issuer
            -- so the execution unit snoops its writeback and fills pixel_snoop.
            exec_mux_ctrl.opcode         <= ifu_inst_out(31 downto 26);
            exec_mux_ctrl.rs1_addr_local <= dec_mem.dest_src_reg_idx;
            exec_mux_ctrl.rd_addr_local  <= dec_mem.dest_src_reg_idx;
            exec_mux_ctrl.rs2_addr_local <= dec_fpu.rs2_addr_local;
            exec_mux_ctrl.rs3_addr_local <= dec_fpu.rs3_addr_local;
            exec_mux_ctrl.swiz_sel_a     <= dec_fpu.swiz_sel_a;
            exec_mux_ctrl.swiz_sel_b     <= dec_fpu.swiz_sel_b;
            exec_mux_ctrl.swiz_sel_c     <= dec_fpu.swiz_sel_c;
            exec_mux_ctrl.write_mask     <= dec_fpu.write_mask;
            exec_mux_ctrl.wb_mux_sel     <= dec_fpu.wb_mux_sel;
            exec_mux_ctrl.cmp_invert     <= dec_fpu.cmp_invert;
            exec_mux_ctrl.cmp_swap       <= dec_fpu.cmp_swap;
            exec_mux_ctrl.vrf_we         <= '0';
            exec_mux_ctrl.prf_we         <= '0';
            exec_mux_ctrl.is_logic_op    <= dec_fpu.is_logic_op;
            exec_mux_ctrl.is_load        <= '0';
            exec_mux_ctrl.imm_data       <= (others => '0');

        elsif v_type = INST_TYPE_SYS then
            if ifu_inst_out(31 downto 26) = OP_RETURN then
                -- RETURN reg: route the register index from bits[7:4] so the barrel
                -- scheduler reads the correct source register for the pixel snoop buffer.
                -- The FPU decoder would extract rs1 from bits[17:14] (wrong for SYS),
                -- so we explicitly override here.  WE fields stay '0' (no writeback).
                exec_mux_ctrl.rs1_addr_local <= ifu_inst_out(7 downto 4);
                exec_mux_ctrl.rd_addr_local  <= ifu_inst_out(7 downto 4);
                exec_mux_ctrl.vrf_we         <= '0';
                exec_mux_ctrl.prf_we         <= '0';
            end if;
            -- For FLUSH: dec_fpu defaults are sufficient (opcode=OP_FLUSH, all WE='0').
        end if;
    end process;

    -- ========================================================================
    -- COMPONENT INSTANTIATIONS
    -- ========================================================================

    -- active_pc_ctrl: inject a synthetic JMP to PC=0 when do_reset_pc='1'.
    -- This ensures each warp run starts from instruction 0 regardless of
    -- where the previous run's PC was left.  PRED_MOD_ANY ensures the jump
    -- is unconditional (always taken).
    -- When do_reset_pc='0', pass dec_pc through normally for branches.
    active_pc_ctrl <= (
        branch_type   => BR_JMP, target_addr => (others => '0'),
        predicate_sel => "00", predicate_mod => PRED_MOD_ANY
    ) when do_reset_pc = '1' else dec_pc;

    u_ifu : entity work.instruction_fetch_unit
        generic map ( PC_WIDTH => PC_WIDTH, WARP_SIZE => WARP_SIZE )
        port map (
            clk             => clk, reset => reset,
            imem_addr       => ifu_imem_addr,
            imem_data       => imem_data,
            imem_valid      => '1',
            stall           => ifu_stall,
            pc_ctrl         => active_pc_ctrl,
            predicate_mask  => prf_mask_out,
            instruction_out => ifu_inst_out,
            exec_mask_out   => ifu_exec_mask,
            fetch_valid     => ifu_fetch_valid
        );

    -- Purely combinational instruction decoder
    u_decode : entity work.instruction_decoder
        port map (
            instruction => ifu_inst_out, fpu_ctrl => dec_fpu, red_ctrl => dec_red,
            alu_ctrl => dec_alu, pc_ctrl => dec_pc, mem_ctrl => dec_mem
        );

    -- Issuer: sequences through threads 0-31 one per cycle
    u_issue : entity work.instruction_issue
        generic map ( THREAD_WIDTH => THREAD_ID_WIDTH, REG_WIDTH => REG_WIDTH )
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

    -- Re-pack issuer flat outputs into record for execution unit
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
    iss_exec_record.rs1_addr_local <= "0000";
    iss_exec_record.rs2_addr_local <= "0000";
    iss_exec_record.rs3_addr_local <= "0000";
    iss_exec_record.rd_addr_local  <= "0000";

    -- Execution unit: FPU/ALU/RED pipelines + writeback + mem-snoop outputs
    u_exec : entity work.execution_unit
        port map (
            clk               => clk, reset => reset, exec_ctrl_in => iss_exec_record,
            valid_in          => iss_issue_valid, inst_type_in => ifu_inst_out(3 downto 0),
            red_mode_in       => dec_red.red_mode, red_mask_in => dec_red.red_mask,
            rd_addr_global_in => iss_rd_global, vrf_rs1_data => vrf_rs1_data,
            vrf_rs2_data      => vrf_rs2_data, vrf_rs3_data => vrf_rs3_data,
            prf_rs1_data      => prf_rs1_data, prf_rs2_data => prf_rs2_data,
            warp_offset_in    => reg_warp_offset, thread_id_in => iss_thread_id,
            wb_rd_addr_out    => exec_wb_rd_addr, wb_vrf_data_out => exec_wb_vrf_data,
            wb_prf_data_out   => exec_wb_prf_data, wb_vrf_we_out => exec_wb_vrf_we,
            wb_prf_we_out     => exec_wb_prf_we, wb_mask_out => exec_wb_mask,
            flush_active_out  => exec_flush_active,
            mem_store_valid   => exec_mem_store_valid,
            mem_store_data    => exec_mem_store_data,
            mem_store_thread_id => exec_mem_store_thread_id
        );

    -- Vector register file: 512 entries (32 threads × 16 registers)
    u_vrf : entity work.vector_reg_file
        generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH )
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs3_addr => iss_rs3_global, rs1_data => vrf_rs1_data,
            rs2_data => vrf_rs2_data, rs3_data => vrf_rs3_data,
            rd_addr_A => exec_wb_rd_addr, rd_data_A => exec_wb_vrf_data,
            write_mask_A => exec_wb_mask, we_A => exec_wb_vrf_we,
            rd_addr_B => (others => '0'), rd_data_B => open,
            wr_addr_B => (others => '0'), wr_data_B => (others => (others => '0')),
            write_mask_B => "1111", we_B => '0'
        );

    -- Predicate register file: 512 entries, same address space as VRF
    u_prf : entity work.predicate_reg_file
        generic map ( ADDR_WIDTH => VRF_ADDR_WIDTH )
        port map (
            clk => clk, reset => reset,
            rs1_addr => iss_rs1_global, rs2_addr => iss_rs2_global,
            rs1_data => prf_rs1_data, rs2_data => prf_rs2_data,
            wr_addr => exec_wb_rd_addr, wr_data => exec_wb_prf_data,
            we => exec_wb_prf_we, wr_mask => exec_wb_mask,
            ifu_pred_sel => dec_pc.predicate_sel, ifu_pred_mod => dec_pc.predicate_mod,
            ifu_mask_out => prf_mask_out
        );

end architecture structural;
