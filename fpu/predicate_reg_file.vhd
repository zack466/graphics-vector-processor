library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vector_types_pkg.all;
use work.processor_constants_pkg.all;

entity predicate_reg_file is
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        
        -- ==========================================
        -- FPU MATH PORTS (Scalar 4-bit access)
        -- ==========================================
        rs1_addr     : in  std_logic_vector(6 downto 0); -- [6:2] Thread, [1:0] P-Reg
        rs2_addr     : in  std_logic_vector(6 downto 0);
        rs1_data     : out std_logic_vector(3 downto 0);
        rs2_data     : out std_logic_vector(3 downto 0);

        wr_addr      : in  std_logic_vector(6 downto 0);
        wr_data      : in  std_logic_vector(3 downto 0);
        we           : in  std_logic;
        wr_mask      : in  std_logic_vector(3 downto 0); -- Allows partial X,Y,Z,A updates

        -- ==========================================
        -- IFU PORT (Warp-Wide 32-bit collapse)
        -- ==========================================
        ifu_pred_sel : in  std_logic_vector(1 downto 0); -- Select p0, p1, p2, or p3
        ifu_pred_mod : in  std_logic_vector(1 downto 0); -- ANY, ALL, X, A modifiers
        ifu_mask_out : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of predicate_reg_file is

    -- 32 threads * 4 registers = 128 locations of 4-bit vectors
    type prf_t is array(0 to 127) of std_logic_vector(3 downto 0);
    signal prf : prf_t := (others => "0000");

begin

    -- ========================================================================
    -- SYNCHRONOUS WRITE PORT
    -- ========================================================================
    process(clk)
        variable w_idx : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                prf <= (others => "0000");
            elsif we = '1' then
                w_idx := to_integer(unsigned(wr_addr));
                if wr_mask(0) = '1' then prf(w_idx)(0) <= wr_data(0); end if;
                if wr_mask(1) = '1' then prf(w_idx)(1) <= wr_data(1); end if;
                if wr_mask(2) = '1' then prf(w_idx)(2) <= wr_data(2); end if;
                if wr_mask(3) = '1' then prf(w_idx)(3) <= wr_data(3); end if;
            end if;
        end if;
    end process;

    -- ========================================================================
    -- ASYNCHRONOUS READ PORTS (For FPU Logic Ops)
    -- ========================================================================
    rs1_data <= prf(to_integer(unsigned(rs1_addr)));
    rs2_data <= prf(to_integer(unsigned(rs2_addr)));

    -- ========================================================================
    -- ASYNCHRONOUS IFU COLLAPSE PORT
    -- ========================================================================
    process(ifu_pred_sel, ifu_pred_mod, prf)
        variable p_val   : std_logic_vector(3 downto 0);
        variable bit_val : std_logic;
        variable idx     : integer;
    begin
        for i in 0 to 31 loop
            idx := (i * 4) + to_integer(unsigned(ifu_pred_sel));
            p_val := prf(idx);
            
            -- Apply the modifier to collapse the 4-bit vector to a 1-bit truth
            case ifu_pred_mod is
                when PRED_MOD_ANY => bit_val := p_val(3) or p_val(2) or p_val(1) or p_val(0);
                when PRED_MOD_ALL => bit_val := p_val(3) and p_val(2) and p_val(1) and p_val(0);
                when PRED_MOD_X   => bit_val := p_val(0);
                when PRED_MOD_A   => bit_val := p_val(3);
                when others       => bit_val := '0';
            end case;
            
            ifu_mask_out(i) <= bit_val;
        end loop;
    end process;

end architecture rtl;
