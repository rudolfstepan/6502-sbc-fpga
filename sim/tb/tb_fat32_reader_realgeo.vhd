-- Real-geometry test for fat32_reader.
--
-- The standard tb_fat32_reader loads the whole card image into an array, which
-- is fine for small images but not for a real card's geometry (reserved=2964,
-- spf=14902 -> data_start=32768 -> a 16 MB image).  This TB instead serves SD
-- sectors lazily from the file, so it can replay the exact geometry of the
-- Windows-formatted SD card that fails on hardware with RESULT=0B.
--
-- Build the image first:
--   python tools/d64/make_fat32_card.py -o sim/generated/fat32_card_realgeo.img \
--     --superfloppy --realistic-prefix --reserved 2964 --force-spf 14902 \
--     --spc 32 roms/test_d64/testdisk.d64
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_fat32_reader_realgeo is
  generic (
    IMG_PATH      : string  := "sim/generated/fat32_card_realgeo.img";
    EXP_START_LBA : integer := 32800     -- testdisk.d64 start LBA (real geo)
  );
end entity;

architecture sim of tb_fat32_reader_realgeo is
  constant EXP_SIZE : integer := 174848;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal start   : std_logic := '0';
  signal busy    : std_logic;
  signal ready   : std_logic;
  signal error   : std_logic;
  signal result  : std_logic_vector(7 downto 0);
  signal fstart  : std_logic_vector(31 downto 0);
  signal fsize   : std_logic_vector(31 downto 0);

  signal sd_read       : std_logic;
  signal sd_read_addr  : std_logic_vector(31 downto 0);
  signal sd_read_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_read_valid : std_logic := '0';
  signal sd_read_end   : std_logic := '0';

  signal rd_pending : std_logic := '0';
  signal rd_lba     : std_logic_vector(31 downto 0) := (others => '0');
  signal rd_taken   : std_logic := '0';
begin
  clk <= not clk after 5 ns;

  dut : entity work.fat32_reader
    port map (
      clk            => clk,
      reset_n        => reset_n,
      start          => start,
      busy           => busy,
      ready          => ready,
      error          => error,
      result         => result,
      file_start_lba => fstart,
      file_size      => fsize,
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

  -- Lazy SD stub: serve each requested 512-byte sector by reading it from the
  -- file.  Keeps the file open and skips forward; reopens on a backward seek.
  sd_stub : process
    type charfile is file of character;
    file f        : charfile;
    variable st   : file_open_status;
    variable c    : character;
    variable cur  : integer := 0;        -- next byte offset the file is at
    variable want : integer;
    variable lba  : integer;
  begin
    sd_read_valid <= '0';
    sd_read_end   <= '0';
    rd_taken      <= '0';
    file_open(st, f, IMG_PATH, read_mode);
    assert st = open_ok
      report "cannot open " & IMG_PATH
           & " (run the make_fat32_card.py command in the TB header)"
      severity failure;

    loop
      wait until rising_edge(clk);
      if rd_pending = '1' then
        rd_taken <= '1';
        lba  := to_integer(unsigned(rd_lba));
        want := lba * 512;
        -- reopen if we need to go backward
        if want < cur then
          file_close(f);
          file_open(st, f, IMG_PATH, read_mode);
          cur := 0;
        end if;
        -- skip forward to the requested sector
        while cur < want and not endfile(f) loop
          read(f, c);
          cur := cur + 1;
        end loop;
        wait until rising_edge(clk);
        rd_taken <= '0';
        for i in 0 to 511 loop
          wait until rising_edge(clk);
          if not endfile(f) then
            read(f, c);
            cur := cur + 1;
            sd_read_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
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
  begin
    reset_n <= '0';
    wait for 40 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until rising_edge(clk);
    while busy = '1' loop
      wait until rising_edge(clk);
    end loop;

    assert error = '0'
      report "fat32_reader reported error, result="
           & integer'image(to_integer(unsigned(result)))
      severity failure;
    assert ready = '1' report "fat32_reader not ready" severity failure;
    assert to_integer(unsigned(fstart)) = EXP_START_LBA
      report "start LBA = " & integer'image(to_integer(unsigned(fstart)))
           & " expected " & integer'image(EXP_START_LBA) severity failure;
    assert to_integer(unsigned(fsize)) = EXP_SIZE
      report "file size = " & integer'image(to_integer(unsigned(fsize)))
           & " expected " & integer'image(EXP_SIZE) severity failure;

    report "tb_fat32_reader_realgeo passed";
    finish;
  end process;
end architecture;
