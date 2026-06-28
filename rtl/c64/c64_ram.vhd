-- C64 main memory: 64K x 8 SINGLE-port synchronous RAM (block RAM).
--
-- Time-shared between the CPU and the VIC by an address mux in c64_core: the VIC
-- gets the bus during its line fetch (BA low) and the CPU otherwise. To avoid
-- dropping CPU writes (a 6502 RDY only halts reads, not writes), the core gates
-- the CPU *clock-enable* during a VIC steal so the CPU is fully paused -- it never
-- reads or writes while the VIC owns the bus, so no write is lost.
--
-- A single-port BSRAM is used on purpose: a 64K dual-port (DPB) BSRAM exhibited
-- hardware hangs (Gowin DPB returns undefined data on a same-address port-A-write
-- / port-B-read collision, unlike the clean behavioural sim model). Single port +
-- gated steal sidesteps that entirely.
--
-- "No-change" read pattern (read only in the else branch) so Gowin infers a
-- supported BSRAM write mode (no read-before-write).
--
-- INIT_FILE is simulation-only: an "ADDR VALUE" hex preload (manual hex parse to
-- dodge the std_logic_textio.hread bug under -fsynopsys/-fexplicit). "" = zeroed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.textio.all;

entity c64_ram is
  generic (
    INIT_FILE : string := ""
  );
  port (
    clk  : in  std_logic;
    addr : in  std_logic_vector(15 downto 0);
    we   : in  std_logic;
    din  : in  std_logic_vector(7 downto 0);
    dout : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of c64_ram is
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
    assert st = open_ok report "c64_ram: cannot open " & fn severity failure;
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
  process(clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(unsigned(addr))) <= din;
      else
        dout <= mem(to_integer(unsigned(addr)));
      end if;
    end if;
  end process;
end architecture;
