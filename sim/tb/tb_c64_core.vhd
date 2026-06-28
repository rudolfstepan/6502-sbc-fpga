-- Boot/behaviour testbench for the native C64 core.
--
-- Boots the real KERNAL/BASIC ROMs (embedded in c64_roms.vhd) in simulation and
-- reports: counts/timestamps of RESET ($FFFC), NMI ($FFFA) and IRQ/BRK ($FFFE)
-- vector accesses; whether BASIC cold start ($E394) / warm start ($E37B) is
-- reached; and the reconstructed 40x25 screen (banner? READY.?).
--
-- PHI2_DIV is set to 3: the read path now has TWO cycles of latency (synchronous
-- BSRAM + the cpu_din_reg read latch), so the CPU period must be >= 3 for the data
-- to settle before the CPU samples it. (On hardware PHI2_DIV=27, ample margin.)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_c64_core is
end entity;

architecture sim of tb_c64_core is
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

  constant RUN_TIME : time := 110 ms;

  type scr_t is array (0 to 999) of std_logic_vector(7 downto 0);
  signal scr : scr_t := (others => x"20");

  signal n_reset, n_nmi, n_irq, n_cold, n_warm : integer := 0;
  signal n_rev : integer := 0;   -- screen writes with bit7 set = cursor blink
  signal t_last_rev : time := 0 ns;   -- sim time of the last cursor-blink write
  signal t_last_irq : time := 0 ns;   -- sim time of the last IRQ/BRK vector (60 Hz heartbeat)
  signal t_cold     : time := 0 ns;

  -- Ring buffer of the last opcode-fetch PCs, to see where a freeze loops.
  type pcring_t is array (0 to 31) of std_logic_vector(15 downto 0);
  signal pcring : pcring_t := (others => (others => '0'));
  signal pc_wp  : integer range 0 to 31 := 0;
  signal pc_last : std_logic_vector(15 downto 0) := (others => '1');

  function hex16(v : std_logic_vector(15 downto 0)) return string is
    constant hc : string(1 to 16) := "0123456789ABCDEF";
    variable s : string(1 to 4);
  begin
    for i in 0 to 3 loop
      s(i+1) := hc(to_integer(unsigned(v(15-4*i downto 12-4*i))) + 1);
    end loop;
    return s;
  end function;

  function scrcode_to_char(c : std_logic_vector(7 downto 0)) return character is
    variable v : integer := to_integer(unsigned(c));
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
      ps2_clk => '1', ps2_data => '1',
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

  mon_p : process(clk)
    variable prev : std_logic_vector(15 downto 0) := (others => '1');
    variable l    : line;
  begin
    if rising_edge(clk) then
      if dbg_addr /= prev then
        case dbg_addr is
          when x"FFFC" => n_reset <= n_reset + 1;
          when x"FFFA" => n_nmi   <= n_nmi   + 1;
          when x"FFFE" => n_irq   <= n_irq   + 1; t_last_irq <= now;
          when x"E394" => if n_cold = 0 then
                            write(l, string'(">> COLD start ($E394) @ ")); write(l, now); writeline(output, l);
                          end if;
                          n_cold <= n_cold + 1;
          when x"E37B" => if n_warm = 0 then
                            write(l, string'(">> WARM start ($E37B) @ ")); write(l, now); writeline(output, l);
                          end if;
                          n_warm <= n_warm + 1;
          when others => null;
        end case;
      end if;
      prev := dbg_addr;

      if dbg_we = '1' and unsigned(dbg_addr) >= 16#0400# and unsigned(dbg_addr) <= 16#07E7# then
        scr(to_integer(unsigned(dbg_addr)) - 16#0400#) <= dbg_do;
        if dbg_do(7) = '1' then n_rev <= n_rev + 1; t_last_rev <= now; end if;
      end if;
      if n_cold = 0 and dbg_addr = x"E394" then t_cold <= now; end if;

      -- Capture one PC per instruction (opcode fetch = sync, at the cpu cycle edge),
      -- deduped so a steal-stalled fetch does not flood the ring with one address.
      if dbg_sync = '1' and dbg_phi = '1' and dbg_addr /= pc_last then
        pcring(pc_wp) <= dbg_addr;
        pc_last <= dbg_addr;
        if pc_wp = 31 then pc_wp <= 0; else pc_wp <= pc_wp + 1; end if;
      end if;
    end if;
  end process;

  stop_p : process
    variable l : line;
  begin
    wait for RUN_TIME;
    running <= false;
    wait for 50 ns;
    write(l, string'("==== c64_core boot report ===="));        writeline(output, l);
    write(l, string'("RESET vec: ")); write(l, n_reset);        writeline(output, l);
    write(l, string'("NMI   vec: ")); write(l, n_nmi);          writeline(output, l);
    write(l, string'("IRQ   vec: ")); write(l, n_irq);          writeline(output, l);
    write(l, string'("COLD hits: ")); write(l, n_cold);         writeline(output, l);
    write(l, string'("WARM hits: ")); write(l, n_warm);         writeline(output, l);
    write(l, string'("REV writes (cursor blink): ")); write(l, n_rev); writeline(output, l);
    write(l, string'("last cursor-blink @ ")); write(l, t_last_rev); writeline(output, l);
    write(l, string'("last IRQ (60Hz heartbeat) @ ")); write(l, t_last_irq); writeline(output, l);
    write(l, string'("cold @ ")); write(l, t_cold);
    write(l, string'(", run end ")); write(l, RUN_TIME); writeline(output, l);
    write(l, string'(">> if last-IRQ << run-end, the IRQ/machine FROZE there")); writeline(output, l);
    write(l, string'("---- last 32 opcode PCs (oldest -> newest) ----")); writeline(output, l);
    for i in 0 to 31 loop
      write(l, hex16(pcring((pc_wp + i) mod 32))); write(l, ' ');
    end loop;
    writeline(output, l);
    write(l, string'("---- screen ($0400) ----"));              writeline(output, l);
    for row in 0 to 24 loop
      for col in 0 to 39 loop
        write(l, scrcode_to_char(scr(row * 40 + col)));
      end loop;
      writeline(output, l);
    end loop;
    write(l, string'("==== end ===="));                         writeline(output, l);
    wait;
  end process;
end architecture;
