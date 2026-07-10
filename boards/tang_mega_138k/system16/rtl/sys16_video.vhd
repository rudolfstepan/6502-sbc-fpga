library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sys16_pkg.all;

entity sys16_video is
  port (
    clk_pix      : in  std_logic;
    reset_n      : in  std_logic;
    status_word  : in  word16_t;
    vga_de       : out std_logic;
    vga_hs       : out std_logic;
    vga_vs       : out std_logic;
    vga_r        : out std_logic_vector(4 downto 0);
    vga_g        : out std_logic_vector(5 downto 0);
    vga_b        : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of sys16_video is
  constant H_ACTIVE : natural := 640;
  constant H_FP     : natural := 16;
  constant H_SYNC   : natural := 96;
  constant H_BP     : natural := 48;
  constant H_TOTAL  : natural := H_ACTIVE + H_FP + H_SYNC + H_BP;

  constant V_ACTIVE : natural := 480;
  constant V_FP     : natural := 10;
  constant V_SYNC   : natural := 2;
  constant V_BP     : natural := 33;
  constant V_TOTAL  : natural := V_ACTIVE + V_FP + V_SYNC + V_BP;

  signal hcnt        : unsigned(9 downto 0) := (others => '0');
  signal vcnt        : unsigned(9 downto 0) := (others => '0');
  signal status_meta : word16_t := (others => '0');
  signal status_sync : word16_t := (others => '0');
  signal active      : std_logic;
  signal bar         : unsigned(2 downto 0);
  signal rgb565      : std_logic_vector(15 downto 0) := (others => '0');
begin
  active <= '1' when hcnt < to_unsigned(H_ACTIVE, hcnt'length) and
                     vcnt < to_unsigned(V_ACTIVE, vcnt'length) else '0';
  bar    <= hcnt(8 downto 6);

  process(clk_pix, reset_n)
  begin
    if reset_n = '0' then
      hcnt        <= (others => '0');
      vcnt        <= (others => '0');
      status_meta <= (others => '0');
      status_sync <= (others => '0');
      rgb565      <= (others => '0');
      vga_de      <= '0';
      vga_hs      <= '1';
      vga_vs      <= '1';
    elsif rising_edge(clk_pix) then
      status_meta <= status_word;
      status_sync <= status_meta;

      if hcnt = to_unsigned(H_TOTAL - 1, hcnt'length) then
        hcnt <= (others => '0');
        if vcnt = to_unsigned(V_TOTAL - 1, vcnt'length) then
          vcnt <= (others => '0');
        else
          vcnt <= vcnt + 1;
        end if;
      else
        hcnt <= hcnt + 1;
      end if;

      vga_de <= active;
      if hcnt >= to_unsigned(H_ACTIVE + H_FP, hcnt'length) and
         hcnt < to_unsigned(H_ACTIVE + H_FP + H_SYNC, hcnt'length) then
        vga_hs <= '0';
      else
        vga_hs <= '1';
      end if;

      if vcnt >= to_unsigned(V_ACTIVE + V_FP, vcnt'length) and
         vcnt < to_unsigned(V_ACTIVE + V_FP + V_SYNC, vcnt'length) then
        vga_vs <= '0';
      else
        vga_vs <= '1';
      end if;

      if active = '0' then
        rgb565 <= (others => '0');
      elsif vcnt < to_unsigned(32, vcnt'length) then
        rgb565 <= status_sync;
      else
        case bar is
          when "000" => rgb565 <= x"F800";
          when "001" => rgb565 <= x"FFE0";
          when "010" => rgb565 <= x"07E0";
          when "011" => rgb565 <= x"07FF";
          when "100" => rgb565 <= x"001F";
          when "101" => rgb565 <= x"F81F";
          when "110" => rgb565 <= x"FFFF";
          when others => rgb565 <= x"39E7";
        end case;
      end if;
    end if;
  end process;

  vga_r <= rgb565(15 downto 11);
  vga_g <= rgb565(10 downto 5);
  vga_b <= rgb565(4 downto 0);
end architecture;
