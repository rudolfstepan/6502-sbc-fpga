-- Real-image test for c1541_sd_d64_sector_source write-back.
--
-- This does not emulate the 1541 CPU/GCR capture.  It starts at the decoded
-- write stream boundary (wr_en/wr_commit) and proves that a committed write to
-- T18/S1 lands in the correct 256-byte half of a packed .d64 inside a simulated
-- SD image.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_c1541_sd_write_image is
  generic (
    D64_PATH  : string  := "roms/test_d64/c64_basic_testdisk.d64";
    MOUNT_LBA : integer := 1000
  );
end entity;

architecture sim of tb_c1541_sd_write_image is
  constant D64_BYTES    : integer := 174848;
  constant D64_BLOCKS   : integer := (D64_BYTES + 511) / 512;
  constant CARD_SECTORS : integer := MOUNT_LBA + D64_BLOCKS + 8;
  constant CARD_BYTES   : integer := CARD_SECTORS * 512;

  type card_t is array (0 to CARD_BYTES - 1) of integer range 0 to 255;

  impure function load_card(path : string) return card_t is
    type charfile is file of character;
    file f       : charfile;
    variable c   : character;
    variable img : card_t := (others => 0);
    variable st  : file_open_status;
    variable i   : integer := 0;
  begin
    file_open(st, f, path, read_mode);
    assert st = open_ok
      report "cannot open " & path
      severity failure;
    while not endfile(f) and i < D64_BYTES loop
      read(f, c);
      img(MOUNT_LBA * 512 + i) := character'pos(c);
      i := i + 1;
    end loop;
    file_close(f);
    assert i = D64_BYTES
      report "D64 has wrong size: " & integer'image(i)
      severity failure;
    return img;
  end function;

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';
  signal done  : boolean := false;

  signal track  : std_logic_vector(7 downto 0) := x"12";
  signal sector : std_logic_vector(4 downto 0) := "00001";
  signal offset : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);
  signal valid  : std_logic;

  signal wr_en     : std_logic := '0';
  signal wr_offset : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_commit : std_logic := '0';
  signal wr_busy   : std_logic;

  signal sd_sec_read            : std_logic;
  signal sd_sec_read_addr       : std_logic_vector(31 downto 0);
  signal sd_sec_read_data       : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_sec_read_data_valid : std_logic := '0';
  signal sd_sec_read_end        : std_logic := '0';
  signal sd_sec_write           : std_logic;
  signal sd_sec_write_addr      : std_logic_vector(31 downto 0);
  signal sd_sec_write_data      : std_logic_vector(7 downto 0);
  signal sd_sec_write_data_req  : std_logic := '0';
  signal sd_sec_write_end       : std_logic := '0';

  signal mount_lba_s  : std_logic_vector(31 downto 0) := (others => '0');
  signal mount_strobe : std_logic := '0';

  signal read_count     : integer := 0;
  signal write_count    : integer := 0;
  signal last_read_lba  : integer := -1;
  signal last_write_lba : integer := -1;

  function sidx(t, s : integer) return integer is
  begin
    if    t >= 1  and t <= 17 then return (t - 1) * 21 + s;
    elsif t >= 18 and t <= 24 then return 357 + (t - 18) * 19 + s;
    elsif t >= 25 and t <= 30 then return 490 + (t - 25) * 18 + s;
    else  return 598 + (t - 31) * 17 + s;
    end if;
  end function;

  function write_pattern(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 37 + 16#5A#) mod 256, 8));
  end function;
begin
  clk <= not clk after 18 ns when not done else '0';

  dut : entity work.c1541_sd_d64_sector_source
    generic map (
      RAW_D64_LBA       => x"00000000",
      PACKED_D64_FILE   => true,
      SD_WRITE_ENABLE   => true,
      SD_BYTE_ADDRESSING => false
    )
    port map (
      clk     => clk,
      reset   => reset,
      track   => track,
      sector  => sector,
      offset  => offset,
      dout    => dout,
      valid   => valid,
      wr_en     => wr_en,
      wr_offset => wr_offset,
      wr_data   => wr_data,
      wr_commit => wr_commit,
      wr_busy   => wr_busy,
      sd_init_done           => '1',
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_data_valid,
      sd_sec_read_end        => sd_sec_read_end,
      sd_sec_write           => sd_sec_write,
      sd_sec_write_addr      => sd_sec_write_addr,
      sd_sec_write_data      => sd_sec_write_data,
      sd_sec_write_data_req  => sd_sec_write_data_req,
      sd_sec_write_end       => sd_sec_write_end,
      mount_lba              => mount_lba_s,
      mount_strobe           => mount_strobe,
      uart_tx                => open
    );

  card_model : process
    variable card : card_t := load_card(D64_PATH);
    variable lba  : integer;
    variable base : integer;
  begin
    loop
      wait until rising_edge(clk);
      exit when done;

      if sd_sec_read = '1' then
        lba := to_integer(unsigned(sd_sec_read_addr));
        assert lba >= 0 and lba < CARD_SECTORS
          report "read LBA out of range: " & integer'image(lba)
          severity failure;
        base := lba * 512;
        last_read_lba <= lba;
        for i in 1 to 12 loop wait until rising_edge(clk); end loop;
        for i in 0 to 511 loop
          sd_sec_read_data <= std_logic_vector(to_unsigned(card(base + i), 8));
          sd_sec_read_data_valid <= '1';
          wait until rising_edge(clk);
          sd_sec_read_data_valid <= '0';
          wait until rising_edge(clk);
        end loop;
        sd_sec_read_end <= '1';
        wait until rising_edge(clk);
        sd_sec_read_end <= '0';
        read_count <= read_count + 1;

      elsif sd_sec_write = '1' then
        lba := to_integer(unsigned(sd_sec_write_addr));
        assert lba >= 0 and lba < CARD_SECTORS
          report "write LBA out of range: " & integer'image(lba)
          severity failure;
        base := lba * 512;
        last_write_lba <= lba;
        for i in 1 to 12 loop wait until rising_edge(clk); end loop;
        for i in 0 to 511 loop
          sd_sec_write_data_req <= '1';
          wait until rising_edge(clk);
          sd_sec_write_data_req <= '0';
          wait until rising_edge(clk);
          card(base + i) := to_integer(unsigned(sd_sec_write_data));
          wait until rising_edge(clk);
        end loop;
        sd_sec_write_end <= '1';
        wait until rising_edge(clk);
        sd_sec_write_end <= '0';
        write_count <= write_count + 1;
      end if;
    end loop;
    wait;
  end process;

  stim : process
    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;

    procedure wait_valid is
      variable n : integer := 0;
    begin
      loop
        tick;
        exit when valid = '1';
        n := n + 1;
        assert n < 200000 report "timeout waiting for valid" severity failure;
      end loop;
    end procedure;

    procedure wait_flush_done is
      variable n : integer := 0;
    begin
      loop
        tick;
        exit when wr_busy = '1';
        n := n + 1;
        assert n < 1000 report "flush did not start" severity failure;
      end loop;
      n := 0;
      loop
        tick;
        exit when wr_busy = '0';
        n := n + 1;
        assert n < 400000 report "flush did not finish" severity failure;
      end loop;
    end procedure;

    procedure check_byte(off : integer; e : std_logic_vector(7 downto 0);
                         what : string) is
    begin
      offset <= std_logic_vector(to_unsigned(off, 8));
      wait for 1 ns;
      assert dout = e
        report what & " offset " & integer'image(off)
             & " got x" & to_hstring(dout) & " expected x" & to_hstring(e)
        severity failure;
    end procedure;

    procedure write_burst_byte(off : integer; d : std_logic_vector(7 downto 0)) is
    begin
      wr_offset <= std_logic_vector(to_unsigned(off, 8));
      wr_data <= d;
      wr_en <= '1';
      tick;
      wr_en <= '0';
      tick;
    end procedure;

    variable target_lba : integer;
    variable exp_reads  : integer;
    variable partner0   : std_logic_vector(7 downto 0);
    variable partner1   : std_logic_vector(7 downto 0);
  begin
    for i in 1 to 5 loop tick; end loop;
    reset <= '0';

    mount_lba_s <= std_logic_vector(to_unsigned(MOUNT_LBA, 32));
    mount_strobe <= '1';
    tick;
    mount_strobe <= '0';

    -- T18/S1 is the sector reported by the real DOS error.  It is sector index
    -- 358, therefore the lower half of SD block MOUNT_LBA+179.
    target_lba := MOUNT_LBA + sidx(18, 1) / 2;
    wait_valid;
    assert last_read_lba = target_lba
      report "initial T18/S1 fetch used LBA " & integer'image(last_read_lba)
           & " expected " & integer'image(target_lba)
      severity failure;

    -- Capture a couple of bytes from the partner half before the write.
    sector <= std_logic_vector(to_unsigned(2, 5));
    wait_valid;
    assert last_read_lba = target_lba
      report "initial T18/S2 should share same LBA" severity failure;
    offset <= x"00";
    wait for 1 ns;
    partner0 := dout;
    offset <= x"7F";
    wait for 1 ns;
    partner1 := dout;
    sector <= std_logic_vector(to_unsigned(1, 5));
    wait_valid;

    for i in 0 to 255 loop
      write_burst_byte(i, write_pattern(i));
    end loop;

    exp_reads := read_count;
    wr_commit <= '1';
    tick;
    wr_commit <= '0';
    wait_flush_done;

    assert write_count = 1 report "expected one SD block write" severity failure;
    assert last_write_lba = target_lba
      report "flush wrote LBA " & integer'image(last_write_lba)
           & " expected " & integer'image(target_lba)
      severity failure;
    assert read_count = exp_reads + 1
      report "flush must RMW-read the containing SD block once"
      severity failure;

    wait_valid;
    check_byte(0,   write_pattern(0),   "T18/S1 written image");
    check_byte(64,  write_pattern(64),  "T18/S1 written image");
    check_byte(255, write_pattern(255), "T18/S1 written image");

    -- Partner half of the same 512-byte block: T18/S2 must not be overwritten.
    sector <= std_logic_vector(to_unsigned(2, 5));
    wait_valid;
    assert last_read_lba = target_lba
      report "partner T18/S2 should share same LBA" severity failure;
    check_byte(0,   partner0, "T18/S2 preserved");
    check_byte(127, partner1, "T18/S2 preserved");

    report "tb_c1541_sd_write_image passed";
    done <= true;
    wait for 100 ns;
    finish;
  end process;
end architecture;
