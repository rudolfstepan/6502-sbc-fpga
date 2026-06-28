-- C64 core package: address types, the PLA banking decode, and the I/O sub-decode.
--
-- This is the C64-accurate memory map, kept entirely separate from the SBC's
-- sbc_pkg so the existing single-board-computer design is untouched. The native
-- C64 core (rtl/c64) builds on these definitions.
--
-- Banking is driven by the 6510 processor port ($0001) bits LORAM/HIRAM/CHAREN
-- plus the cartridge lines GAME/EXROM. Milestone 1 targets an unexpanded C64
-- (GAME=1, EXROM=1); the ROML/ROMH selections are reserved for later cartridge
-- support and never asserted while both lines are high.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package c64_pkg is
  subtype c64_addr_t is std_logic_vector(15 downto 0);
  subtype c64_data_t is std_logic_vector(7 downto 0);

  -- What the CPU address currently maps to after PLA banking.
  type c64_sel_t is (
    SEL_RAM,      -- 64K DRAM
    SEL_BASIC,    -- BASIC ROM    $A000-$BFFF
    SEL_KERNAL,   -- KERNAL ROM   $E000-$FFFF
    SEL_CHARGEN,  -- char ROM     $D000-$DFFF (CHAREN=0)
    SEL_IO,       -- I/O block    $D000-$DFFF (CHAREN=1)
    SEL_ROML,     -- cartridge ROM low  (reserved)
    SEL_ROMH      -- cartridge ROM high (reserved)
  );

  -- Sub-decode of the $D000-$DFFF I/O block.
  type c64_io_t is (
    IO_NONE,
    IO_VIC,       -- $D000-$D3FF  VIC-II (mirrored every $40)
    IO_SID,       -- $D400-$D7FF  SID    (mirrored every $20)
    IO_COLOR,     -- $D800-$DBFF  colour RAM (1K x 4)
    IO_CIA1,      -- $DC00-$DCFF  CIA-1  (mirrored every $10)
    IO_CIA2,      -- $DD00-$DDFF  CIA-2  (mirrored every $10)
    IO_EXP1,      -- $DE00-$DEFF  I/O area 1 (expansion)
    IO_EXP2       -- $DF00-$DFFF  I/O area 2 (expansion)
  );

  -- PLA banking decode. ctrl bits: (2)=CHAREN (1)=HIRAM (0)=LORAM, all active
  -- high as stored in the processor port. game_n/exrom_n are active-low cart
  -- lines (both '1' for an unexpanded machine).
  function pla_decode(
    addr    : c64_addr_t;
    ctrl    : std_logic_vector(2 downto 0);
    game_n  : std_logic;
    exrom_n : std_logic
  ) return c64_sel_t;

  -- I/O sub-decode for an address already known to be in $D000-$DFFF as I/O.
  function io_decode(addr : c64_addr_t) return c64_io_t;
end package;

package body c64_pkg is

  function pla_decode(
    addr    : c64_addr_t;
    ctrl    : std_logic_vector(2 downto 0);
    game_n  : std_logic;
    exrom_n : std_logic
  ) return c64_sel_t is
    variable a      : unsigned(15 downto 0);
    variable loram  : std_logic := ctrl(0);
    variable hiram  : std_logic := ctrl(1);
    variable charen : std_logic := ctrl(2);
  begin
    if is_x(addr) then
      return SEL_RAM;
    end if;
    a := unsigned(addr);

    -- $A000-$BFFF: BASIC when LORAM & HIRAM (unexpanded machine).
    if a >= x"A000" and a <= x"BFFF" then
      if loram = '1' and hiram = '1' then
        return SEL_BASIC;
      else
        return SEL_RAM;
      end if;

    -- $D000-$DFFF: I/O, character ROM, or RAM.
    elsif a >= x"D000" and a <= x"DFFF" then
      if (loram = '1' or hiram = '1') and charen = '1' then
        return SEL_IO;
      elsif (loram = '1' or hiram = '1') and charen = '0' then
        return SEL_CHARGEN;
      else
        return SEL_RAM;
      end if;

    -- $E000-$FFFF: KERNAL when HIRAM.
    elsif a >= x"E000" then
      if hiram = '1' then
        return SEL_KERNAL;
      else
        return SEL_RAM;
      end if;
    end if;

    return SEL_RAM;
  end function;

  function io_decode(addr : c64_addr_t) return c64_io_t is
    variable a : unsigned(15 downto 0);
  begin
    if is_x(addr) then
      return IO_NONE;
    end if;
    a := unsigned(addr);
    case a(11 downto 8) is
      when x"0" | x"1" | x"2" | x"3" => return IO_VIC;   -- $D000-$D3FF
      when x"4" | x"5" | x"6" | x"7" => return IO_SID;   -- $D400-$D7FF
      when x"8" | x"9" | x"A" | x"B" => return IO_COLOR; -- $D800-$DBFF
      when x"C"                      => return IO_CIA1;  -- $DC00-$DCFF
      when x"D"                      => return IO_CIA2;  -- $DD00-$DDFF
      when x"E"                      => return IO_EXP1;  -- $DE00-$DEFF
      when x"F"                      => return IO_EXP2;  -- $DF00-$DFFF
      when others                    => return IO_NONE;
    end case;
  end function;

end package body;
