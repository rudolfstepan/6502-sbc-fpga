-- C64 main memory, dual-port variant for the vic_ii_xl configuration:
--   port A: CPU read/write (never stolen -- the XL VIC does not share it)
--   port B: VIC read-only (the XL VIC's dedicated fetch port)
--
-- Background: c64_ram.vhd is deliberately SINGLE-port because a 64K DPB BSRAM
-- once hung the machine -- Gowin DPB returns undefined data on a same-address
-- port-A-write / port-B-read collision, and back then the CPU read through the
-- colliding port. Here the collision case is different: port B only feeds the
-- VIC pixel pipeline, so the worst case of a CPU write hitting the exact byte
-- the VIC fetches in the same clock is one transiently wrong video byte on one
-- scanline -- never a CPU-visible corruption. The CPU keeps its own clean port.
--
-- "No-change" write mode on port A (read only in the else branch) so Gowin
-- infers a supported BSRAM write mode. Port B is a plain registered read.
--
-- INIT_FILE is simulation-only: an "ADDR VALUE" hex preload (manual hex parse
-- to dodge the std_logic_textio.hread bug under -fsynopsys/-fexplicit).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.textio.all;

entity c64_ram_dp is
  generic (
    INIT_FILE : string := ""
  );
  port (
    clk    : in  std_logic;
    -- port A: CPU
    a_addr : in  std_logic_vector(15 downto 0);
    a_we   : in  std_logic;
    a_din  : in  std_logic_vector(7 downto 0);
    a_dout : out std_logic_vector(7 downto 0);
    -- port B: VIC (read-only)
    b_addr : in  std_logic_vector(15 downto 0);
    b_dout : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of c64_ram_dp is
  type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);

  impure function load(fn : string) return mem_t is
    variable m   : mem_t := (others => (others => '0'));
    variable st  : file_open_status;
    file f       : text;
    variable row : line;
    variable c   : character;
    variable ok  : boolean;
    variable addr_i, val, h : integer;

    function hexv(ch : character) return integer is
    begin
      case ch is
        when '0' to '9' => return character'pos(ch) - character'pos('0');
        when 'A' to 'F' => return character'pos(ch) - character'pos('A') + 10;
        when 'a' to 'f' => return character'pos(ch) - character'pos('a') + 10;
        when others     => return -1;
      end case;
    end function;
  begin
    if fn'length = 0 then
      return m;
    end if;
    file_open(st, f, fn, read_mode);
    assert st = open_ok report "c64_ram_dp: cannot open " & fn severity failure;
    while not endfile(f) loop
      readline(f, row);
      addr_i := 0; val := 0;
      loop
        read(row, c, ok); exit when not ok;
        h := hexv(c); exit when h < 0;
        addr_i := addr_i * 16 + h;
      end loop;
      loop
        read(row, c, ok); exit when not ok;
        h := hexv(c); next when h < 0;
        val := val * 16 + h;
      end loop;
      if addr_i >= 0 and addr_i < 65536 then
        m(addr_i) := std_logic_vector(to_unsigned(val, 8));
      end if;
    end loop;
    file_close(f);
    return m;
  end function;

  signal mem : mem_t := load(INIT_FILE);
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
begin
  -- port A: CPU read/write, no-change write mode
  process(clk)
  begin
    if rising_edge(clk) then
      if a_we = '1' then
        mem(to_integer(unsigned(a_addr))) <= a_din;
      else
        a_dout <= mem(to_integer(unsigned(a_addr)));
      end if;
    end if;
  end process;

  -- port B: VIC read-only
  process(clk)
  begin
    if rising_edge(clk) then
      b_dout <= mem(to_integer(unsigned(b_addr)));
    end if;
  end process;
end architecture;
