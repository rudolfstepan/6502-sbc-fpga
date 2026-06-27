-- ============================================================================
-- REIST centered-correction step (combinational).
--
-- Given a sum that is already within (-2B, 2B) -- the case for acc+x when both
-- acc and x lie in the centered interval -- bring it back into
-- [-floor(B/2), ceil(B/2)) with a single conditional add or subtract. No
-- divider, no loop: two comparators, one adder/subtractor, one mux. This is the
-- whole point of REIST as a hardware primitive.
--
--   lo = -floor(B/2)         hi = lo + B = ceil(B/2)
--   if sum >= hi : sum - B
--   if sum <  lo : sum + B
--   else         : sum
--
-- Works for odd and even B (the floor/ceil split handles the parity).
-- VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reist_core is
  generic (
    W : positive := 32
  );
  port (
    -- b is the modulus (positive); sum is the value to center. Both carry a
    -- guard bit (W downto 0) so acc+x and the +/- B correction cannot overflow.
    b   : in  signed(W downto 0);
    sum : in  signed(W downto 0);
    r   : out signed(W downto 0)
  );
end entity;

architecture rtl of reist_core is
  signal half : signed(W downto 0);   -- floor(B/2)
  signal lo   : signed(W downto 0);   -- -floor(B/2)
  signal hi   : signed(W downto 0);   --  ceil(B/2) = B - floor(B/2)
begin
  -- floor(B/2) for B >= 0 is an arithmetic right shift by one.
  half <= shift_right(b, 1);
  lo   <= -half;
  hi   <= b - half;

  r <= sum - b when sum >= hi else
       sum + b when sum <  lo else
       sum;
end architecture;
