-- Testbench for c1541_v1541_uart_sector_source.
--
-- A fake PC speaks the tools/virtual_1541 CMD_SECTOR protocol at the bit level:
-- it decodes the DUT's request frame with a real uart_rx_ser, verifies the
-- request checksum, and replies with a real uart_tx_ser.  The sector payload is
-- g(sector_index*256 + offset), g(a) = a[7:0] xor a[15:8], so any framing,
-- track/sector or offset error surfaces as a mismatch.  This exercises the full
-- round trip incl. UART serialisation, the response parser and the valid-stall.
--
-- Small CLK_HZ/BAUD ratio keeps the simulation short.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_c1541_v1541_uart_sector_source is
end entity;

architecture sim of tb_c1541_v1541_uart_sector_source is
  constant CLK_HZ : positive := 1_000_000;
  constant BAUD   : positive := 250_000;

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal track  : std_logic_vector(7 downto 0) := (others => '0');
  signal sector : std_logic_vector(4 downto 0) := (others => '0');
  signal offset : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);
  signal valid  : std_logic;

  signal fpga_tx : std_logic;   -- DUT -> PC
  signal pc_tx   : std_logic := '1';   -- PC -> DUT

  -- PC-side UART leaves
  signal pc_rx_data  : std_logic_vector(7 downto 0);
  signal pc_rx_valid : std_logic;
  signal pc_tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal pc_tx_valid : std_logic := '0';
  signal pc_tx_busy  : std_logic;

  signal done : boolean := false;

  function gbyte(ba : integer) return std_logic_vector is
    variable u : unsigned(23 downto 0) := to_unsigned(ba, 24);
  begin
    return std_logic_vector(u(7 downto 0) xor u(15 downto 8));
  end function;

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
  clk <= not clk after 10 ns when not done else '0';

  dut : entity work.c1541_v1541_uart_sector_source
    generic map ( CLK_HZ => CLK_HZ, BAUD => BAUD, TIMEOUT_CYC => 100_000 )
    port map (
      clk => clk, reset => reset,
      track => track, sector => sector, offset => offset,
      dout => dout, valid => valid,
      uart_rx => pc_tx, uart_tx => fpga_tx
    );

  -- PC-side UART cores.
  pc_rx_i : entity work.uart_rx_ser
    generic map ( CLK_HZ => CLK_HZ, BAUD => BAUD )
    port map ( clk => clk, reset_n => not reset, rx => fpga_tx,
               data => pc_rx_data, valid => pc_rx_valid );

  pc_tx_i : entity work.uart_tx_ser
    generic map ( CLK_HZ => CLK_HZ, BAUD => BAUD )
    port map ( clk => clk, reset_n => not reset, data => pc_tx_data,
               valid => pc_tx_valid, tx => pc_tx, busy => pc_tx_busy );

  -- Fake virtual-1541 PC: decode a CMD_SECTOR request, answer with the sector.
  pc : process
    variable b     : std_logic_vector(7 downto 0);
    variable trk   : integer;
    variable sec   : integer;
    variable cks   : integer;
    variable base  : integer;
    variable rcks  : unsigned(7 downto 0);

    procedure get_byte(v : out std_logic_vector(7 downto 0)) is
    begin
      loop
        wait until rising_edge(clk);
        exit when pc_rx_valid = '1';
      end loop;
      v := pc_rx_data;
    end procedure;

    procedure send_byte(d : std_logic_vector(7 downto 0)) is
    begin
      loop wait until rising_edge(clk); exit when pc_tx_busy = '0'; end loop;
      pc_tx_data  <= d;
      pc_tx_valid <= '1';
      wait until rising_edge(clk);
      pc_tx_valid <= '0';
      loop wait until rising_edge(clk); exit when pc_tx_busy = '1'; end loop;
      loop wait until rising_edge(clk); exit when pc_tx_busy = '0'; end loop;
    end procedure;
  begin
    loop
      exit when done;
      -- resync on request magic
      get_byte(b);
      next when b /= x"C6";
      get_byte(b);  assert b = x"30" report "req cmd != SECTOR" severity failure;
      get_byte(b);  assert b = x"02" report "req len_lo != 2"   severity failure;
      get_byte(b);  assert b = x"00" report "req len_hi != 0"   severity failure;
      get_byte(b);  trk := to_integer(unsigned(b));
      get_byte(b);  sec := to_integer(unsigned(b));
      get_byte(b);  cks := to_integer(unsigned(b));
      assert cks = ((16#32# + trk + sec) mod 256)
        report "bad request checksum from DUT" severity failure;

      -- response: 64 30 00 00 01 <256 bytes> <cks>
      base := sidx(trk, sec) * 256;
      rcks := to_unsigned((16#30# + 16#00# + 16#00# + 16#01#) mod 256, 8);
      send_byte(x"64");
      send_byte(x"30");
      send_byte(x"00");           -- status OK
      send_byte(x"00");           -- len_lo
      send_byte(x"01");           -- len_hi (256)
      for off in 0 to 255 loop
        send_byte(gbyte(base + off));
        rcks := rcks + unsigned(gbyte(base + off));
      end loop;
      send_byte(std_logic_vector(rcks));
    end loop;
    wait;
  end process;

  stim : process
    procedure wait_valid is
      variable n : integer := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when valid = '1';
        n := n + 1;
        assert n < 2_000_000 report "timeout waiting for valid" severity failure;
      end loop;
    end procedure;

    procedure read_check(t, s : integer) is
      variable e : std_logic_vector(7 downto 0);
    begin
      track  <= std_logic_vector(to_unsigned(t, 8));
      sector <= std_logic_vector(to_unsigned(s, 5));
      wait_valid;
      for off in 0 to 255 loop
        offset <= std_logic_vector(to_unsigned(off, 8));
        wait for 1 ns;
        e := gbyte(sidx(t, s) * 256 + off);
        assert dout = e
          report "T" & integer'image(t) & "/S" & integer'image(s)
               & "/O" & integer'image(off)
               & " got x" & to_hstring(dout)
               & " expected x" & to_hstring(e) severity failure;
      end loop;
    end procedure;
  begin
    reset  <= '1';
    track  <= x"12";
    sector <= "00000";
    offset <= x"00";
    wait for 200 ns;
    wait until rising_edge(clk);
    reset <= '0';

    wait until rising_edge(clk);
    assert valid = '0'
      report "valid must be low until the first sector arrives" severity failure;

    read_check(18, 0);
    read_check(18, 1);
    read_check(17, 0);
    read_check(1, 0);
    read_check(35, 16);
    read_check(18, 0);

    report "tb_c1541_v1541_uart_sector_source passed";
    done <= true;
    wait for 100 ns;
    finish;
  end process;
end architecture;
