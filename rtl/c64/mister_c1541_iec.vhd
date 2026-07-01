library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mister_c1541_iec is
  generic (
    CLK_HZ       : integer := 27000000;
    DRIVE_CPU_HZ : integer := 1000000
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    iec_atn_n  : in  std_logic;
    iec_clk_n  : in  std_logic;
    iec_data_n : in  std_logic;

    drive_clk_pull_n  : out std_logic;
    drive_data_pull_n : out std_logic;

    led : out std_logic
  );
end entity;

architecture rtl of mister_c1541_iec is
  constant PHI2_DIV : integer := CLK_HZ / DRIVE_CPU_HZ;
  constant PHI2_HALF : integer := PHI2_DIV / 2;

  signal div_cnt : integer range 0 to PHI2_DIV - 1 := 0;
  signal ph2_r   : std_logic := '0';
  signal ph2_f   : std_logic := '0';

  signal rom_addr : std_logic_vector(14 downto 0);
  signal rom_data : std_logic_vector(7 downto 0);
  signal dout     : std_logic_vector(7 downto 0);
  signal din      : std_logic_vector(7 downto 0);
  signal mode     : std_logic;
  signal stp      : std_logic_vector(1 downto 0);
  signal stp_old  : std_logic_vector(1 downto 0) := "00";
  signal track_num : unsigned(6 downto 0) := to_unsigned(34, 7);
  signal gcr_sync_n : std_logic := '1';
  signal gcr_byte_n : std_logic := '1';
  signal gcr_we     : std_logic;
  signal gcr_ce     : std_logic := '0';
  signal mtr      : std_logic;
  signal freq     : std_logic_vector(1 downto 0);
  signal drive_reset : std_logic;
  signal raw_drive_clk_pull_n  : std_logic := '1';
  signal raw_drive_data_pull_n : std_logic := '1';
  signal iec_atn_sync  : std_logic_vector(2 downto 0) := (others => '1');
  signal iec_clk_sync  : std_logic_vector(2 downto 0) := (others => '1');
  signal iec_data_sync : std_logic_vector(2 downto 0) := (others => '1');
  signal iec_atn_s     : std_logic := '1';
  signal iec_clk_s     : std_logic := '1';
  signal iec_data_s    : std_logic := '1';

  component c1541_logic
    port (
      clk          : in  std_logic;
      reset        : in  std_logic;
      ce           : in  std_logic;
      ph2_r        : in  std_logic;
      ph2_f        : in  std_logic;
      iec_clk_in   : in  std_logic;
      iec_data_in  : in  std_logic;
      iec_atn_in   : in  std_logic;
      iec_clk_out  : out std_logic;
      iec_data_out : out std_logic;
      ext_en       : in  std_logic;
      rom_addr     : out std_logic_vector(14 downto 0);
      rom_data     : in  std_logic_vector(7 downto 0);
      par_data_in  : in  std_logic_vector(7 downto 0);
      par_stb_in   : in  std_logic;
      par_data_out : out std_logic_vector(7 downto 0);
      par_stb_out  : out std_logic;
      ds           : in  std_logic_vector(1 downto 0);
      din          : in  std_logic_vector(7 downto 0);
      dout         : out std_logic_vector(7 downto 0);
      mode         : out std_logic;
      stp          : out std_logic_vector(1 downto 0);
      mtr          : out std_logic;
      freq         : out std_logic_vector(1 downto 0);
      sync_n       : in  std_logic;
      byte_n       : in  std_logic;
      wps_n        : in  std_logic;
      tr00_sense_n : in  std_logic;
      act          : out std_logic
    );
  end component;

  component c1541_static_dir_gcr
    port (
      clk    : in  std_logic;
      ce     : in  std_logic;
      reset  : in  std_logic;
      dout   : out std_logic_vector(7 downto 0);
      din    : in  std_logic_vector(7 downto 0);
      mode   : in  std_logic;
      mtr    : in  std_logic;
      freq   : in  std_logic_vector(1 downto 0);
      sync_n : out std_logic;
      byte_n : out std_logic;
      track  : in  std_logic_vector(6 downto 0);
      we     : out std_logic
    );
  end component;
begin
  drive_reset <= not reset_n;
  drive_clk_pull_n  <= '1' when drive_reset = '1' else raw_drive_clk_pull_n;
  drive_data_pull_n <= '1' when drive_reset = '1' else raw_drive_data_pull_n;

  process(clk)
    variable move : unsigned(1 downto 0);
  begin
    if rising_edge(clk) then
      ph2_r <= '0';
      ph2_f <= '0';

      if reset_n = '0' then
        div_cnt <= 0;
        gcr_ce <= '0';
        stp_old <= "00";
        track_num <= to_unsigned(34, track_num'length);
        iec_atn_sync  <= (others => '1');
        iec_clk_sync  <= (others => '1');
        iec_data_sync <= (others => '1');
        iec_atn_s     <= '1';
        iec_clk_s     <= '1';
        iec_data_s    <= '1';
      elsif div_cnt = PHI2_DIV - 1 then
        div_cnt <= 0;
        ph2_r <= '1';
      else
        div_cnt <= div_cnt + 1;
        gcr_ce <= not gcr_ce;
        if div_cnt = PHI2_HALF - 1 then
          ph2_f <= '1';
        end if;
      end if;

      if reset_n = '1' then
        stp_old <= stp;
        if mtr = '1' and stp(0) /= stp_old(0) then
          move := unsigned(stp) - unsigned(stp_old);
          if move(1) = '0' then
            if track_num < to_unsigned(84, track_num'length) then
              track_num <= track_num + 1;
            end if;
          else
            if track_num > 0 then
              track_num <= track_num - 1;
            end if;
          end if;
        end if;

        iec_atn_sync  <= iec_atn_sync(1 downto 0) & iec_atn_n;
        iec_clk_sync  <= iec_clk_sync(1 downto 0) & iec_clk_n;
        iec_data_sync <= iec_data_sync(1 downto 0) & iec_data_n;

        if iec_atn_sync(2) = iec_atn_sync(1) then
          iec_atn_s <= iec_atn_sync(2);
        end if;
        if iec_clk_sync(2) = iec_clk_sync(1) then
          iec_clk_s <= iec_clk_sync(2);
        end if;
        if iec_data_sync(2) = iec_data_sync(1) then
          iec_data_s <= iec_data_sync(2);
        end if;
      end if;
    end if;
  end process;

  rom_i : entity work.c1541_rom
    port map (
      clk  => clk,
      addr => rom_addr(13 downto 0),
      dout => rom_data
    );

  drive_i : c1541_logic
    port map (
      clk          => clk,
      reset        => drive_reset,
      ce           => '1',
      ph2_r        => ph2_r,
      ph2_f        => ph2_f,
      iec_clk_in   => iec_clk_s and raw_drive_clk_pull_n,
      iec_data_in  => iec_data_s and raw_drive_data_pull_n,
      iec_atn_in   => iec_atn_s,
      iec_clk_out  => raw_drive_clk_pull_n,
      iec_data_out => raw_drive_data_pull_n,
      ext_en       => '0',
      rom_addr     => rom_addr,
      rom_data     => rom_data,
      par_data_in  => x"FF",
      par_stb_in   => '1',
      par_data_out => open,
      par_stb_out  => open,
      ds           => "00",
      din          => din,
      dout         => dout,
      mode         => mode,
      stp          => stp,
      mtr          => mtr,
      freq         => freq,
      sync_n       => gcr_sync_n,
      byte_n       => gcr_byte_n,
      wps_n        => '1',
      tr00_sense_n => '1' when track_num /= 0 else '0',
      act          => led
    );

  gcr_i : c1541_static_dir_gcr
    port map (
      clk    => clk,
      ce     => gcr_ce,
      reset  => drive_reset,
      dout   => din,
      din    => dout,
      mode   => mode,
      mtr    => mtr,
      freq   => freq,
      sync_n => gcr_sync_n,
      byte_n => gcr_byte_n,
      track  => std_logic_vector(track_num),
      we     => gcr_we
    );
end architecture;
