-- Self-checking testbench for hdmi_encoder.
--
-- Drives CEA-861 720x480p timing (de/hs/vs/rgb) and verifies, over a settled
-- frame, that the encoder emits:
--   * exactly one AVI-InfoFrame data island whose 32 TERC4 words match the
--     precomputed hdmi_data_island_pkg ROM, wrapped in data guard bands,
--   * a 2-pixel video guard band immediately before every active line,
--   * no 'U'/'X' on any channel.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.hdmi_data_island_pkg.all;

entity tb_hdmi_encoder is
end entity;

architecture sim of tb_hdmi_encoder is
  constant H_TOT : integer := 858;
  constant V_TOT : integer := 525;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal de, hs, vs : std_logic;
  signal r8, g8, b8 : std_logic_vector(7 downto 0);
  signal ch0, ch1, ch2 : std_logic_vector(9 downto 0);

  signal hc : integer range 0 to H_TOT - 1 := 0;
  signal vc : integer range 0 to V_TOT - 1 := 0;
  signal frame : integer := 0;
  signal running : boolean := true;

  -- de/vc delayed by the encoder's 3-cycle latency so the checker inspects the
  -- output in step (periphery is in blanking; video must be excluded).
  signal de_d1, de_d2, de_d3 : std_logic := '0';
  signal vc_d1, vc_d2, vc_d3 : integer range 0 to V_TOT - 1 := 0;

  -- guard-band / control reference codes (mirror hdmi_encoder)
  constant VGB_02 : std_logic_vector(9 downto 0) := "1011001100";
  constant VGB_1  : std_logic_vector(9 downto 0) := "0100110011";
  constant DGB_12 : std_logic_vector(9 downto 0) := "0100110011";
  constant DGB0_11: std_logic_vector(9 downto 0) := "1011000011";  -- ch0, {vs,hs}=1,1
begin
  clk <= not clk after 5 ns when running else '0';
  reset_n <= '1' after 40 ns;

  -- CEA 720x480p timing generator (sync active-low)
  timing : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        hc <= 0; vc <= 0; frame <= 0;
      else
        if hc = H_TOT - 1 then
          hc <= 0;
          if vc = V_TOT - 1 then
            vc <= 0; frame <= frame + 1;
          else
            vc <= vc + 1;
          end if;
        else
          hc <= hc + 1;
        end if;
      end if;
    end if;
  end process;

  de <= '1' when hc < 720 and vc < 480 else '0';
  hs <= '0' when hc >= 736 and hc < 798 else '1';
  vs <= '0' when vc >= 489 and vc < 495 else '1';
  -- non-trivial pixel data so video codes differ from control codes
  r8 <= std_logic_vector(to_unsigned(hc mod 256, 8));
  g8 <= std_logic_vector(to_unsigned(vc mod 256, 8));
  b8 <= x"5A";

  dut : entity work.hdmi_encoder
    port map (clk => clk, reset_n => reset_n, de => de, hs => hs, vs => vs,
              r8 => r8, g8 => g8, b8 => b8,
              tmds_ch0 => ch0, tmds_ch1 => ch1, tmds_ch2 => ch2);

  -- Scan the settled output stream (frame index 2) for the expected structure.
  checker : process(clk)
    variable island_count : integer := 0;
    variable vguard_px     : integer := 0;
    variable state         : integer := 0;  -- 0=idle 1=in-island
    variable idx           : integer := 0;
    variable di_ok         : boolean := true;
  begin
    if rising_edge(clk) and reset_n = '1' then
      -- latency-aligned input shadows
      de_d1 <= de; de_d2 <= de_d1; de_d3 <= de_d2;
      vc_d1 <= vc; vc_d2 <= vc_d1; vc_d3 <= vc_d2;
      -- only inspect a fully settled frame, in blanking (exclude video pixels)
      if frame = 2 and de_d3 = '0' then
        -- no undefined levels
        assert not (is_x(ch0) or is_x(ch1) or is_x(ch2))
          report "tb_hdmi_encoder: X/U on TMDS output" severity failure;

        -- count video guard-band pixels
        if ch0 = VGB_02 and ch1 = VGB_1 and ch2 = VGB_02 then
          vguard_px := vguard_px + 1;
        end if;

        -- detect data-island body on its line only: a data guard band
        -- (ch1=ch2=DGB_12, ch0=DGB0_11) then 32 island words vs the ROM.
        if vc_d3 /= 482 then
          state := 0;
        elsif state = 0 then
          if ch1 = DGB_12 and ch2 = DGB_12 and ch0 = DGB0_11 then
            state := 1; idx := -1;  -- next data-guard pixel still part of leading GB
          end if;
        elsif state = 1 then
          if idx = -1 then
            idx := 0;  -- consume 2nd leading guard pixel
          elsif idx < 32 then
            if ch0 /= DI_CH0(idx) or ch1 /= DI_CH1(idx) or ch2 /= DI_CH2(idx) then
              di_ok := false;
            end if;
            idx := idx + 1;
          elsif idx = 32 or idx = 33 then
            -- the two trailing guard-band pixels (consume both so the second
            -- is not mistaken for a new leading guard)
            assert ch1 = DGB_12 and ch2 = DGB_12 and ch0 = DGB0_11
              report "tb_hdmi_encoder: missing trailing data guard band" severity failure;
            if idx = 33 then
              assert di_ok
                report "tb_hdmi_encoder: data island words != AVI ROM" severity failure;
              island_count := island_count + 1;
              state := 0;
            else
              idx := 33;
            end if;
          end if;
        end if;
      elsif frame = 3 then
        assert island_count = 1
          report "tb_hdmi_encoder: expected exactly 1 data island, got "
                 & integer'image(island_count) severity failure;
        -- ~480 lines * 2 px; allow +/-2 px slack at the frame boundary (latency).
        assert vguard_px >= 956 and vguard_px <= 960
          report "tb_hdmi_encoder: video guard pixels = "
                 & integer'image(vguard_px) & " (expected ~960)" severity failure;
        report "tb_hdmi_encoder passed" severity note;
        running <= false;
      end if;
    end if;
  end process;
end architecture;
