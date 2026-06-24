-- Testbench for fat32_reader.
--
-- An SD stub serves the FAT32 card image produced by
-- tools/d64/make_fat32_card.py (sim/generated/fat32_card.img) over the raw
-- 512-byte read protocol.  The reader must resolve the .d64 file's start LBA
-- and verify the chain is contiguous.  The expected start LBA (2090) comes from
-- the Python builder's printed metadata for the default layout.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_fat32_reader is
  generic (
    -- override to point at a different card image (padded / superfloppy)
    IMG_PATH      : string  := "sim/generated/fat32_card.img";
    CARD_SECTORS  : integer := 2434;    -- image size / 512
    EXP_START_LBA : integer := 2090     -- expected .d64 start LBA on the card
  );
end entity;

architecture sim of tb_fat32_reader is
  constant CARD_BYTES   : integer := CARD_SECTORS * 512;
  constant EXP_SIZE     : integer := 174848;

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
           & " (run: python tools/d64/make_fat32_card.py -o " & path
           & " roms/test_d64/testdisk.d64)"
      severity failure;
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

  -- SD-stub read-request latch (so one-cycle strobes are never missed).
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

  -- Latch one-cycle sd_read pulses so the stub never misses a back-to-back
  -- request (the real sd_card_top latches the strobe internally).
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
        -- rd_taken clears rd_pending; drop it so we re-arm for the next request
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
  begin
    reset_n <= '0';
    wait for 40 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    -- wait for completion (ready or error)
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
           & " expected " & integer'image(EXP_START_LBA)
      severity failure;
    assert to_integer(unsigned(fsize)) = EXP_SIZE
      report "file size = " & integer'image(to_integer(unsigned(fsize)))
           & " expected " & integer'image(EXP_SIZE)
      severity failure;

    report "tb_fat32_reader passed";
    finish;
  end process;
end architecture;
