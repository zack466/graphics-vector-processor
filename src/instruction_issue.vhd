library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity instruction_issue is
    generic (
        THREAD_WIDTH : integer := 5;  -- 32 threads
        REG_WIDTH    : integer := 2   -- 4 vector registers
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;
        exec_ctrl_in    : in  exec_ctrl_t;
        valid_in        : in  std_logic;
        
        current_thread  : out std_logic_vector(THREAD_WIDTH-1 downto 0);
        opcode_out      : out std_logic_vector(5 downto 0);
        rs1_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs2_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rs3_addr_global : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        rd_addr_global  : out std_logic_vector((THREAD_WIDTH + REG_WIDTH) - 1 downto 0);
        
        swiz_sel_a      : out swizzle_sel_t;
        swiz_sel_b      : out swizzle_sel_t;
        swiz_sel_c      : out swizzle_sel_t;
        inst_write_mask : out std_logic_vector(3 downto 0);
        cmp_invert      : out std_logic;
        cmp_swap        : out std_logic;
        is_logic_op     : out std_logic;
        is_load         : out std_logic;
        imm_data        : out std_logic_vector(15 downto 0);
        wb_mux_sel      : out std_logic_vector(1 downto 0);
        vrf_we          : out std_logic;
        prf_we          : out std_logic;

        issue_valid     : out std_logic 
    );
end entity;

architecture rtl of instruction_issue is

    signal count : unsigned(5 downto 0);

    signal latched_ctrl : exec_ctrl_t := (
        opcode         => OP_NOP,
        rs1_addr_local => "00", rs2_addr_local => "00", rs3_addr_local => "00", rd_addr_local => "00",
        swiz_sel_a     => SWIZ_PASS, swiz_sel_b => SWIZ_PASS, swiz_sel_c => SWIZ_PASS,
        write_mask     => "0000", wb_mux_sel => "00", 
        cmp_invert     => '0', cmp_swap => '0',
        is_logic_op    => '0', vrf_we => '0', prf_we => '0',
        is_load        => '0', imm_data => (others => '0')
    );

    signal current_thread_int : std_logic_vector(THREAD_WIDTH-1 downto 0);
    signal ctrl_out           : exec_ctrl_t;

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count <= to_unsigned(32, 6); 
                
                latched_ctrl.opcode         <= OP_NOP;
                latched_ctrl.rs1_addr_local <= "00"; latched_ctrl.rs2_addr_local <= "00";
                latched_ctrl.rs3_addr_local <= "00"; latched_ctrl.rd_addr_local  <= "00";
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
                    -- FIX: If it's a flush token, instantly set count to 32 so it only takes 1 clock cycle to issue!
                    if exec_ctrl_in.opcode = OP_FLUSH then
                        count <= to_unsigned(32, 6);
                    else
                        count <= to_unsigned(1, 6);
                    end if;
                    latched_ctrl <= exec_ctrl_in;
                elsif count < 32 then
                    count <= count + 1;
                end if;
            end if;
        end if;
    end process;

    current_thread_int <= (others => '0') when valid_in = '1' 
                          else std_logic_vector(count(THREAD_WIDTH-1 downto 0));

    ctrl_out    <= exec_ctrl_in when valid_in = '1' else latched_ctrl;
    issue_valid <= '1' when (valid_in = '1') or (count < 32) else '0';

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
    is_logic_op     <= ctrl_out.is_logic_op;
    is_load         <= ctrl_out.is_load;  
    imm_data        <= ctrl_out.imm_data; 
    wb_mux_sel      <= ctrl_out.wb_mux_sel;
    vrf_we          <= ctrl_out.vrf_we;
    prf_we          <= ctrl_out.prf_we;

end architecture rtl;
