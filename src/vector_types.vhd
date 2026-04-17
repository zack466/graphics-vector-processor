--------------------------------------------------------------------------------
-- Package: vector_types_pkg
--
-- PURPOSE:
--   Defines the canonical scalar and vector primitive types shared across every
--   entity in the SIMT vector processor.  Centralising them here avoids
--   duplicated type declarations and ensures that every entity speaks the same
--   bit-width language — a mismatch would otherwise be a silent functional bug
--   caught only at simulation time.
--
-- USAGE:
--   Add the following two lines to any entity that needs these types:
--       library work;
--       use work.vector_types_pkg.all;
--
-- TYPES DEFINED:
--   word_t        -- 32-bit scalar value.  Used for individual ALU operands,
--                    register file words, and instruction words.
--
--   vector_t      -- Array of four word_ts, indexed 0..3 corresponding to the
--                    XYZW components of a GPU-style vector register.  Index 0
--                    is X (lowest address / least-significant lane).
--
--   swizzle_sel_t -- 3-bit selector code that picks one source component for a
--                    single destination lane during a swizzle operation.
--                    3 bits gives 8 encodings. Code 0 is SWIZ_PASS (identity),
--                    and codes 4-7 are for X/Y/Z/W broadcast (splat) selection.
--                    Kept as a raw
--                    std_logic_vector so it can be sliced directly from the
--                    instruction word without a numeric conversion.
--
-- DESIGN NOTES:
--   vector_t is declared as a VHDL array type (not a subtype) because VHDL
--   does not allow array subtypes with unconstrained element types.  Using a
--   named type also makes port and signal declarations self-documenting.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package vector_types_pkg is
    subtype word_t is std_logic_vector(31 downto 0);
    type vector_t is array (0 to 3) of word_t;
    subtype swizzle_sel_t is std_logic_vector(2 downto 0);

    -- -------------------------------------------------------------------------
    -- Unconstrained array types for multi-warp port arrays.
    -- Used by warp_scheduler, mcu_block_transfer, and frame_processor to pass
    -- per-warp data with a single generic NUM_WARPS controlling array bounds.
    -- VHDL-2008 allows port constraints of the form slv32_array_t(0 to N-1)
    -- where N is a generic, which is how these types are used in practice.
    -- -------------------------------------------------------------------------
    type slv3_array_t   is array (natural range <>) of std_logic_vector(2 downto 0);
    type slv5_array_t   is array (natural range <>) of std_logic_vector(4 downto 0);
    type slv16_array_t  is array (natural range <>) of std_logic_vector(15 downto 0);
    type slv32_array_t  is array (natural range <>) of std_logic_vector(31 downto 0);
    type slv128_array_t is array (natural range <>) of std_logic_vector(127 downto 0);
end package;
