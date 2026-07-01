library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity sid_top is
  port (
    reset       : in  std_logic;
    clk         : in  std_logic;
    ce_1m       : in  std_logic;

    cs          : in  std_logic_vector(1 downto 0);
    we          : in  std_logic;
    addr        : in  unsigned(4 downto 0);
    data_in     : in  unsigned(7 downto 0);
    data_out    : out unsigned(7 downto 0);

    pot_x_l     : in  std_logic_vector(7 downto 0) := (others => '0');
    pot_y_l     : in  std_logic_vector(7 downto 0) := (others => '0');
    pot_x_r     : in  std_logic_vector(7 downto 0) := (others => '0');
    pot_y_r     : in  std_logic_vector(7 downto 0) := (others => '0');

    audio_l     : out std_logic_vector(17 downto 0);
    audio_r     : out std_logic_vector(17 downto 0);

    ext_in_l    : in  std_logic_vector(17 downto 0);
    ext_in_r    : in  std_logic_vector(17 downto 0);

    fc_offset_l : in  std_logic_vector(12 downto 0);
    fc_offset_r : in  std_logic_vector(12 downto 0);

    filter_en   : in  std_logic_vector(1 downto 0);
    mode        : in  std_logic_vector(1 downto 0);
    cfg         : in  std_logic_vector(3 downto 0);

    ld_clk      : in  std_logic;
    ld_addr     : in  std_logic_vector(11 downto 0);
    ld_data     : in  std_logic_vector(15 downto 0);
    ld_wr       : in  std_logic
  );
end entity;

architecture rtl of sid_top is
  signal sid_cs     : std_logic;
  signal sid_we     : std_logic;
  signal sid_dout   : data_t;
  signal sid_sample : std_logic_vector(15 downto 0);
  signal audio18    : signed(17 downto 0);
begin
  -- First Tang MiSTer build uses one native SID and mirrors it to both channels.
  -- The MiSTer wrapper keeps the dual-SID/config ports so a fuller replacement
  -- can be dropped in later without touching the C64 core integration again.
  sid_cs <= cs(0) or cs(1);
  sid_we <= we and sid_cs;

  sid_i : entity work.sid6581
    generic map (
      CLK_HZ => 32000000,
      SID_HZ => 985248
    )
    port map (
      clk        => clk,
      reset_n    => not reset,
      cs         => sid_cs,
      we         => sid_we,
      addr       => std_logic_vector(addr),
      din        => std_logic_vector(data_in),
      dout       => sid_dout,
      sample_out => sid_sample
    );

  data_out <= unsigned(sid_dout);
  audio18 <= resize(signed(sid_sample), audio18'length);
  audio_l <= std_logic_vector(audio18);
  audio_r <= std_logic_vector(audio18);
end architecture;
