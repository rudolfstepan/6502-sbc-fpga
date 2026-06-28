-- Reproduce a BASIC syntax-error path by typing "A" + RETURN over the PS/2
-- keyboard matrix, then dump the screen, recent opcode PCs, and recent writes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_c64_syntax_error is
end entity;

architecture sim of tb_c64_syntax_error is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal running : boolean := true;

  signal dbg_addr : std_logic_vector(15 downto 0);
  signal dbg_we   : std_logic;
  signal dbg_do   : std_logic_vector(7 downto 0);
  signal dbg_di   : std_logic_vector(7 downto 0);
  signal dbg_sync : std_logic;
  signal dbg_phi  : std_logic;

  signal vga_hs, vga_vs, vga_de : std_logic;
  signal vga_r, vga_b : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal audio        : std_logic_vector(15 downto 0);
  signal ps2_clk      : std_logic := '1';
  signal ps2_data     : std_logic := '1';

  constant RUN_TIME : time := 230 ms;

  type scr_t is array (0 to 999) of std_logic_vector(7 downto 0);
  signal scr : scr_t := (others => x"20");

  signal n_irq : integer := 0;
  signal n_rev : integer := 0;
  signal t_last_irq : time := 0 ns;
  signal t_last_rev : time := 0 ns;
  signal t_last_scr : time := 0 ns;

  type pcring_t is array (0 to 63) of std_logic_vector(15 downto 0);
  signal pcring : pcring_t := (others => (others => '0'));
  signal pc_wp  : integer range 0 to 63 := 0;
  signal pc_last : std_logic_vector(15 downto 0) := (others => '1');

  type wrring_addr_t is array (0 to 63) of std_logic_vector(15 downto 0);
  type wrring_data_t is array (0 to 63) of std_logic_vector(7 downto 0);
  signal waddr : wrring_addr_t := (others => (others => '0'));
  signal wdata : wrring_data_t := (others => (others => '0'));
  signal wr_wp : integer range 0 to 63 := 0;

  function hex16(v : std_logic_vector(15 downto 0)) return string is
    constant hc : string(1 to 16) := "0123456789ABCDEF";
    variable s : string(1 to 4);
  begin
    for i in 0 to 3 loop
      s(i+1) := hc(to_integer(unsigned(v(15-4*i downto 12-4*i))) + 1);
    end loop;
    return s;
  end function;

  function hex8(v : std_logic_vector(7 downto 0)) return string is
    constant hc : string(1 to 16) := "0123456789ABCDEF";
    variable s : string(1 to 2);
  begin
    for i in 0 to 1 loop
      s(i+1) := hc(to_integer(unsigned(v(7-4*i downto 4-4*i))) + 1);
    end loop;
    return s;
  end function;

  function scrcode_to_char(c : std_logic_vector(7 downto 0)) return character is
    variable v : integer := to_integer(unsigned(c and x"7F"));
  begin
    if v = 0 then return '@';
    elsif v >= 1 and v <= 26 then return character'val(64 + v);
    elsif v >= 32 and v <= 63 then return character'val(v);
    else return '.';
    end if;
  end function;
begin
  dut : entity work.c64_core
    generic map (PHI2_DIV => 4)
    port map (
      clk => clk, reset_n => reset_n,
      dbg_addr => dbg_addr, dbg_we => dbg_we, dbg_do => dbg_do, dbg_di => dbg_di,
      dbg_sync => dbg_sync, dbg_phi => dbg_phi, dbg_status => open, dbg_cia1 => open,
      dbg_regs => open,
      vga_hs => vga_hs, vga_vs => vga_vs, vga_de => vga_de,
      vga_r => vga_r, vga_g => vga_g, vga_b => vga_b,
      ps2_clk => ps2_clk, ps2_data => ps2_data,
      audio => audio
    );

  clk_p : process
  begin
    while running loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  rst_p : process
  begin
    reset_n <= '0';
    wait for 200 ns;
    reset_n <= '1';
    wait;
  end process;

  key_p : process
    procedure ps2_bit(bitv : std_logic) is
    begin
      ps2_data <= bitv;
      wait for 15 us;
      ps2_clk <= '0';
      wait for 15 us;
      ps2_clk <= '1';
      wait for 15 us;
    end procedure;

    procedure ps2_byte(code : std_logic_vector(7 downto 0)) is
      variable parity : std_logic := '1'; -- odd parity bit
    begin
      for i in 0 to 7 loop
        parity := parity xor code(i);
      end loop;
      ps2_bit('0');
      for i in 0 to 7 loop
        ps2_bit(code(i));
      end loop;
      ps2_bit(parity);
      ps2_bit('1');
      ps2_data <= '1';
      wait for 120 us;
    end procedure;

    procedure key_make(code : std_logic_vector(7 downto 0)) is
    begin
      ps2_byte(code);
    end procedure;

    procedure key_break(code : std_logic_vector(7 downto 0)) is
    begin
      ps2_byte(x"F0");
      ps2_byte(code);
    end procedure;
  begin
    ps2_clk <= '1';
    ps2_data <= '1';
    wait for 104 ms; -- READY is reached around 85 ms with PHI2_DIV=4.

    -- Type a deliberately invalid BASIC line: A<RETURN>.
    key_make(x"1C");  -- A
    wait for 8 ms;
    key_break(x"1C");
    wait for 8 ms;
    key_make(x"5A");  -- RETURN
    wait for 8 ms;
    key_break(x"5A");
    wait;
  end process;

  mon_p : process(clk)
    variable prev : std_logic_vector(15 downto 0) := (others => '1');
  begin
    if rising_edge(clk) then
      if dbg_addr /= prev then
        if dbg_addr = x"FFFE" then
          n_irq <= n_irq + 1;
          t_last_irq <= now;
        end if;
      end if;
      prev := dbg_addr;

      if dbg_we = '1' and unsigned(dbg_addr) >= 16#0400# and unsigned(dbg_addr) <= 16#07E7# then
        scr(to_integer(unsigned(dbg_addr)) - 16#0400#) <= dbg_do;
        t_last_scr <= now;
        if dbg_do(7) = '1' then
          n_rev <= n_rev + 1;
          t_last_rev <= now;
        end if;
      end if;

      if dbg_sync = '1' and dbg_phi = '1' and dbg_addr /= pc_last then
        pcring(pc_wp) <= dbg_addr;
        pc_last <= dbg_addr;
        if pc_wp = 63 then pc_wp <= 0; else pc_wp <= pc_wp + 1; end if;
      end if;

      if dbg_we = '1' and dbg_phi = '1' then
        waddr(wr_wp) <= dbg_addr;
        wdata(wr_wp) <= dbg_do;
        if wr_wp = 63 then wr_wp <= 0; else wr_wp <= wr_wp + 1; end if;
      end if;
    end if;
  end process;

  stop_p : process
    variable l : line;
  begin
    wait for RUN_TIME;
    running <= false;
    wait for 50 ns;

    write(l, string'("==== c64 syntax-error report ====")); writeline(output, l);
    write(l, string'("IRQ vec count: ")); write(l, n_irq); writeline(output, l);
    write(l, string'("last IRQ @ ")); write(l, t_last_irq); writeline(output, l);
    write(l, string'("REV writes: ")); write(l, n_rev); writeline(output, l);
    write(l, string'("last cursor/screen write @ ")); write(l, t_last_rev);
    write(l, string'(" / ")); write(l, t_last_scr); writeline(output, l);

    write(l, string'("---- last 64 opcode PCs ----")); writeline(output, l);
    for i in 0 to 63 loop
      write(l, hex16(pcring((pc_wp + i) mod 64))); write(l, ' ');
    end loop;
    writeline(output, l);

    write(l, string'("---- last 64 writes addr:data ----")); writeline(output, l);
    for i in 0 to 63 loop
      write(l, hex16(waddr((wr_wp + i) mod 64)));
      write(l, ':');
      write(l, hex8(wdata((wr_wp + i) mod 64)));
      write(l, ' ');
    end loop;
    writeline(output, l);

    write(l, string'("---- screen ($0400) ----")); writeline(output, l);
    for row in 0 to 24 loop
      for col in 0 to 39 loop
        write(l, scrcode_to_char(scr(row * 40 + col)));
      end loop;
      writeline(output, l);
    end loop;
    write(l, string'("==== end ====")); writeline(output, l);
    wait;
  end process;
end architecture;
