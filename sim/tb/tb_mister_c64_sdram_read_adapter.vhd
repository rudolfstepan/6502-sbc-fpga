-- Integration testbench for the D64 SDRAM read chain:
--
--   c1541_d64_sector_source  ->  mister_c64_sdram_read_adapter  ->  (fake sdram_ctrl)
--
-- Low-byte-only convention (see rtl/core/mem/sdram_if.vhd): each 16-bit word
-- carries one .d64 byte in the low byte; the high byte is don't-care (driven to
-- xFF here to prove the adapter ignores it).  word_addr = byte_addr, so the byte
-- delivered to the sector source must equal g(byte_addr) with g(a)=a[7:0]^a[15:8].
-- Any offset or sector_index error shows up as a mismatch.  This exercises the
-- whole read path end to end, including the burst handshake.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_mister_c64_sdram_read_adapter is
end entity;

architecture sim of tb_mister_c64_sdram_read_adapter is
  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  -- disk request into the sector source
  signal track  : std_logic_vector(7 downto 0) := (others => '0');
  signal sector : std_logic_vector(4 downto 0) := (others => '0');
  signal offset : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);
  signal valid  : std_logic;

  -- sector source <-> adapter
  signal ss_addr  : std_logic_vector(22 downto 0);
  signal ss_rd    : std_logic;
  signal ss_ready : std_logic;
  signal ss_valid : std_logic;
  signal ss_q     : std_logic_vector(7 downto 0);

  -- adapter <-> fake sdram_ctrl
  signal rb_req    : std_logic;
  signal rb_addr   : std_logic_vector(23 downto 0);
  signal rb_len    : std_logic_vector(9 downto 0);
  signal rb_data   : std_logic_vector(15 downto 0) := (others => '0');
  signal rb_dvalid : std_logic := '0';
  signal ctrl_idle : std_logic := '1';

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

  src : entity work.c1541_d64_sector_source
    generic map ( D64_BASE => 0 )
    port map (
      clk         => clk,
      reset       => reset,
      track       => track,
      sector      => sector,
      offset      => offset,
      dout        => dout,
      valid       => valid,
      sdram_addr  => ss_addr,
      sdram_rd    => ss_rd,
      sdram_q     => ss_q,
      sdram_valid => ss_valid,
      sdram_ready => ss_ready
    );

  adp : entity work.mister_c64_sdram_read_adapter
    generic map ( D64_WORD_BASE => 0 )
    port map (
      clk                 => clk,
      reset               => reset,
      req_addr            => ss_addr,
      req_rd              => ss_rd,
      req_ready           => ss_ready,
      req_valid           => ss_valid,
      req_data            => ss_q,
      rd_burst_req        => rb_req,
      rd_burst_addr       => rb_addr,
      rd_burst_len        => rb_len,
      rd_burst_data       => rb_data,
      rd_burst_data_valid => rb_dvalid,
      ctrl_idle           => ctrl_idle
    );

  -- Behavioural sdram_ctrl: accept a 1-word read, deliver packed data after a
  -- few cycles (ACTIVE/RCD/CAS), then return to idle.
  fake_ctrl : process(clk)
    variable st : integer := 0;
    variable wa : integer := 0;
  begin
    if rising_edge(clk) then
      rb_dvalid <= '0';
      if reset = '1' then
        st := 0;
        ctrl_idle <= '1';
      else
        case st is
          when 0 =>
            ctrl_idle <= '1';
            if rb_req = '1' then
              wa := to_integer(unsigned(rb_addr));
              ctrl_idle <= '0';
              st := 1;
            end if;
          when 1 =>
            ctrl_idle <= '0';
            st := 2;
          when 2 =>
            ctrl_idle <= '0';
            st := 3;
          when 3 =>
            rb_data   <= x"FF" & gbyte(wa);   -- low byte = data, high = don't-care
            rb_dvalid <= '1';
            ctrl_idle <= '1';
            st := 0;
          when others =>
            st := 0;
        end case;
      end if;
    end if;
  end process;

  stim : process
    procedure wait_valid is
      variable n : integer := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when valid = '1';
        n := n + 1;
        assert n < 40000 report "timeout waiting for valid" severity failure;
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
    wait for 55 ns;
    wait until rising_edge(clk);
    reset <= '0';

    wait until rising_edge(clk);
    assert valid = '0'
      report "valid should be low before the first fill completes"
      severity failure;

    read_check(18, 0);
    read_check(18, 1);
    read_check(17, 0);
    read_check(1, 0);
    read_check(35, 16);
    read_check(18, 0);

    report "tb_mister_c64_sdram_read_adapter passed";
    done <= true;
    wait for 40 ns;
    finish;
  end process;
end architecture;
