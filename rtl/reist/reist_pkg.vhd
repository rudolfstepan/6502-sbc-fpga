-- ============================================================================
-- REIST benchmark — shared configuration and software reference models.
--
-- REIST (Remainder-Extended Inversion and Subtraction Technique) keeps a value
-- in the CENTERED half-open interval [-floor(B/2), ceil(B/2)) instead of the
-- classical [0, B). For a running modular accumulator that means one conditional
-- add/subtract per step (no divider); the classical baseline reduces with a
-- sequential hardware divider. This package is shared by the engine and the
-- testbenches. VHDL-93 compatible (gw_sh + GHDL).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package reist_pkg is

  -- Datapath width (engine/divider use this as a generic default).
  constant REIST_W : positive := 32;

  -- Moduli the engine sweeps: a mix of odd/even and small/large values.
  type modulus_array is array (natural range <>) of integer;
  constant MODULI : modulus_array := (251, 256, 1009, 65521);

  -- Software reference models for the testbenches.
  --   classic_mod : non-negative residue, 0 .. b-1
  --   reist_res   : centered residue, -floor(b/2) .. ceil(b/2)-1
  function classic_mod(t : integer; b : integer) return integer;
  function reist_res  (t : integer; b : integer) return integer;

end package;

package body reist_pkg is

  function classic_mod(t : integer; b : integer) return integer is
  begin
    return t mod b;                      -- b>0 => result in 0 .. b-1
  end function;

  function reist_res(t : integer; b : integer) return integer is
  begin
    return ((t + b/2) mod b) - b/2;      -- centered, matches the hardware core
  end function;

end package body;
