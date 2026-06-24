-- Testbench for d64_drive.
--
-- A small SD stub serves a real testdisk.d64 (roms/test_d64/testdisk.d64,
-- regenerate with `make d64-test-image`) over the raw 512-byte read protocol.
-- The drive is mounted at file_start_lba=0 (the image sits at the start of the
-- simulated card) and then asked to read several D64 sectors; the captured
-- 256-byte buffer is compared against the bytes read straight from the file.
--
-- This locks the FPGA T/S -> LBA -> half-sector path to the same image the host
-- tooling produces, the way tb_d64_sector_map locks the mapper.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_d64_drive is
end entity;

architecture sim of tb_d64_drive is
  constant IMG_PATH  : string  := "roms/test_d64/testdisk.d64";
  constant IMG_BYTES : integer := 174848;

  type img_t is array (0 to IMG_BYTES - 1) of integer range 0 to 255;

  -- Load the whole D64 image into memory at elaboration.
  impure function load_image(path : string) return img_t is
    type charfile is file of character;
    file f       : charfile;
    variable c   : character;
    variable img : img_t := (others => 0);
    variable st  : file_open_status;
  begin
    file_open(st, f, path, read_mode);
    assert st = open_ok
      report "cannot open " & path & " (run `make d64-test-image`)"
      severity failure;
    for i in 0 to IMG_BYTES - 1 loop
      assert not endfile(f)
        report "image shorter than expected at byte " & integer'image(i)
        severity failure;
      read(f, c);
      img(i) := character'pos(c);
    end loop;
    file_close(f);
    return img;
  end function;

  signal image : img_t := load_image(IMG_PATH);

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';

  signal mount_s   : std_logic := '0';
  signal unmount_s : std_logic := '0';
  signal start_lba : std_logic_vector(31 downto 0) := (others => '0');

  signal rd_req    : std_logic := '0';
  signal rd_track  : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_sector : std_logic_vector(7 downto 0) := (others => '0');

  signal busy     : std_logic;
  signal done     : std_logic;
  signal error    : std_logic;
  signal mounted  : std_logic;
  signal wprot    : std_logic;
  signal result   : std_logic_vector(7 downto 0);

  signal buf_addr : std_logic_vector(7 downto 0) := (others => '0');
  signal buf_data : std_logic_vector(7 downto 0);

  -- SD stub <-> drive
  signal sd_read       : std_logic;
  signal sd_read_addr  : std_logic_vector(31 downto 0);
  signal sd_read_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_read_valid : std_logic := '0';
  signal sd_read_end   : std_logic := '0';
begin
  clk <= not clk after 5 ns;

  dut : entity work.d64_drive
    port map (
      clk            => clk,
      reset_n        => reset_n,
      mount          => mount_s,
      unmount        => unmount_s,
      file_start_lba => start_lba,
      write_protect_in => '1',
      rd_req         => rd_req,
      rd_track       => rd_track,
      rd_sector      => rd_sector,
      busy           => busy,
      done           => done,
      error          => error,
      mounted        => mounted,
      write_protect  => wprot,
      result         => result,
      buf_addr       => buf_addr,
      buf_data       => buf_data,
      sd_sec_read            => sd_read,
      sd_sec_read_addr       => sd_read_addr,
      sd_sec_read_data       => sd_read_data,
      sd_sec_read_data_valid => sd_read_valid,
      sd_sec_read_end        => sd_read_end
    );

  -- ── SD stub: on a read strobe, stream the 512 bytes of that LBA from image ─
  sd_stub : process
    variable base : integer;
  begin
    sd_read_valid <= '0';
    sd_read_end   <= '0';
    loop
      wait until rising_edge(clk);
      if sd_read = '1' then
        base := to_integer(unsigned(sd_read_addr)) * 512;
        for i in 0 to 511 loop
          wait until rising_edge(clk);
          if base + i < IMG_BYTES then
            sd_read_data <= std_logic_vector(to_unsigned(image(base + i), 8));
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
    -- expected linear byte offset of a D64 (track, sector) in the image
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

    -- Issue a READ_SECTOR and wait for completion.
    procedure read_sector(t, s : integer) is
    begin
      rd_track  <= std_logic_vector(to_unsigned(t, 8));
      rd_sector <= std_logic_vector(to_unsigned(s, 8));
      rd_req    <= '1';
      wait until rising_edge(clk);
      rd_req    <= '0';
      -- wait for busy to drop after it has risen (or for an immediate error)
      wait until rising_edge(clk);
      while busy = '1' loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- Verify the buffer equals the image bytes at d64_offset(t,s).
    procedure check_sector(t, s : integer) is
      variable off : integer;
      variable exp : integer;
    begin
      read_sector(t, s);
      assert error = '0'
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " unexpected error, result=" & integer'image(to_integer(unsigned(result)))
        severity failure;
      assert done = '1'
        report "T" & integer'image(t) & "/S" & integer'image(s) & " not done"
        severity failure;
      off := d64_offset(t, s);
      for i in 0 to 255 loop
        buf_addr <= std_logic_vector(to_unsigned(i, 8));
        wait until rising_edge(clk);
        wait until rising_edge(clk);  -- 1-cycle synchronous read latency
        exp := image(off + i);
        assert to_integer(unsigned(buf_data)) = exp
          report "T" & integer'image(t) & "/S" & integer'image(s)
               & " byte " & integer'image(i)
               & " got " & integer'image(to_integer(unsigned(buf_data)))
               & " expected " & integer'image(exp)
          severity failure;
      end loop;
    end procedure;
  begin
    reset_n <= '0';
    wait for 40 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    -- Reading before mount must report NO_IMAGE ($01).
    read_sector(18, 0);
    assert error = '1' and result = x"01"
      report "expected NO_IMAGE before mount" severity failure;

    -- Mount the image at LBA 0.
    start_lba <= (others => '0');
    mount_s   <= '1';
    wait until rising_edge(clk);
    mount_s   <= '0';
    wait until rising_edge(clk);
    assert mounted = '1' report "mount failed" severity failure;
    assert wprot = '1' report "expected write-protect" severity failure;

    -- Lower-half sector (T18/S1, offset 91648 -> block 179, half 0).
    check_sector(18, 1);
    -- Upper-half sector (T18/S0, offset 91392 -> block 178, half 0x100).
    check_sector(18, 0);
    -- First and last sectors of the image.
    check_sector(1, 0);
    check_sector(35, 16);
    -- A directory data sector (HELLO is at T1/S0 already checked); check T1/S1.
    check_sector(1, 1);

    -- Invalid sector on a valid track -> INVALID_SECTOR ($03), buffer untouched.
    read_sector(1, 21);
    assert error = '1' and result = x"03"
      report "expected INVALID_SECTOR for T1/S21" severity failure;

    -- Invalid track -> INVALID_TRACK ($02).
    read_sector(36, 0);
    assert error = '1' and result = x"02"
      report "expected INVALID_TRACK for T36" severity failure;

    -- Unmount, then a read must report NO_IMAGE again.
    unmount_s <= '1';
    wait until rising_edge(clk);
    unmount_s <= '0';
    wait until rising_edge(clk);
    assert mounted = '0' report "unmount failed" severity failure;
    read_sector(18, 0);
    assert error = '1' and result = x"01"
      report "expected NO_IMAGE after unmount" severity failure;

    report "tb_d64_drive passed";
    finish;
  end process;
end architecture;
