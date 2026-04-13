-- ============================================================================
-- FILE: warp_unit.vhd
-- COMPONENT: warp_unit
-- ============================================================================
-- PURPOSE:
--   Self-contained execution unit for a single SIMT warp.  Encapsulates all
--   per-warp state: instruction fetch (IFU + PC + divergence stack), decode,
--   32-thread issue, FPU/ALU/RED execution, VRF, PRF, and the pipelined M10K
--   pixel buffer that accumulates packed RGBA pixels during OP_RETURN.
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
--   The warp_unit does NOT contain an Avalon master. Instead, it exposes a
--   synchronous read interface to the internal M10K pixel buffer for the MCU:
--     pixel_buf_valid : 1-cycle pulse after EXEC_WAIT completes for OP_RETURN.
--     pixel_buf_addr  : computed DDR3 byte addr: (fb_base_addr << 16) + warp_offset*4.
--     mem_stall       : Input from MCU; holds FSM in MEM_WAIT until burst completes.
--     pixel_rd_en     : MCU read enable to fetch from the M10K RAM.
--     pixel_rd_addr   : MCU read address (0 to 7) to sweep through the 8 burst beats.
--     pixel_rd_data   : Output 128-bit pixel data (4 packed pixels per beat).
--
-- PROCESSOR FSM STATES AND RATIONALE:
--   HALTED        : Idle state. Waits for `running='1'` (triggered by the external
--                   warp_start pulse). If do_reset_pc is set when starting, skips
--                   directly to ADVANCE_PC to force a jump to PC=0 before fetching.
--
--   FETCH_ADDR    : First fetch wait cycle. instruction_memory is an M10K BRAM,
--                   which has a 1-cycle registered-read latency. The address must
--                   be stable for one cycle before data appears. The IFU is
--                   STALLED here (ifu_stall='1') so the PC does not advance.
--
--   FETCH_DATA    : Second fetch wait cycle. The IFU pipeline has its own internal
--                   register stage before presenting instruction_out. Two cycles
--                   guarantee stable data at DECODE.
--
--   DECODE        : Instruction is stable on ifu_inst_out. The FSM inspects the
--                   instruction type and opcode to dispatch:
--                   SYS / OP_RETURN  → assert iss_valid_in='1' → EXEC_WAIT.
--                                      (running='0' is cleared concurrently).
--                   SYS / OP_BREAK   → assert warp_break, go to ADVANCE_PC.
--                                      (PC advances so BREAK is not re-hit).
--                   SYS / OP_FLUSH   → assert iss_valid_in='1' → EXEC_WAIT.
--                   CTRL             → IFU handles PC update combinationally;
--                                      go straight to ADVANCE_PC.
--                   FPU/ALU/IMM/RED  → assert iss_valid_in='1' → EXEC_WAIT.
--
--   EXEC_WAIT     : Waits for the barrel scheduler to finish issuing all 32 threads
--                   (iss_issue_valid='0'). If the instruction is OP_FLUSH, it also
--                   waits for the execution pipelines to fully drain 
--                   (exec_flush_active='0').
--                   SPECIAL CASE (OP_RETURN): Waits one extra cycle for 
--                   exec_mem_store_valid='0' to ensure the final thread's pixel
--                   is safely written into the synchronous M10K pixel buffer.
--                   Then pulses pixel_buf_valid='1' and proceeds to MEM_WAIT.
--                   ALL OTHERS: Proceed to ADVANCE_PC.
--
--   MEM_WAIT      : Handles backpressure from the external memory controller.
--                   Spins until mem_stall='0'. The MCU drives this combinationally,
--                   locking the FSM here while it bursts the pixel buffer to DDR3.
--                   Once complete, OP_RETURN transitions to HALTED.
--
--   ADVANCE_PC    : Deasserts ifu_stall for exactly ONE clock cycle. The IFU
--                   samples active_pc_ctrl to compute the next PC (branch taken /
--                   not-taken / sequential), then re-presents the updated PC.
--                   The FSM immediately returns to FETCH_ADDR.
--
-- INSTRUCTION LIFECYCLE & DATAPATH FLOW:
-- The warp_unit uses a highly decoupled, time-multiplexed SIMT pipeline. 
-- Rather than instantiating 32 physical execution lanes, it uses 1 physical 
-- lane and sweeps through the 32 threads sequentially over 32 clock cycles.
--
-- The life of a standard arithmetic instruction (FPU / ALU / IMM) looks like this:
--
-- 1. FETCH & DECODE (FSM controlled)
--    The FSM wakes up, drives `imem_addr`, waits 2 cycles for the M10K read 
--    latency, and receives `ifu_inst_out`. The combinational decoder immediately 
--    parses the instruction type, opcode, and local register addresses (0-15).
--
-- 2. ISSUE (Barrel Scheduler)
--    The FSM asserts `iss_valid_in` for exactly 1 cycle and enters `EXEC_WAIT`.
--    The `instruction_issue` unit latches the decoded control record. Over the 
--    next 32 clock cycles, it outputs the control record while incrementing the 
--    `current_thread` ID from 0 to 31. 
--    Crucially, the issuer concatenates the 5-bit thread ID with the 4-bit local 
--    register addresses to form flat 9-bit global addresses for the register files.
--
-- 3. OPERAND FETCH & SWIZZLE (Execution Unit - Stage 1)
--    The 9-bit global addresses drive the Vector (VRF) and Predicate (PRF) 
--    register files. One cycle later, data for the current thread emerges. 
--    The swizzle network applies broadcast/splat modifiers (e.g., .xxxx) to 
--    the vector operands before feeding them into the math pipelines.
--
-- 4. EXECUTION & LATENCY PADDING (Execution Unit - Stage 2..N)
--    The operands enter the specific functional unit (FPU lane, ALU lane, etc.).
--    Because different IP cores have different latencies (e.g., FADD takes 14 
--    cycles, FSQRT takes 28, ALU takes 2), every pipeline is padded with 
--    shift registers to exactly match `FPU_MAX_LATENCY`. 
--    This guarantees that the 32 results pop out of the execution unit in a 
--    perfect, contiguous 32-cycle burst, exactly FPU_MAX_LATENCY cycles after 
--    they were issued.
--
-- 5. WRITEBACK
--    The synchronized results hit the `writeback_controller`, which routes them 
--    to the VRF or PRF using the 9-bit global destination address delayed by 
--    the same shift-register pipeline. 
--    Once the 32nd thread's result is written, `exec_flush_active` drops to '0',
--    allowing the FSM to exit `EXEC_WAIT` and advance the PC.
--
-- INSTRUCTION CLASS EXCEPTIONS:
-- Not all instructions follow the standard 32-cycle math datapath:
--
-- * CTRL (Branches, Jumps, Calls):
--     Never reach the issuer. The decoder routes them directly to the IFU 
--     combinational logic. The FSM skips EXEC_WAIT, jumps straight to 
--     ADVANCE_PC, and the IFU immediately updates the Program Counter and 
--     Divergence Stack.
--
-- * RED (Reduction Math):
--     Sweeps through 32 threads like standard math, but instead of writing 32 
--     independent results, it feeds the operands into an accumulator IP core. 
--     Only the final accumulated result is written back to the VRF.
--
-- * SYS / FLUSH:
--     The issuer recognizes FLUSH and instantly fast-tracks its internal 
--     counter to 32, finishing issuance in 1 cycle (saving 31 dead cycles). 
--     However, the FSM remains stuck in EXEC_WAIT until `exec_flush_active` 
--     drops to '0', ensuring the 28-stage pipeline is entirely drained of 
--     previous instructions before continuing.
--
-- * SYS / RETURN:
--     Issues all 32 threads through the pipeline. Instead of doing math, the 
--     execution unit acts as a passthrough, snooping the source register and 
--     synchronously writing it into the M10K `pixel_buffer_ram`. Once complete, 
--     the FSM enters `MEM_WAIT` until the MCU flushes the buffer to DDR3, then 
--     halts. The DDR3 address uses fb_base_addr from warp_scheduler (not an
--     embedded immediate), enabling double-buffering without changing the
--     shader program.
--
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
        
        -- Shader Uniforms
        frame_width     : in  std_logic_vector(15 downto 0);
        frame_height    : in  std_logic_vector(15 downto 0);
        time_ms         : in  std_logic_vector(31 downto 0);

        -- ==========================================
        -- Pixel Buffer Output (to mcu_block_transfer)
        -- ==========================================
        mem_stall       : in  std_logic;                       -- MCU stall signal
        pixel_buf_valid : out std_logic;                       -- 1-cycle trigger: buffer full
        pixel_buf_addr  : out std_logic_vector(31 downto 0);   -- computed DDR3 byte address
        pixel_rd_en     : in  std_logic;                       -- MCU read enable
        pixel_rd_addr   : in  std_logic_vector(2 downto 0);    -- MCU read address (0-7)
        pixel_rd_data   : out std_logic_vector(127 downto 0)   -- MCU read data from M10K (128-bit)
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

    -- PC control mux (no do_force_pc in warp_unit — PC always resets to 0)
    signal active_pc_ctrl : pc_ctrl_t;

    -- Exec ctrl mux
    signal exec_mux_ctrl  : exec_ctrl_t;

    -- Issuer outputs
    signal iss_exec_record : exec_ctrl_t;
    signal iss_valid_in    : std_logic;
    signal iss_issue_valid : std_logic;
    signal iss_thread_id   : std_logic_vector(4 downto 0);
    signal iss_rs1_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs2_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rs3_global  : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);
    signal iss_rd_global   : std_logic_vector(VRF_ADDR_WIDTH-1 downto 0);

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

    -- Execution unit memory snoop outputs (for RETURN instruction)
    signal exec_mem_store_valid     : std_logic;
    signal exec_mem_store_data      : vector_t;
    signal exec_mem_store_thread_id : std_logic_vector(4 downto 0);

    -- Intermediate packing signal for pixel_buffer_ram
    signal packed_pixel_data        : std_logic_vector(31 downto 0);

    -- Computed physical DDR3 address:
    -- base_addr << 16 + reg_warp_offset * 4 (bytes per pixel).
    -- For OP_RETURN: base_addr comes from fb_base_addr (set by warp_scheduler,
    --   enables double-buffering by toggling between two framebuffer addresses).
    signal mem_phys_base : std_logic_vector(15 downto 0);
    signal mem_phys_addr : std_logic_vector(31 downto 0);

begin

    -- ========================================================================
    -- DDR3 ADDRESS CALCULATION
    -- ========================================================================
    -- Select base: RETURN uses fb_base_addr from the scheduler (supports double-
    -- buffering)
    mem_phys_base <= fb_base_addr;
    mem_phys_addr <= std_logic_vector(
        unsigned(std_logic_vector'(mem_phys_base & x"0000")) +
        unsigned(std_logic_vector'(reg_warp_offset(29 downto 0) & "00"))
    );

    -- ========================================================================
    -- PIXEL BUFFER OUTPUT WIRING
    -- ========================================================================
    pixel_buf_addr  <= mem_phys_addr;

    -- Expose IMEM address upward (IFU drives it, frame_processor wires it to shared IMEM)
    imem_addr <= ifu_imem_addr;

    -- warp_halted: level signal reflecting FSM state
    warp_halted <= '1' when state = HALTED else '0';

    -- ========================================================================
    -- PIXEL BUFFER RAM (M10K)
    -- ========================================================================
    -- Packs the low bytes of the snooped vector register into a single RGBA
    -- pixel. Assumes that each component of the vector is an integer from 0 to
    -- 255. Written synchronously during EXEC_WAIT as the barrel scheduler
    -- issues threads 0-31.
    packed_pixel_data <= exec_mem_store_data(3)(7 downto 0) &
                         exec_mem_store_data(2)(7 downto 0) &
                         exec_mem_store_data(1)(7 downto 0) &
                         exec_mem_store_data(0)(7 downto 0);

    u_pixel_buffer : entity work.pixel_buffer_ram
        port map (
            clk      => clk,
            we       => exec_mem_store_valid,
            wr_addr  => exec_mem_store_thread_id,
            wr_data  => packed_pixel_data,
            rd_en    => pixel_rd_en,
            rd_addr  => pixel_rd_addr,
            rd_data  => pixel_rd_data
        );


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
    process(state, running, ifu_inst_out, iss_issue_valid, exec_flush_active,
            exec_mem_store_valid, mem_stall)
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

                elsif v_inst_type = INST_TYPE_SYS then
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- Issue through barrel scheduler so execution_unit snoops the
                        -- source register and fills pixel_buffer_ram for all 32 threads.
                        -- After EXEC_WAIT the FSM goes to HALTED.
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
                    if ifu_inst_out(31 downto 26) = OP_RETURN then
                        -- Wait for exec_mem_store_valid='0' before signaling completion.
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
    -- WHY this mux exists here rather than inside the issuer or decoder:
    --   The instruction_decoder produces parallel, incompatible record types
    --   (fpu_ctrl_t, alu_ctrl_t, red_ctrl_t) because each instruction class
    --   packs its bits differently. The issuer and execution unit consume a
    --   single unified exec_ctrl_t. Merging here (at the top level) keeps
    --   the decoder and the issuer completely orthogonal.
    --
    -- WHY dec_fpu is the default (not an "unknown" value):
    --   SYS instructions (like FLUSH) go through the issuer. Their opcode
    --   field is in bits[31:26], which dec_fpu correctly exposes. All WE
    --   fields in dec_fpu are '0' for SYS instructions, so using dec_fpu as
    --   the default causes no accidental writebacks.
    --
    -- WHY ALU and IMM share the same branch:
    --   Both use dec_alu fields. The IMM class differs only in that
    --   dec_alu.is_load='1' and imm_data carries the payload. Note that
    --   shader uniforms (WIDTH, HEIGHT, TIME) also flow through the ALU
    --   branch because they are executed as integer scalar operations.
    --
    -- WHY RED does not override rs3_addr_local:
    --   The reduction unit only reads rs1 and rs2; rs3 is unused (left as
    --   the dec_fpu default, which is '0').
    --
    -- WHY SYS has a special override for OP_RETURN:
    --   OP_RETURN encodes the pixel buffer source register in bits [7:4]
    --   of the instruction word. The default FPU decoder would incorrectly
    --   extract rs1 from bits [17:14]. This block explicitly intercepts
    --   OP_RETURN, maps bits [7:4] to rs1_addr_local, and forces all write
    --   enables to '0' so the execution unit safely snoops the register
    --   for the M10K pixel buffer without corrupting the VRF.
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

        elsif v_type = INST_TYPE_SYS then
            if ifu_inst_out(31 downto 26) = OP_RETURN then
                -- RETURN reg: route the register index from bits[7:4] so the barrel
                -- scheduler reads the correct source register for the pixel buffer.
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
            alu_ctrl => dec_alu, pc_ctrl => dec_pc
        );

    -- Issuer: sequences through threads 0-31 one per cycle
    u_issue : entity work.instruction_issue
        generic map ( THREAD_WIDTH => THREAD_ID_WIDTH, REG_WIDTH => REG_WIDTH )
        port map (
            clk             => clk, 
            reset           => reset, 
            exec_ctrl_in    => exec_mux_ctrl,
            valid_in        => iss_valid_in, 
            current_thread  => iss_thread_id,
            rs1_addr_global => iss_rs1_global,
            rs2_addr_global => iss_rs2_global, 
            rs3_addr_global => iss_rs3_global,
            rd_addr_global  => iss_rd_global,
            exec_ctrl_out   => iss_exec_record,
            issue_valid     => iss_issue_valid
        );

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
            frame_width_in    => frame_width,
            frame_height_in   => frame_height,
            time_ms_in        => time_ms,
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
