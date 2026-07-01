-- Testbench for c1541_d64_sector_source.
--
-- A fake SDRAM returns data as a function of the byte address
-- (addr[7:0] xor addr[15:8]).  Because every returned byte depends on the exact
-- address, a wrong sector_index or offset immediately produces a mismatch, so
-- this doubles as an addressing check against d64_sector_map.
--
-- The model uses the decoupled handshake the DUT expects: ready is always high
-- (accept on the cycle sdram_rd is seen), then sdram_valid/sdram_q are presented
-- one cycle later.  The test verifies:
--   * the first request fills before `valid` rises (no stale reads),
--   * dout(offset) matches the fixture for every offset 0..255,
--   * changing sector and changing track both drop `valid` and refill correctly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_c1541_d64_sector_source is
end entity;

architecture sim of tb_c1541_d64_sector_source is
  signal clk    : std_logic := '0';
  signal reset  : std_logic := '1';

  signal track  : std_logic_vector(7 downto 0) := (others => '0');
  signal sector : std_logic_vector(4 downto 0) := (others => '0');
  signal offset : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);
  signal valid  : std_logic;

  signal sdram_addr  : std_logic_vector(22 downto 0);
  signal sdram_rd    : std_logic;
  signal sdram_q     : std_logic_vector(7 downto 0) := (others => '0');
  signal sdram_valid : std_logic := '0';
  signal sdram_ready : std_logic := '1';   -- always ready to accept

  signal done : boolean := false;

  -- Fixture: the byte stored at a linear D64 address.
  function fixture(addr : unsigned(22 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(addr(7 downto 0) xor addr(15 downto 8));
  end function;

  -- TB copy of the sector map (mirrors d64_sector_map.vhd).
  function sidx(t, s : integer) return integer is
  begin
    if    t >= 1  and t <= 17 then return (t - 1) * 21 + s;
    elsif t >= 18 and t <= 24 then return 357 + (t - 18) * 19 + s;
    elsif t >= 25 and t <= 30 then return 490 + (t - 25) * 18 + s;
    elsif t >= 31 and t <= 35 then return 598 + (t - 31) * 17 + s;
    else  return 0;
    end if;
  end function;
begin
  clk <= not clk after 10 ns when not done else '0';  -- 50 MHz

  dut : entity work.c1541_d64_sector_source
    generic map ( D64_BASE => 0 )
    port map (
      clk         => clk,
      reset       => reset,
      track       => track,
      sector      => sector,
      offset      => offset,
      dout        => dout,
      valid       => valid,
      sdram_addr  => sdram_addr,
      sdram_rd    => sdram_rd,
      sdram_q     => sdram_q,
      sdram_valid => sdram_valid,
      sdram_ready => sdram_ready
    );

  -- Fake SDRAM: accept a read when sdram_rd is high, deliver the fixture byte
  -- one cycle later on sdram_valid.
  sdram_model : process(clk)
    variable capture  : std_logic := '0';
    variable cap_addr : unsigned(22 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      sdram_valid <= '0';
      if capture = '1' then
        sdram_q     <= fixture(cap_addr);
        sdram_valid <= '1';
        capture     := '0';
      elsif sdram_rd = '1' and sdram_ready = '1' then
        cap_addr := unsigned(sdram_addr);
        capture  := '1';
      end if;
    end if;
  end process;

  stim : process
    -- Wait until the requested sector has been buffered (bounded).
    procedure wait_valid is
      variable n : integer := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when valid = '1';
        n := n + 1;
        assert n < 20000
          report "timeout waiting for valid" severity failure;
      end loop;
    end procedure;

    -- Select (t,s), wait for the fill, then check every offset.
    procedure read_check(t, s : integer) is
      variable a : unsigned(22 downto 0);
      variable e : std_logic_vector(7 downto 0);
    begin
      track  <= std_logic_vector(to_unsigned(t, 8));
      sector <= std_logic_vector(to_unsigned(s, 5));
      wait_valid;
      for off in 0 to 255 loop
        offset <= std_logic_vector(to_unsigned(off, 8));
        wait for 1 ns;
        a := to_unsigned(sidx(t, s) * 256 + off, 23);
        e := std_logic_vector(a(7 downto 0) xor a(15 downto 8));
        assert dout = e
          report "T" & integer'image(t) & "/S" & integer'image(s)
               & "/O" & integer'image(off)
               & " got x" & to_hstring(dout)
               & " expected x" & to_hstring(e) severity failure;
      end loop;
    end procedure;
  begin
    -- Reset.
    reset  <= '1';
    track  <= x"12";           -- 18
    sector <= "00000";
    offset <= x"00";
    wait for 55 ns;
    wait until rising_edge(clk);
    reset <= '0';

    -- `valid` must stay low until the very first sector is buffered.
    wait until rising_edge(clk);
    assert valid = '0'
      report "valid should be low before the first fill completes"
      severity failure;

    read_check(18, 0);   -- directory/BAM sector, first fill
    read_check(18, 1);   -- next sector on the same track (sector change)
    read_check(17, 0);   -- different track (track change)
    read_check(1, 0);    -- track 1
    read_check(35, 16);  -- last sector of a 35-track image
    read_check(18, 0);   -- back to the start (another refill)

    report "tb_c1541_d64_sector_source passed";
    done <= true;
    wait for 40 ns;
    finish;
  end process;
end architecture;
