-- End-to-end testbench for d64_subsystem.
--
-- Serves the FAT32 card image (sim/generated/fat32_card.img) over the raw SD
-- read channel and drives the 6502 register interface:
--   MOUNT -> poll BUSY -> check MOUNTED
--   READ_SECTOR(18,1) -> poll BUSY -> read 256 bytes via the DATA port and
--   compare against the .d64 bytes at that sector.
--
-- This exercises the arbiter (fat32_reader then d64_drive over one channel) and
-- the auto-incrementing buffer data port, the way the 6502 will.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_d64_subsystem is
end entity;

architecture sim of tb_d64_subsystem is
  constant IMG_PATH     : string  := "sim/generated/fat32_card.img";
  constant CARD_SECTORS : integer := 2434;
  constant CARD_BYTES   : integer := CARD_SECTORS * 512;
  constant FILE_LBA     : integer := 2090;   -- testdisk.d64 start LBA on the card

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
    assert st = open_ok report "cannot open " & path
      & " (run `make fat32-card-image`)" severity failure;
    while not endfile(f) and i < CARD_BYTES loop
      read(f, c);
      img(i) := character'pos(c);
      i := i + 1;
    end loop;
    file_close(f);
    return img;
  end function;

  signal card : card_t := load_card(IMG_PATH);

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';

  signal cs     : std_logic := '0';
  signal we     : std_logic := '0';
  signal offset : std_logic_vector(3 downto 0) := (others => '0');
  signal din    : std_logic_vector(7 downto 0) := (others => '0');
  signal dout   : std_logic_vector(7 downto 0);

  signal sd_read       : std_logic;
  signal sd_read_addr  : std_logic_vector(31 downto 0);
  signal sd_read_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_read_valid : std_logic := '0';
  signal sd_read_end   : std_logic := '0';

  -- SD-stub request latch (never miss a one-cycle strobe)
  signal rd_pending : std_logic := '0';
  signal rd_lba     : std_logic_vector(31 downto 0) := (others => '0');
  signal rd_taken   : std_logic := '0';

  constant STATUS_BUSY    : integer := 0;
  constant STATUS_MOUNTED : integer := 3;
begin
  clk <= not clk after 5 ns;

  dut : entity work.d64_subsystem
    port map (
      clk      => clk,
      reset_n  => reset_n,
      cs       => cs,
      we       => we,
      offset   => offset,
      din      => din,
      dout     => dout,
      sd_sec_read            => sd_read,
      sd_sec_read_addr       => sd_read_addr,
      sd_sec_read_data       => sd_read_data,
      sd_sec_read_data_valid => sd_read_valid,
      sd_sec_read_end        => sd_read_end
    );

  stub_latch : process(clk)
  begin
    if rising_edge(clk) then
      if sd_read = '1' then
        rd_pending <= '1';
        rd_lba     <= sd_read_addr;
      elsif rd_taken = '1' then
        rd_pending <= '0';
      end if;
    end if;
  end process;

  sd_stub : process
    variable base : integer;
  begin
    sd_read_valid <= '0';
    sd_read_end   <= '0';
    rd_taken      <= '0';
    loop
      wait until rising_edge(clk);
      if rd_pending = '1' then
        rd_taken <= '1';
        base := to_integer(unsigned(rd_lba)) * 512;
        wait until rising_edge(clk);
        rd_taken <= '0';
        for i in 0 to 511 loop
          wait until rising_edge(clk);
          if base + i < CARD_BYTES then
            sd_read_data <= std_logic_vector(to_unsigned(card(base + i), 8));
          else
            sd_read_data <= (others => '0');
          end if;
          sd_read_valid <= '1';
          if i = 511 then
            sd_read_end <= '1';
          end if;
        end loop;
        wait until rising_edge(clk);
        sd_read_valid <= '0';
        sd_read_end   <= '0';
      end if;
    end loop;
  end process;

  main : process
    -- write one register
    -- write one register.  Models the real CPU bus cycle EXACTLY: on hardware
    -- cpu_enable toggles every clk, disk_cs is high for TWO clocks but
    -- disk_we = cpu_we AND NOT cpu_enable is high for only ONE of them (the
    -- cpu_enable=0 clock).  So cs is held 2 clocks while we pulses 1 clock.
    procedure reg_write(ofs : integer; val : integer) is
    begin
      offset <= std_logic_vector(to_unsigned(ofs, 4));
      din    <= std_logic_vector(to_unsigned(val, 8));
      cs     <= '1';
      we     <= '1';
      wait until rising_edge(clk);     -- clock 1: cs=1, we=1 (the write fires)
      we     <= '0';
      wait until rising_edge(clk);     -- clock 2: cs=1, we=0 (we already dropped)
      cs <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- read one register. Models the real CPU bus cycle: cs is held high for TWO
    -- system clocks (cpu_enable toggles every clk on hardware), so the DATA-port
    -- auto-increment must fire exactly once per access, not once per clock.
    procedure reg_read(ofs : integer; result : out integer) is
    begin
      offset <= std_logic_vector(to_unsigned(ofs, 4));
      cs     <= '1';
      we     <= '0';
      wait until rising_edge(clk);     -- clock 1 of the access
      wait until rising_edge(clk);     -- clock 2 of the access
      wait for 1 ns;
      result := to_integer(unsigned(dout));
      cs <= '0';
      wait until rising_edge(clk);     -- access ends (falling edge of cs)
    end procedure;

    procedure wait_not_busy is
      variable st : integer;
    begin
      loop
        reg_read(0, st);
        exit when (st mod 2) = 0;   -- STATUS_BUSY is bit 0
      end loop;
    end procedure;

    -- d64 byte offset of (t,s) within the image
    function d64_offset(t, s : integer) return integer is
      variable idx : integer;
    begin
      if    t >= 1  and t <= 17 then idx := (t - 1) * 21 + s;
      elsif t >= 18 and t <= 24 then idx := 357 + (t - 18) * 19 + s;
      elsif t >= 25 and t <= 30 then idx := 490 + (t - 25) * 18 + s;
      else                            idx := 598 + (t - 31) * 17 + s;
      end if;
      return idx * 256;
    end function;

    variable st  : integer;
    variable val : integer;
    variable card_off : integer;
  begin
    reset_n <= '0';
    wait for 40 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    -- ── MOUNT ────────────────────────────────────────────────────────────
    reg_write(1, 16#03#);     -- COMMAND = MOUNT
    wait_not_busy;
    reg_read(0, st);
    assert (st / 4) mod 2 = 0  -- ERROR is bit 2
      report "mount reported ERROR, status=" & integer'image(st) severity failure;
    assert (st / 8) mod 2 = 1  -- MOUNTED is bit 3
      report "not MOUNTED after mount, status=" & integer'image(st) severity failure;

    -- ── Debug-word readback: data_start (selector 0) for the default MBR card
    -- = part_lba(2048) + reserved(32) + 2*spf(1) = 2082.
    reg_write(7, 0);            -- DBG_SEL = data_start
    reg_read(8, val);          -- LBA byte 0
    reg_read(9, st);           -- LBA byte 1
    val := val + st * 256;
    assert val = 2082
      report "debug data_start = " & integer'image(val) & " expected 2082"
      severity failure;
    -- root_lba (selector 2) must also be 2082 (root_clus 2 -> data_start)
    reg_write(7, 2);
    reg_read(8, val);
    reg_read(9, st);
    val := val + st * 256;
    assert val = 2082
      report "debug root_lba = " & integer'image(val) & " expected 2082"
      severity failure;

    -- A raw debug read first (sets raw_active and fills raw_buf); the following
    -- READ_SECTOR must switch the DATA port back to the drive buffer, not leave
    -- the stale raw contents (regression for the raw_active-stuck bug).
    reg_write(2, 0);           -- half-select = lower (reg_track bit0)
    reg_write(8, 0); reg_write(9, 0); reg_write(10, 0); reg_write(11, 0);  -- LBA 0
    reg_write(1, 16#05#);      -- COMMAND = RAW_READ
    wait_not_busy;

    -- ── READ_SECTOR(18,1) ─────────────────────────────────────────────────
    reg_write(2, 18);          -- TRACK
    reg_write(3, 1);           -- SECTOR
    reg_write(1, 16#01#);      -- COMMAND = READ_SECTOR
    wait_not_busy;
    reg_read(4, val);          -- RESULT
    assert val = 0
      report "READ_SECTOR result=" & integer'image(val) & " expected 0"
      severity failure;

    -- Read 256 bytes via the DATA port (auto-increment) and compare.
    -- Reset the pointer first (defensive; READ also resets it).
    reg_write(6, 0);           -- PTR_LO = 0
    card_off := FILE_LBA * 512 + d64_offset(18, 1);
    for i in 0 to 255 loop
      reg_read(5, val);        -- DATA (auto-increments pointer)
      assert val = card(card_off + i)
        report "T18/S1 byte " & integer'image(i)
             & " got " & integer'image(val)
             & " expected " & integer'image(card(card_off + i))
        severity failure;
    end loop;

    -- ── MOUNT_LBA: mount a specific LBA (the menu path) and read from it ────
    -- Write FILE_LBA into $882C-$882F, CMD_MOUNT_LBA, then READ T18/S1.
    reg_write(8,  FILE_LBA mod 256);
    reg_write(9,  (FILE_LBA / 256) mod 256);
    reg_write(10, (FILE_LBA / 65536) mod 256);
    reg_write(11, 0);
    reg_write(1, 16#07#);      -- COMMAND = MOUNT_LBA
    wait_not_busy;
    reg_read(0, st);
    assert (st / 8) mod 2 = 1 report "not MOUNTED after MOUNT_LBA" severity failure;
    reg_write(2, 18);
    reg_write(3, 1);
    reg_write(1, 16#01#);
    wait_not_busy;
    reg_write(6, 0);
    card_off := FILE_LBA * 512 + d64_offset(18, 1);
    for i in 0 to 255 loop
      reg_read(5, val);
      assert val = card(card_off + i)
        report "MOUNT_LBA T18/S1 byte " & integer'image(i) & " mismatch"
        severity failure;
    end loop;

    -- ── RE-MOUNT_LBA to a DIFFERENT LBA: the read must target the NEW LBA ──
    -- Regression for the menu bug "always mounts the first disk": after the
    -- first CMD_MOUNT_LBA above, a second CMD_MOUNT_LBA to a distinct LBA must
    -- re-latch the drive's start LBA so the next read goes there, not the old one.
    reg_write(8,  (FILE_LBA+50) mod 256);
    reg_write(9,  ((FILE_LBA+50) / 256) mod 256);
    reg_write(10, ((FILE_LBA+50) / 65536) mod 256);
    reg_write(11, 0);
    reg_write(1, 16#07#);      -- COMMAND = MOUNT_LBA (new LBA)
    wait_not_busy;
    reg_write(2, 18);
    reg_write(3, 1);
    reg_write(1, 16#01#);      -- READ T18/S1
    wait_not_busy;
    -- engine requests target_lba = start_lba + index/2; for S1 index/2 = 0, so
    -- the SD request LBA should equal (FILE_LBA+50) + (d64_offset(18,1)/512).
    assert to_integer(unsigned(rd_lba)) = (FILE_LBA+50) + (d64_offset(18,1)/512)
      report "RE-MOUNT_LBA: read went to LBA " & integer'image(to_integer(unsigned(rd_lba)))
           & " expected " & integer'image((FILE_LBA+50) + (d64_offset(18,1)/512))
      severity failure;

    -- ── READ an invalid sector -> ERROR, RESULT=INVALID_SECTOR ($03) ───────
    reg_write(2, 1);
    reg_write(3, 21);          -- T1/S21 invalid
    reg_write(1, 16#01#);
    wait_not_busy;
    reg_read(0, st);
    assert (st / 4) mod 2 = 1 report "expected ERROR for T1/S21" severity failure;
    reg_read(4, val);
    assert val = 16#03# report "expected INVALID_SECTOR ($03)" severity failure;

    -- ── UNMOUNT ────────────────────────────────────────────────────────────
    reg_write(1, 16#04#);      -- UNMOUNT
    wait_not_busy;
    reg_read(0, st);
    assert (st / 8) mod 2 = 0 report "still MOUNTED after unmount" severity failure;

    report "tb_d64_subsystem passed";
    finish;
  end process;
end architecture;
