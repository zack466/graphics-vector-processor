-- ============================================================================
-- instruction_issue.vhd — SIMT Barrel Scheduler / Instruction Issuer
-- ============================================================================
--
-- WHY THIS COMPONENT EXISTS
-- -------------------------
-- In a SIMT (Single Instruction, Multiple Threads) processor, every instruction
-- must execute independently for each of the 32 threads.  Rather than replicating
-- 32 execution lanes (expensive in area), this design uses a single execution
-- pipeline that is time-multiplexed across all 32 threads.  The instruction
-- issuer is the "barrel" that drives that time-multiplexing: it takes one
-- decoded instruction and replays it 32 consecutive cycles, once per thread,
-- sweeping the thread index from 0 to 31.
--
-- The processor FSM enters EXEC_WAIT after dispatching an instruction and waits
-- for issue_valid to drop to '0'.  This means the FSM cannot fetch the next
-- instruction until all 32 threads of the current one have been issued —
-- preserving the in-order, single-issue contract of the barrel scheduler.
--
-- HOW TO USE
-- ----------
-- 1. Assert valid_in='1' for exactly ONE clock cycle with a fully decoded
--    exec_ctrl_t record on exec_ctrl_in.  Thread 0 is issued on that very cycle
--    (count is reset to 1 so the combinational output already sees thread 0).
-- 2. Deassert valid_in.  The issuer autonomously replays the latched instruction
--    for threads 1..31 over the next 31 cycles.
-- 3. Monitor issue_valid.  When it falls to '0', all 32 threads have been issued
--    and the pipeline is ready for the next instruction.
-- 4. FLUSH: present valid_in='1' with opcode=OP_FLUSH.  The issuer immediately
--    sets count=32 instead of 1, so FLUSH takes only 1 cycle — it carries no
--    per-thread register addresses, so replay is unnecessary.
--
-- GLOBAL ADDRESS FORMATION
-- ------------------------
-- The VRF and PRF use 9-bit addresses: {thread_id[4:0], reg[3:0]}.
-- The issuer forms these by concatenating current_thread_int with each local
-- 4-bit register field from the latched control record.  This means every
-- register "slot" 0-15 appears 32 times in the flat register file, once per
-- thread, with no extra hardware needed for bank selection.
--
-- PORT DESCRIPTIONS
-- -----------------
-- clk             : System clock.  All registered logic is rising-edge triggered.
-- reset           : Synchronous active-high reset.  Sets count=32 (idle) and
--                   clears latched_ctrl to NOP.
-- exec_ctrl_in    : Fully decoded instruction control record from the decode stage.
--                   Sampled only when valid_in='1'.
-- valid_in        : Pulse (one cycle wide) that signals a new instruction has
--                   arrived.  Drives thread-0 issue immediately on the same cycle.
-- current_thread  : 5-bit thread index being issued this cycle (0..31).
-- rs1_addr_global : 9-bit global address of source register 1 for current thread.
-- rs2_addr_global : 9-bit global address of source register 2 for current thread.
-- rs3_addr_global : 9-bit global address of source register 3 for current thread.
-- rd_addr_global  : 9-bit global address of destination register for current thread.
-- exec_ctrl_out   : Forwarded execution control record. The issuer passes this 
--                   through directly (muxing between the live input on cycle 0 
--                   and the latched copy on cycles 1-31) so the execution unit 
--                   receives identical control parameters for every thread.
-- issue_valid     : '1' while any thread of the current instruction is being
--                   issued.  Held high for 32 cycles (1 for FLUSH).  The
--                   processor FSM spins in EXEC_WAIT until this falls to '0'.
--
-- TIMING / LATENCY
-- ----------------
-- Throughput : 1 instruction per 32 cycles (1 cycle for FLUSH).
-- Latency    : Thread 0 is issued combinationally on the same cycle as
--              valid_in='1'.  Threads 1-31 follow on the next 31 rising edges.
-- issue_valid deasserts on the cycle AFTER thread 31 is issued (count reaches
-- 32 on a rising edge; the combinational check count<32 then evaluates false).
-- ============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_issue is
    generic (
        THREAD_WIDTH : integer := 5;  -- 32 threads
        REG_WIDTH    : integer := 4   -- 16 vector registers per thread
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;
        exec_ctrl_in    : in  exec_ctrl_t;
        valid_in        : in  std_logic;
        
        current_thread  : out std_logic_vector(THREAD_WIDTH-1 downto 0);
        rs1_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs2_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs3_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rd_addr_global  : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        
        exec_ctrl_out   : out exec_ctrl_t;
        
        issue_valid     : out std_logic 
    );
end entity;

architecture rtl of instruction_issue is

    -- count tracks which thread is NEXT to be issued on the following clock edge.
    -- Range 0..31: actively issuing.  Value 32: idle (no replay in progress).
    -- Initialised to 32 so the issuer is silent on power-up before the first
    -- valid_in pulse arrives.
    signal count : unsigned(5 downto 0);

    -- latched_ctrl holds the control record for the instruction currently being
    -- replayed.  It is updated on the same cycle valid_in='1' so that threads
    -- 1..31 see the correct opcode and register addresses without requiring the
    -- decode stage to hold its outputs stable.
    signal latched_ctrl : exec_ctrl_t := (
        opcode         => OP_NOP,
        rs1_addr_local => "0000", rs2_addr_local => "0000", rs3_addr_local => "0000", rd_addr_local => "0000",
        swiz_sel_a     => SWIZ_PASS, swiz_sel_b => SWIZ_PASS, swiz_sel_c => SWIZ_PASS,
        write_mask     => "0000", wb_mux_sel => "00",
        cmp_invert     => '0', cmp_swap => '0',
        is_logic_op    => '0', vrf_we => '0', prf_we => '0',
        is_load        => '0', imm_data => (others => '0')
    );

    -- current_thread_int is the combinational thread index visible on the
    -- outputs this cycle.  It is driven before the registered count increments,
    -- so thread 0 appears on the outputs on the same cycle as valid_in='1'.
    signal current_thread_int : std_logic_vector(THREAD_WIDTH-1 downto 0);

    -- ctrl_out selects between the live exec_ctrl_in (thread 0, valid_in cycle)
    -- and latched_ctrl (threads 1..31).  This avoids a one-cycle gap where
    -- thread 0 would have to wait for the latch to settle.
    signal ctrl_out           : exec_ctrl_t;

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset to count=32 (idle).  The issuer will not drive issue_valid
                -- until a valid_in pulse resets count to 0 or 1.
                count <= to_unsigned(32, 6);

                latched_ctrl.opcode         <= OP_NOP;
                latched_ctrl.rs1_addr_local <= "0000"; latched_ctrl.rs2_addr_local <= "0000";
                latched_ctrl.rs3_addr_local <= "0000"; latched_ctrl.rd_addr_local  <= "0000";
                latched_ctrl.swiz_sel_a     <= SWIZ_PASS;
                latched_ctrl.swiz_sel_b     <= SWIZ_PASS;
                latched_ctrl.swiz_sel_c     <= SWIZ_PASS;
                latched_ctrl.write_mask     <= "0000"; latched_ctrl.wb_mux_sel     <= "00";
                latched_ctrl.cmp_invert     <= '0'; latched_ctrl.cmp_swap       <= '0';
                latched_ctrl.is_logic_op    <= '0'; latched_ctrl.vrf_we         <= '0';
                latched_ctrl.prf_we         <= '0'; latched_ctrl.is_load        <= '0';
                latched_ctrl.imm_data       <= (others => '0');
            else
                if valid_in = '1' then
                    -- OP_FLUSH is a pipeline-control token, not a data instruction.
                    -- It carries no per-thread register addresses, so replaying it
                    -- 32 times would waste 31 cycles. Setting count=32 here means 
                    -- it issues in exactly 1 clock cycle.
                    if exec_ctrl_in.opcode = OP_FLUSH then
                        count <= to_unsigned(32, 6);
                    else
                        -- For all normal instructions (including OP_RETURN): 
                        -- thread 0 is handled combinationally this cycle. Starting 
                        -- count at 1 means the registered path picks up at thread 1 
                        -- on the next edge, giving the full 32-thread replay.
                        -- NOTE: OP_RETURN *must* do the full 32 cycles so the 
                        -- execution unit can snoop the data and fill the pixel buffer.
                        count <= to_unsigned(1, 6);
                    end if;
                    -- Latch the incoming control record so it survives after the
                    -- decode stage de-asserts valid_in.
                    latched_ctrl <= exec_ctrl_in;
                elsif count < 32 then
                    -- Replay in progress: advance to the next thread.
                    -- When count reaches 32 the issue_valid combinational expression
                    -- evaluates to '0', signalling the FSM that all threads are done.
                    count <= count + 1;
                end if;
            end if;
        end if;
    end process;

    -- Thread 0 is presented combinationally on the valid_in cycle (all-zeros).
    -- Threads 1-31 are driven from the registered count, which was set to 1
    -- on the previous edge.  The two-to-one mux here avoids any single-cycle
    -- bubble between thread 0 and thread 1.
    current_thread_int <= (others => '0') when valid_in = '1'
                          else std_logic_vector(count(THREAD_WIDTH-1 downto 0));

    -- On the valid_in cycle, bypass the latch so thread 0 sees the incoming
    -- instruction directly — the latch write won't be visible until next cycle.
    ctrl_out    <= exec_ctrl_in when valid_in = '1' else latched_ctrl;

    -- issue_valid is '1' whenever any thread of the current instruction is
    -- being driven onto the output ports.  The processor FSM polls this signal
    -- to decide when it is safe to fetch the next instruction.
    issue_valid <= '1' when (valid_in = '1') or (count < 32) else '0';

    -- Form 9-bit global addresses by prepending the current 5-bit thread index
    -- to each 4-bit local register field.  This is the complete address into
    -- the flat 512-entry VRF/PRF — no banking or thread-select logic elsewhere.
    current_thread  <= current_thread_int;
    rs1_addr_global <= current_thread_int & ctrl_out.rs1_addr_local;
    rs2_addr_global <= current_thread_int & ctrl_out.rs2_addr_local;
    rs3_addr_global <= current_thread_int & ctrl_out.rs3_addr_local;
    rd_addr_global  <= current_thread_int & ctrl_out.rd_addr_local;

    -- Directly forward the entire control record structure to the execution unit
    exec_ctrl_out   <= ctrl_out;

end architecture rtl;
