------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     2025 Sep 28      Zack Huang      Initial revision
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- This entity is a wrapper around a dual-port RAM that provides a hierarchical
-- register file structure. It organizes the memory into warps, threads, and
-- registers, with the dimensions specified by generics. The interface allows
-- addressing registers using separate warp, thread, and register IDs.
entity Register_File is
    generic (
        G_NUM_WARPS        : positive := 8;    -- Number of warps in the register file
        G_THREADS_PER_WARP : positive := 32;   -- Number of threads per warp
        G_REGS_PER_THREAD  : positive := 32;   -- Number of registers per thread
        G_DATA_WIDTH       : positive := 32    -- Data width of each register
    );
    port (
        -- System Inputs
        i_clk   : in  std_logic;    -- System clock
        i_rst   : in  std_logic;    -- Asynchronous reset

        -- Port A Interface
        i_we_a        : in  std_logic;                                          -- Write enable for Port A
        i_re_a        : in  std_logic;                                          -- Read enable for Port A
        i_warp_id_a   : in  natural range 0 to G_NUM_WARPS - 1;                 -- Warp index for Port A
        i_thread_id_a : in  natural range 0 to G_THREADS_PER_WARP - 1;          -- Thread index for Port A
        i_reg_id_a    : in  natural range 0 to G_REGS_PER_THREAD - 1;           -- Register index for Port A
        i_data_a      : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);        -- Data input for Port A
        o_data_a      : out std_logic_vector(G_DATA_WIDTH - 1 downto 0);        -- Registered data output for Port A

        -- Port B Interface
        i_we_b        : in  std_logic;                                          -- Write enable for Port B
        i_re_b        : in  std_logic;                                          -- Read enable for Port B
        i_warp_id_b   : in  natural range 0 to G_NUM_WARPS - 1;                 -- Warp index for Port B
        i_thread_id_b : in  natural range 0 to G_THREADS_PER_WARP - 1;          -- Thread index for Port B
        i_reg_id_b    : in  natural range 0 to G_REGS_PER_THREAD - 1;           -- Register index for Port B
        i_data_b      : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);        -- Data input for Port B
        o_data_b      : out std_logic_vector(G_DATA_WIDTH - 1 downto 0)         -- Registered data output for Port B
    );
end entity Register_File;

architecture rtl of Register_File is

    -- VHDL-2008 allows use of math_real for synthesis
    use ieee.math_real.all;

    -- This function calculates the minimum number of bits required to represent a
    -- given number of unique values (i.e., ceil(log2(N))).
    function ceil_log2(val: positive) return natural is
    begin
        return integer(ceil(log2(real(val))));
    end function ceil_log2;

    -- Calculate the bit width required for each index
    constant C_WARP_ID_WIDTH    : natural := ceil_log2(G_NUM_WARPS);
    constant C_THREAD_ID_WIDTH  : natural := ceil_log2(G_THREADS_PER_WARP);
    constant C_REG_ID_WIDTH     : natural := ceil_log2(G_REGS_PER_THREAD);

    -- The total address width is the sum of the individual index widths.
    -- This implies a memory layout of [warp_id | thread_id | reg_id].
    constant C_TOTAL_ADDR_WIDTH : natural := C_WARP_ID_WIDTH + C_THREAD_ID_WIDTH + C_REG_ID_WIDTH;

    -- Signals for the concatenated addresses for the underlying RAM
    signal s_addr_a : std_logic_vector(C_TOTAL_ADDR_WIDTH - 1 downto 0);    -- Port A linear address
    signal s_addr_b : std_logic_vector(C_TOTAL_ADDR_WIDTH - 1 downto 0);    -- Port B linear address

    -- Signals to hold the vector versions of the natural inputs
    signal s_warp_id_a_v   : std_logic_vector(C_WARP_ID_WIDTH - 1 downto 0);
    signal s_thread_id_a_v : std_logic_vector(C_THREAD_ID_WIDTH - 1 downto 0);
    signal s_reg_id_a_v    : std_logic_vector(C_REG_ID_WIDTH - 1 downto 0);
    signal s_warp_id_b_v   : std_logic_vector(C_WARP_ID_WIDTH - 1 downto 0);
    signal s_thread_id_b_v : std_logic_vector(C_THREAD_ID_WIDTH - 1 downto 0);
    signal s_reg_id_b_v    : std_logic_vector(C_REG_ID_WIDTH - 1 downto 0);

begin

    -- Convert natural-typed indices to std_logic_vector for concatenation.
    -- The width of each vector is determined by the ceil_log2 function.
    s_warp_id_a_v   <= std_logic_vector(to_unsigned(i_warp_id_a, C_WARP_ID_WIDTH));
    s_thread_id_a_v <= std_logic_vector(to_unsigned(i_thread_id_a, C_THREAD_ID_WIDTH));
    s_reg_id_a_v    <= std_logic_vector(to_unsigned(i_reg_id_a, C_REG_ID_WIDTH));

    s_warp_id_b_v   <= std_logic_vector(to_unsigned(i_warp_id_b, C_WARP_ID_WIDTH));
    s_thread_id_b_v <= std_logic_vector(to_unsigned(i_thread_id_b, C_THREAD_ID_WIDTH));
    s_reg_id_b_v    <= std_logic_vector(to_unsigned(i_reg_id_b, C_REG_ID_WIDTH));

    -- Generate the linear RAM address by concatenating the hierarchical indices.
    -- The memory is laid out with registers grouped by thread, and threads grouped by warp.
    s_addr_a <= s_warp_id_a_v & s_thread_id_a_v & s_reg_id_a_v;
    s_addr_b <= s_warp_id_b_v & s_thread_id_b_v & s_reg_id_b_v;

    -- Instantiate the dual-port RAM component. This wrapper translates the
    -- hierarchical addressing scheme into the linear address required by the RAM.
    u_ram : entity work.Ram_Dual_Port
        generic map (
            G_DATA_WIDTH => G_DATA_WIDTH,
            G_ADDR_WIDTH => C_TOTAL_ADDR_WIDTH
        )
        port map (
            i_clk    => i_clk,
            i_rst    => i_rst,
            i_we_a   => i_we_a,
            i_re_a   => i_re_a,
            i_addr_a => s_addr_a,
            i_data_a => i_data_a,
            o_data_a => o_data_a,
            i_we_b   => i_we_b,
            i_re_b   => i_re_b,
            i_addr_b => s_addr_b,
            i_data_b => i_data_b,
            o_data_b => o_data_b
        );

end architecture rtl;
