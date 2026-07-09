-- Self-checking testbench for vic_blit_regs: writes the blitter register bank,
-- checks the decoded command fields, the one-cycle start pulse on $884F, and the
-- BUSY read-back at $884F.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_blit_regs is
end entity;

architecture sim of tb_vic_blit_regs is
  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal wr    : std_logic := '0';
  signal addr  : std_logic_vector(3 downto 0) := (others => '0');
  signal wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal rdata : std_logic_vector(7 downto 0);
  signal busy  : std_logic := '0';
  signal blit_op    : std_logic_vector(2 downto 0);
  signal blit_x0, blit_y0, blit_x1, blit_y1 : unsigned(9 downto 0);
  signal blit_color : std_logic_vector(7 downto 0);
  signal blit_page  : std_logic;
  signal blit_start : std_logic;
  signal start_seen : integer := 0;
begin

  dut : entity work.vic_blit_regs
    port map (clk => clk, rst_n => rst_n, wr => wr, addr => addr, wdata => wdata,
              rdata => rdata, busy => busy,
              blit_op => blit_op, blit_x0 => blit_x0, blit_y0 => blit_y0,
              blit_x1 => blit_x1, blit_y1 => blit_y1, blit_color => blit_color,
              blit_page => blit_page, blit_gap => open,
              blit_dstx => open, blit_dsty => open,
              blit_tex_base => open, blit_tex_u0 => open, blit_tex_v0 => open,
              blit_tex_dudx => open, blit_tex_dvdx => open,
              blit_tex_dudy => open, blit_tex_dvdy => open,
              blit_tex_flags => open,
              blit_start => blit_start);

  clk <= not clk after 5 ns;

  -- count start pulses
  process(clk)
  begin
    if rising_edge(clk) then
      if blit_start = '1' then start_seen <= start_seen + 1; end if;
    end if;
  end process;

  stim : process
    procedure wreg(a : integer; d : integer) is
    begin
      addr  <= std_logic_vector(to_unsigned(a, 4));
      wdata <= std_logic_vector(to_unsigned(d, 8));
      wr    <= '1';
      wait until rising_edge(clk);
      wr    <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    rst_n <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst_n <= '1';
    wait until rising_edge(clk);

    wreg(0, 16#2C#); wreg(1, 16#01#);   -- x0 = 0x12C = 300
    wreg(2, 16#FA#); wreg(3, 16#00#);   -- y0 = 250
    wreg(4, 16#90#); wreg(5, 16#01#);   -- x1 = 0x190 = 400
    wreg(6, 16#2C#); wreg(7, 16#01#);   -- y1 = 0x12C = 300
    wreg(8, 16#E0#);                    -- colour
    wreg(9, 3);                         -- OP = LINE
    wreg(10, 1);                        -- PAGE = 1

    assert blit_op = "011"            report "OP wrong"    severity failure;
    assert blit_x0 = to_unsigned(300,10) report "x0 wrong" severity failure;
    assert blit_y0 = to_unsigned(250,10) report "y0 wrong" severity failure;
    assert blit_x1 = to_unsigned(400,10) report "x1 wrong" severity failure;
    assert blit_y1 = to_unsigned(300,10) report "y1 wrong" severity failure;
    assert blit_color = x"E0"         report "colour wrong" severity failure;
    assert blit_page = '1'            report "page wrong"  severity failure;

    wreg(16#F#, 0);                    -- trigger $884F
    wait until rising_edge(clk);       -- let the count settle
    wait until rising_edge(clk);
    assert start_seen = 1  report "expected exactly one start pulse, got " &
                                  integer'image(start_seen) severity failure;

    -- Sticky BUSY: set the instant $884F is written (engine busy still 0), so the
    -- CPU sees BUSY immediately and does not race past through the CDC latency.
    addr <= x"F";
    wait until rising_edge(clk);
    assert rdata(7) = '1'
      report "sticky busy not asserted right after trigger" severity failure;

    -- engine busy arrives (CDC), runs, then drops -> sticky clears
    busy <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert rdata(7) = '1' report "busy should still be set while engine runs"
      severity failure;
    busy <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert rdata(7) = '0' report "sticky busy did not clear after op done"
      severity failure;

    report "tb_vic_blit_regs: PASS (decode + start pulse + sticky busy)" severity note;
    std.env.stop;
  end process;

end architecture;
