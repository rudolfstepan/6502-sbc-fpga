-- Character ROM: ASCII-compatible PETSCII-style 8x8 pixel patterns
-- Addressing: full glyph index = glyph_hi & addr = char_code(7:0) & pixel_row(2:0)
--   addr     = char_code(6:0) & pixel_row(2:0)   (low 128 glyphs, 10 bits)
--   glyph_hi = char_code(7)                       (selects the upper 128 glyphs)
-- Output: bit 7 = leftmost pixel.
-- NOTE: char_code(7) used to mean reverse video. The active VGA path now uses it
-- as the high glyph-select bit (for German umlauts); legacy instances that leave
-- glyph_hi unconnected keep the original 128-glyph behaviour.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity char_rom is
  port (
    addr     : in  std_logic_vector(9 downto 0);
    -- 9th glyph-select bit (char_code bit 7). Left unconnected it defaults to
    -- '0', so existing instances keep their original 128-glyph behaviour; the
    -- active VGA path drives it with char_code(7) to reach the upper 128 glyphs
    -- (German umlauts) instead of using bit 7 as reverse video.
    glyph_hi : in  std_logic := '0';
    dout     : out data_t
  );
end entity;

architecture rtl of char_rom is
  -- 256 glyphs * 8 rows = 2048 bytes. The low 128 glyphs are the original
  -- ASCII/PETSCII set; the upper half is blank except for the German umlaut
  -- glyphs added at their Latin-1 code points (see build_rom below).
  type rom_t  is array (0 to 2047) of data_t;
  type base_t is array (0 to 1023) of data_t;

  constant base128 : base_t := (
    -- PETSCII @ / screen-code 0
    x"3C", x"66", x"6E", x"6A", x"6E", x"60", x"3E", x"00",
    -- PETSCII A-Z screen-code block
    x"3C", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x02
    x"7C", x"66", x"66", x"7C", x"66", x"66", x"7C", x"00",
    -- Character 0x03
    x"3C", x"66", x"60", x"60", x"60", x"66", x"3C", x"00",
    -- Character 0x04
    x"78", x"6C", x"66", x"66", x"66", x"6C", x"78", x"00",
    -- Character 0x05
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"7E", x"00",
    -- Character 0x06
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x07
    x"3C", x"66", x"60", x"6E", x"66", x"66", x"3C", x"00",
    -- Character 0x08
    x"66", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x09
    x"7E", x"18", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x0A
    x"3E", x"0C", x"0C", x"0C", x"0C", x"6C", x"38", x"00",
    -- Character 0x0B
    x"66", x"6C", x"78", x"70", x"78", x"6C", x"66", x"00",
    -- Character 0x0C
    x"60", x"60", x"60", x"60", x"60", x"60", x"7E", x"00",
    -- Character 0x0D
    x"63", x"77", x"7F", x"6B", x"63", x"63", x"63", x"00",
    -- Character 0x0E
    x"66", x"76", x"7E", x"7E", x"6E", x"66", x"66", x"00",
    -- Character 0x0F
    x"3C", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x10
    x"7C", x"66", x"66", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x11
    x"3C", x"66", x"66", x"66", x"6E", x"3C", x"06", x"00",
    -- Character 0x12
    x"7C", x"66", x"66", x"7C", x"78", x"6C", x"66", x"00",
    -- Character 0x13
    x"3E", x"60", x"60", x"3C", x"06", x"06", x"7C", x"00",
    -- Character 0x14
    x"7E", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x15
    x"66", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x16
    x"66", x"66", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x17
    x"63", x"63", x"6B", x"7F", x"77", x"63", x"63", x"00",
    -- Character 0x18
    x"66", x"66", x"3C", x"18", x"3C", x"66", x"66", x"00",
    -- Character 0x19
    x"66", x"66", x"66", x"3C", x"18", x"18", x"18", x"00",
    -- Character 0x1A
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"7E", x"00",
    -- Character 0x1B
    x"3C", x"30", x"30", x"30", x"30", x"30", x"3C", x"00",
    -- Character 0x1C
    x"1C", x"36", x"30", x"7C", x"30", x"30", x"7E", x"00",
    -- Character 0x1D
    x"3C", x"0C", x"0C", x"0C", x"0C", x"0C", x"3C", x"00",
    -- Character 0x1E
    x"18", x"3C", x"7E", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x1F
    x"00", x"10", x"30", x"7F", x"7F", x"30", x"10", x"00",
    -- ASCII/PETSCII punctuation, digits, uppercase letters
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x21
    x"18", x"18", x"18", x"18", x"00", x"18", x"00", x"00",
    -- Character 0x22
    x"66", x"66", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x23
    x"36", x"36", x"7F", x"36", x"7F", x"36", x"36", x"00",
    -- Character 0x24
    x"18", x"3E", x"60", x"3C", x"06", x"7C", x"18", x"00",
    -- Character 0x25
    x"60", x"66", x"0C", x"18", x"30", x"66", x"06", x"00",
    -- Character 0x26
    x"38", x"6C", x"38", x"76", x"DC", x"CC", x"76", x"00",
    -- Character 0x27
    x"18", x"18", x"30", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x28
    x"0C", x"18", x"30", x"30", x"30", x"18", x"0C", x"00",
    -- Character 0x29
    x"30", x"18", x"0C", x"0C", x"0C", x"18", x"30", x"00",
    -- Character 0x2A
    x"00", x"66", x"3C", x"FF", x"3C", x"66", x"00", x"00",
    -- Character 0x2B
    x"00", x"18", x"18", x"7E", x"18", x"18", x"00", x"00",
    -- Character 0x2C
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"30",
    -- Character 0x2D
    x"00", x"00", x"00", x"7E", x"00", x"00", x"00", x"00",
    -- Character 0x2E
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"00",
    -- Character 0x2F
    x"06", x"0C", x"18", x"30", x"60", x"C0", x"80", x"00",
    -- Character 0x30
    x"3C", x"66", x"6E", x"76", x"66", x"66", x"3C", x"00",
    -- Character 0x31
    x"18", x"38", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x32
    x"3C", x"66", x"06", x"0C", x"18", x"30", x"7E", x"00",
    -- Character 0x33
    x"3C", x"66", x"06", x"1C", x"06", x"66", x"3C", x"00",
    -- Character 0x34
    x"0C", x"1C", x"3C", x"6C", x"7E", x"0C", x"0C", x"00",
    -- Character 0x35
    x"7E", x"60", x"7C", x"06", x"06", x"66", x"3C", x"00",
    -- Character 0x36
    x"3C", x"66", x"60", x"7C", x"66", x"66", x"3C", x"00",
    -- Character 0x37
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"60", x"00",
    -- Character 0x38
    x"3C", x"66", x"66", x"3C", x"66", x"66", x"3C", x"00",
    -- Character 0x39
    x"3C", x"66", x"66", x"3E", x"06", x"66", x"3C", x"00",
    -- Character 0x3A
    x"00", x"18", x"18", x"00", x"18", x"18", x"00", x"00",
    -- Character 0x3B
    x"00", x"18", x"18", x"00", x"18", x"18", x"30", x"00",
    -- Character 0x3C
    x"0C", x"18", x"30", x"60", x"30", x"18", x"0C", x"00",
    -- Character 0x3D
    x"00", x"00", x"7E", x"00", x"7E", x"00", x"00", x"00",
    -- Character 0x3E
    x"30", x"18", x"0C", x"06", x"0C", x"18", x"30", x"00",
    -- Character 0x3F
    x"3C", x"66", x"06", x"0C", x"18", x"00", x"18", x"00",
    -- Character 0x40
    x"3C", x"66", x"6E", x"6A", x"6E", x"60", x"3E", x"00",
    -- Character 0x41
    x"3C", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x42
    x"7C", x"66", x"66", x"7C", x"66", x"66", x"7C", x"00",
    -- Character 0x43
    x"3C", x"66", x"60", x"60", x"60", x"66", x"3C", x"00",
    -- Character 0x44
    x"78", x"6C", x"66", x"66", x"66", x"6C", x"78", x"00",
    -- Character 0x45
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"7E", x"00",
    -- Character 0x46
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x47
    x"3C", x"66", x"60", x"6E", x"66", x"66", x"3C", x"00",
    -- Character 0x48
    x"66", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x49
    x"7E", x"18", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x4A
    x"3E", x"0C", x"0C", x"0C", x"0C", x"6C", x"38", x"00",
    -- Character 0x4B
    x"66", x"6C", x"78", x"70", x"78", x"6C", x"66", x"00",
    -- Character 0x4C
    x"60", x"60", x"60", x"60", x"60", x"60", x"7E", x"00",
    -- Character 0x4D
    x"63", x"77", x"7F", x"6B", x"63", x"63", x"63", x"00",
    -- Character 0x4E
    x"66", x"76", x"7E", x"7E", x"6E", x"66", x"66", x"00",
    -- Character 0x4F
    x"3C", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x50
    x"7C", x"66", x"66", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x51
    x"3C", x"66", x"66", x"66", x"6E", x"3C", x"06", x"00",
    -- Character 0x52
    x"7C", x"66", x"66", x"7C", x"78", x"6C", x"66", x"00",
    -- Character 0x53
    x"3E", x"60", x"60", x"3C", x"06", x"06", x"7C", x"00",
    -- Character 0x54
    x"7E", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x55
    x"66", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x56
    x"66", x"66", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x57
    x"63", x"63", x"6B", x"7F", x"77", x"63", x"63", x"00",
    -- Character 0x58
    x"66", x"66", x"3C", x"18", x"3C", x"66", x"66", x"00",
    -- Character 0x59
    x"66", x"66", x"66", x"3C", x"18", x"18", x"18", x"00",
    -- Character 0x5A
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"7E", x"00",
    -- Character 0x5B
    x"3C", x"30", x"30", x"30", x"30", x"30", x"3C", x"00",
    -- Character 0x5C
    x"80", x"C0", x"60", x"30", x"18", x"0C", x"06", x"00",
    -- Character 0x5D
    x"3C", x"0C", x"0C", x"0C", x"0C", x"0C", x"3C", x"00",
    -- Character 0x5E
    x"18", x"3C", x"66", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x5F
    x"00", x"00", x"00", x"00", x"00", x"00", x"FF", x"00",
    -- PETSCII-style block and line graphics
    x"00", x"00", x"00", x"FF", x"FF", x"00", x"00", x"00",
    -- Character 0x61
    x"18", x"18", x"18", x"18", x"18", x"18", x"18", x"18",
    -- Character 0x62
    x"18", x"18", x"18", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x63
    x"00", x"00", x"00", x"1F", x"1F", x"18", x"18", x"18",
    -- Character 0x64
    x"00", x"00", x"00", x"F8", x"F8", x"18", x"18", x"18",
    -- Character 0x65
    x"18", x"18", x"18", x"1F", x"1F", x"00", x"00", x"00",
    -- Character 0x66
    x"18", x"18", x"18", x"F8", x"F8", x"00", x"00", x"00",
    -- Character 0x67
    x"00", x"00", x"00", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x68
    x"18", x"18", x"18", x"FF", x"FF", x"00", x"00", x"00",
    -- Character 0x69
    x"18", x"18", x"18", x"1F", x"1F", x"18", x"18", x"18",
    -- Character 0x6A
    x"18", x"18", x"18", x"F8", x"F8", x"18", x"18", x"18",
    -- Character 0x6B
    x"80", x"C0", x"E0", x"F0", x"78", x"3C", x"1E", x"0F",
    -- Character 0x6C
    x"01", x"03", x"07", x"0F", x"1E", x"3C", x"78", x"F0",
    -- Character 0x6D
    x"AA", x"55", x"AA", x"55", x"AA", x"55", x"AA", x"55",
    -- Character 0x6E
    x"CC", x"CC", x"33", x"33", x"CC", x"CC", x"33", x"33",
    -- Character 0x6F
    x"F0", x"F0", x"F0", x"F0", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x70
    x"F0", x"F0", x"F0", x"F0", x"F0", x"F0", x"F0", x"F0",
    -- Character 0x71
    x"0F", x"0F", x"0F", x"0F", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x72
    x"FF", x"FF", x"FF", x"FF", x"00", x"00", x"00", x"00",
    -- Character 0x73
    x"00", x"00", x"00", x"00", x"FF", x"FF", x"FF", x"FF",
    -- Character 0x74
    x"F0", x"F0", x"F0", x"F0", x"00", x"00", x"00", x"00",
    -- Character 0x75
    x"0F", x"0F", x"0F", x"0F", x"00", x"00", x"00", x"00",
    -- Character 0x76
    x"00", x"00", x"00", x"00", x"F0", x"F0", x"F0", x"F0",
    -- Character 0x77
    x"00", x"00", x"00", x"00", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x78
    x"81", x"42", x"24", x"18", x"18", x"24", x"42", x"81",
    -- Character 0x79
    x"18", x"3C", x"7E", x"FF", x"FF", x"7E", x"3C", x"18",
    -- Character 0x7A
    x"18", x"3C", x"7E", x"DB", x"FF", x"24", x"5A", x"A5",
    -- Character 0x7B
    x"00", x"3C", x"7E", x"7E", x"7E", x"7E", x"3C", x"00",
    -- Character 0x7C
    x"18", x"3C", x"7E", x"18", x"18", x"7E", x"3C", x"18",
    -- Character 0x7D
    x"18", x"18", x"18", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x7E
    x"76", x"DC", x"00", x"76", x"DC", x"00", x"00", x"00",
    -- Character 0x7F
    x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF"
  );

  -- Build the full 256-glyph ROM: copy the base 128 glyphs and overlay the
  -- German umlaut glyphs at their Latin-1 code points so that the bytes emitted
  -- by the keyboard (ä=E4 ö=F6 ü=FC Ä=C4 Ö=D6 Ü=DC ß=DF) index real shapes.
  -- The display path stores text in uppercase, so ä/Ä, ö/Ö and ü/Ü share the
  -- same upper-case-with-diaeresis glyph for a consistent all-caps screen.
  function build_rom return rom_t is
    variable r : rom_t := (others => x"00");
  begin
    for i in base_t'range loop
      r(i) := base128(i);
    end loop;

    -- Ä / ä  (A with diaeresis)
    for code in 0 to 1 loop
      r((16#C4# + code*16#20#)*8 + 0) := x"66";
      r((16#C4# + code*16#20#)*8 + 1) := x"00";
      r((16#C4# + code*16#20#)*8 + 2) := x"3C";
      r((16#C4# + code*16#20#)*8 + 3) := x"66";
      r((16#C4# + code*16#20#)*8 + 4) := x"7E";
      r((16#C4# + code*16#20#)*8 + 5) := x"66";
      r((16#C4# + code*16#20#)*8 + 6) := x"66";
      r((16#C4# + code*16#20#)*8 + 7) := x"00";
    end loop;

    -- Ö / ö  (O with diaeresis)
    for code in 0 to 1 loop
      r((16#D6# + code*16#20#)*8 + 0) := x"66";
      r((16#D6# + code*16#20#)*8 + 1) := x"00";
      r((16#D6# + code*16#20#)*8 + 2) := x"3C";
      r((16#D6# + code*16#20#)*8 + 3) := x"66";
      r((16#D6# + code*16#20#)*8 + 4) := x"66";
      r((16#D6# + code*16#20#)*8 + 5) := x"66";
      r((16#D6# + code*16#20#)*8 + 6) := x"3C";
      r((16#D6# + code*16#20#)*8 + 7) := x"00";
    end loop;

    -- Ü / ü  (U with diaeresis)
    for code in 0 to 1 loop
      r((16#DC# + code*16#20#)*8 + 0) := x"66";
      r((16#DC# + code*16#20#)*8 + 1) := x"00";
      r((16#DC# + code*16#20#)*8 + 2) := x"66";
      r((16#DC# + code*16#20#)*8 + 3) := x"66";
      r((16#DC# + code*16#20#)*8 + 4) := x"66";
      r((16#DC# + code*16#20#)*8 + 5) := x"66";
      r((16#DC# + code*16#20#)*8 + 6) := x"3C";
      r((16#DC# + code*16#20#)*8 + 7) := x"00";
    end loop;

    -- ß  (sharp s, single form)
    r(16#DF#*8 + 0) := x"3C";
    r(16#DF#*8 + 1) := x"66";
    r(16#DF#*8 + 2) := x"66";
    r(16#DF#*8 + 3) := x"7C";
    r(16#DF#*8 + 4) := x"66";
    r(16#DF#*8 + 5) := x"66";
    r(16#DF#*8 + 6) := x"6C";
    r(16#DF#*8 + 7) := x"60";

    return r;
  end function;

  constant rom : rom_t := build_rom;

begin
  dout <= rom(to_integer(unsigned(glyph_hi & addr)));
end architecture;
