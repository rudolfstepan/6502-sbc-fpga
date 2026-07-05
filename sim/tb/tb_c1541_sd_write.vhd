-- Testbench for the c1541_sd_d64_sector_source write-back path.
--
-- A behavioural SD card model implements both directions of the ALINX raw
-- sector channel: reads stream 512 fixture bytes, writes pulse data_req per
-- byte and sample sd_sec_write_data one clock later (exactly the timing of
-- sd_card_sec_read_write.v / spi_master.v).  The card content is a real
-- array, so a flushed sector is visible to the following refetch.
--
-- Checks:
--   * baseline read of T18/S0 returns fixture data,
--   * a 256-byte write burst + wr_commit triggers the RMW flush: one read of
--     the containing block, then one write of the same LBA whose written half
--     is the burst data and whose other half is the preserved card content,
--   * wr_busy is high during the flush and low after,
--   * the buffered sector is invalidated and the automatic refetch returns
--     the freshly written data,
--   * the partner sector in the same SD block (T17/S20) is untouched,
--   * a second burst to T18/S1 (even sector index -> lower half) also lands.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_c1541_sd_write is
end entity;

architecture sim of tb_c1541_sd_write is
  constant C_MOUNT_LBA : integer := 1000;

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal track  : std_logic_vector(7 downto 0) := (others => '0');
  signal sector : std_logic_vector(4 downto 0) := (others => '0');
  signal offset : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);
  signal valid  : std_logic;

  signal wr_en     : std_logic := '0';
  signal wr_offset : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_commit : std_logic := '0';
  signal wr_busy   : std_logic;

  signal sd_init_done : std_logic := '1';
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

  signal mount_lba    : std_logic_vector(31 downto 0) := (others => '0');
  signal mount_strobe : std_logic := '0';

  signal done : boolean := false;

  -- Card model: 1024 blocks starting at C_MOUNT_LBA.
  type card_t is array (0 to 1024 * 512 - 1) of std_logic_vector(7 downto 0);

  -- Statistics observed by the card model, checked by the stimulus.
  signal mdl_read_count  : integer := 0;
  signal mdl_write_count : integer := 0;
  signal mdl_last_read_lba  : integer := -1;
  signal mdl_last_write_lba : integer := -1;

  function fixture(lba : integer; idx : integer) return std_logic_vector is
    variable a : unsigned(31 downto 0);
  begin
    a := to_unsigned(lba * 512 + idx, 32);
    return std_logic_vector(a(7 downto 0) xor a(15 downto 8));
  end function;

  -- TB copy of the sector map (mirrors d64_sector_map.vhd).
  function sidx(t, s : integer) return integer is
  begin
    if    t >= 1  and t <= 17 then return (t - 1) * 21 + s;
    elsif t >= 18 and t <= 24 then return 357 + (t - 18) * 19 + s;
    elsif t >= 25 and t <= 30 then return 490 + (t - 25) * 18 + s;
    else  return 598 + (t - 31) * 17 + s;
    end if;
  end function;

  function pattern1(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(i, 8) xor x"A5");
  end function;

  function pattern2(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(i, 8) xor x"3C");
  end function;
begin
  clk <= not clk after 18 ns when not done else '0';  -- ~27 MHz

  dut : entity work.c1541_sd_d64_sector_source
    generic map (
      RAW_D64_LBA     => x"00000000",
      PACKED_D64_FILE => true,
      SD_WRITE_ENABLE => true
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
      sd_init_done           => sd_init_done,
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
      mount_lba    => mount_lba,
      mount_strobe => mount_strobe,
      uart_tx      => open
    );

  -- SD card model: one outstanding transfer at a time, like the board arbiter
  -- grants them.  Write timing mirrors sd_card_sec_read_write.v: a one-clock
  -- data_req, the byte is sampled on the following clock.
  card_model : process
    variable card : card_t;
    variable lba  : integer;
    variable base : integer;
  begin
    for i in card_t'range loop
      card(i) := fixture(C_MOUNT_LBA + i / 512, i mod 512);
    end loop;

    loop
      wait until rising_edge(clk);
      exit when done;

      if sd_sec_read = '1' then
        lba := to_integer(unsigned(sd_sec_read_addr));
        assert lba >= C_MOUNT_LBA and lba < C_MOUNT_LBA + 1024
          report "read LBA out of card range: " & integer'image(lba)
          severity failure;
        base := (lba - C_MOUNT_LBA) * 512;
        mdl_last_read_lba <= lba;
        -- a little command latency
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        for i in 0 to 511 loop
          sd_sec_read_data       <= card(base + i);
          sd_sec_read_data_valid <= '1';
          wait until rising_edge(clk);
          sd_sec_read_data_valid <= '0';
          wait until rising_edge(clk);
          wait until rising_edge(clk);
        end loop;
        sd_sec_read_end <= '1';
        wait until rising_edge(clk);
        sd_sec_read_end <= '0';
        mdl_read_count <= mdl_read_count + 1;

      elsif sd_sec_write = '1' then
        lba := to_integer(unsigned(sd_sec_write_addr));
        assert lba >= C_MOUNT_LBA and lba < C_MOUNT_LBA + 1024
          report "write LBA out of card range: " & integer'image(lba)
          severity failure;
        base := (lba - C_MOUNT_LBA) * 512;
        mdl_last_write_lba <= lba;
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        for i in 0 to 511 loop
          sd_sec_write_data_req <= '1';
          wait until rising_edge(clk);
          sd_sec_write_data_req <= '0';
          wait until rising_edge(clk);
          -- byte is valid one clock after the request
          card(base + i) := sd_sec_write_data;
          wait until rising_edge(clk);
          wait until rising_edge(clk);
        end loop;
        sd_sec_write_end <= '1';
        wait until rising_edge(clk);
        sd_sec_write_end <= '0';
        mdl_write_count <= mdl_write_count + 1;
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
      -- first wait for the flush to start, then to finish
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
      wr_data   <= d;
      wr_en     <= '1';
      tick;
      wr_en <= '0';
      tick;
      tick;
    end procedure;

    variable blk_lba   : integer;
    variable exp_reads : integer;
  begin
    reset <= '1';
    track  <= std_logic_vector(to_unsigned(18, 8));
    sector <= "00000";
    for i in 1 to 5 loop tick; end loop;
    reset <= '0';

    -- Mount at C_MOUNT_LBA.
    mount_lba <= std_logic_vector(to_unsigned(C_MOUNT_LBA, 32));
    mount_strobe <= '1';
    tick;
    mount_strobe <= '0';

    -- ── Baseline read T18/S0 ─────────────────────────────────────────────
    -- sector index 357 (odd) -> LBA MOUNT+178, upper half.
    blk_lba := C_MOUNT_LBA + sidx(18, 0) / 2;
    wait_valid;
    assert mdl_last_read_lba = blk_lba
      report "T18/S0 fetch used LBA " & integer'image(mdl_last_read_lba)
           & " expected " & integer'image(blk_lba) severity failure;
    check_byte(0,   fixture(blk_lba, 256 + 0),   "T18/S0 fixture");
    check_byte(129, fixture(blk_lba, 256 + 129), "T18/S0 fixture");
    check_byte(255, fixture(blk_lba, 256 + 255), "T18/S0 fixture");

    -- ── Write burst to T18/S0 ────────────────────────────────────────────
    for i in 0 to 255 loop
      write_burst_byte(i, pattern1(i));
    end loop;
    exp_reads := mdl_read_count;
    wr_commit <= '1';
    tick;
    wr_commit <= '0';
    wait_flush_done;

    assert mdl_write_count = 1
      report "expected exactly one block write, got "
           & integer'image(mdl_write_count) severity failure;
    assert mdl_last_write_lba = blk_lba
      report "flush wrote LBA " & integer'image(mdl_last_write_lba)
           & " expected " & integer'image(blk_lba) severity failure;
    assert mdl_read_count = exp_reads + 1
      report "flush should read the block exactly once (RMW)" severity failure;

    -- The buffered sector was invalidated; the source refetches on its own
    -- and must now return the written data.
    wait_valid;
    check_byte(0,   pattern1(0),   "T18/S0 after write");
    check_byte(77,  pattern1(77),  "T18/S0 after write");
    check_byte(255, pattern1(255), "T18/S0 after write");

    -- ── Partner sector in the same block must be preserved ───────────────
    -- sector index 356 = T17/S20 -> same LBA, lower half.
    track  <= std_logic_vector(to_unsigned(17, 8));
    sector <= std_logic_vector(to_unsigned(20, 5));
    wait_valid;
    check_byte(0,   fixture(blk_lba, 0),   "T17/S20 preserved");
    check_byte(200, fixture(blk_lba, 200), "T17/S20 preserved");

    -- ── Second burst: T18/S1 (even index 358 -> lower half) ──────────────
    track  <= std_logic_vector(to_unsigned(18, 8));
    sector <= std_logic_vector(to_unsigned(1, 5));
    wait_valid;   -- let the prefetch settle so the flush target is unambiguous
    blk_lba := C_MOUNT_LBA + sidx(18, 1) / 2;
    for i in 0 to 255 loop
      write_burst_byte(i, pattern2(i));
    end loop;
    wr_commit <= '1';
    tick;
    wr_commit <= '0';
    wait_flush_done;

    assert mdl_write_count = 2
      report "expected a second block write" severity failure;
    assert mdl_last_write_lba = blk_lba
      report "second flush wrote LBA " & integer'image(mdl_last_write_lba)
           & " expected " & integer'image(blk_lba) severity failure;

    wait_valid;
    check_byte(0,   pattern2(0),   "T18/S1 after write");
    check_byte(128, pattern2(128), "T18/S1 after write");
    check_byte(255, pattern2(255), "T18/S1 after write");

    -- T18/S0 (upper half of a DIFFERENT block) still holds pattern1.
    track  <= std_logic_vector(to_unsigned(18, 8));
    sector <= "00000";
    wait_valid;
    check_byte(11, pattern1(11), "T18/S0 still intact");

    report "tb_c1541_sd_write passed";
    done <= true;
    wait for 100 ns;
    finish;
  end process;
end architecture;
