-- HDMI (not bare DVI) TMDS word generator.
--
-- Takes VGA-style de/hs/vs + 8-bit RGB and produces the three 10-bit TMDS
-- words per pixel, inserting the HDMI periphery a sink needs to treat the
-- stream as HDMI rather than DVI:
--   * a video preamble (8 px) + video guard band (2 px) before every active line
--   * one Data Island per frame carrying the AVI InfoFrame (preamble + guard +
--     32 TERC4 packet pixels + guard), placed in vertical blanking
--   * normal control periods everywhere else
--
-- Why: many USB HDMI capture devices stay black on a pure-DVI signal (no AVI
-- InfoFrame) even though monitors accept it. The InfoFrame announces the video
-- format (VIC) and flips the sink into HDMI mode.
--
-- The AVI InfoFrame is static, so its 32-pixel TERC4 packet is precomputed
-- offline (tools/gen_avi_infoframe.py -> hdmi_data_island_pkg) including BCH ECC
-- and checksum. This module only sequences fixed words; no runtime ECC/TERC4.
--
-- Pipeline: 3 pixel-clock cycles of latency, identical on all three channels.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.hdmi_data_island_pkg.all;

entity hdmi_encoder is
  generic (
    -- CEA-861 720x480p totals (Tang Primer 20K). cx is 0 at the first active
    -- pixel of a line; cy is 0 at the first active line.
    H_TOT    : natural := 858;
    V_TOT    : natural := 525;
    H_ACT    : natural := 720;
    V_ACT    : natural := 480;
    V_SYNC   : natural := 489;   -- first line of the vertical sync pulse
    -- Data island: a vertical-blank line, in the horizontal-blank region that
    -- precedes the (negative) HSYNC pulse, so sync wire levels are idle (1).
    DI_LINE  : natural := 482;
    DI_START : natural := 10     -- cx of the data-island preamble's first pixel
  );
  port (
    clk      : in  std_logic;    -- pixel clock (27 MHz)
    reset_n  : in  std_logic;
    de       : in  std_logic;    -- data enable (active video)
    hs       : in  std_logic;    -- HSYNC wire level (active low, as from VIC)
    vs       : in  std_logic;    -- VSYNC wire level (active low)
    r8       : in  std_logic_vector(7 downto 0);
    g8       : in  std_logic_vector(7 downto 0);
    b8       : in  std_logic_vector(7 downto 0);
    tmds_ch0 : out std_logic_vector(9 downto 0);  -- blue  (carries sync)
    tmds_ch1 : out std_logic_vector(9 downto 0);  -- green
    tmds_ch2 : out std_logic_vector(9 downto 0)   -- red
  );
end entity;

architecture rtl of hdmi_encoder is
  subtype slv10 is std_logic_vector(9 downto 0);

  -- TMDS control-period symbols (DVI 1.0 / tmds_encoder).
  constant CTRL_00 : slv10 := "1101010100";
  constant CTRL_01 : slv10 := "0010101011";
  constant CTRL_10 : slv10 := "0101010100";
  constant CTRL_11 : slv10 := "1010101011";
  -- Video guard band: channels 0 & 2 vs channel 1.
  constant VGB_02  : slv10 := "1011001100";
  constant VGB_1   : slv10 := "0100110011";
  -- Data-island guard band: channels 1 & 2 are fixed, channel 0 depends on
  -- the {vsync,hsync} wire levels during the guard band.
  constant DGB_12  : slv10 := "0100110011";

  -- Channel-0 control symbol selected by the {vsync,hsync} wire levels.
  function ctrl_code(vsl, hsl : std_logic) return slv10 is
  begin
    if    vsl = '0' and hsl = '0' then return CTRL_00;
    elsif vsl = '0' and hsl = '1' then return CTRL_01;
    elsif vsl = '1' and hsl = '0' then return CTRL_10;
    else                               return CTRL_11;
    end if;
  end function;

  -- Channel-0 data-island guard band, selected by {vsync,hsync}.
  function dgb0(vsl, hsl : std_logic) return slv10 is
  begin
    if    vsl = '0' and hsl = '0' then return "1010001110";
    elsif vsl = '0' and hsl = '1' then return "1001110001";
    elsif vsl = '1' and hsl = '0' then return "0101100011";
    else                               return "1011000011";
    end if;
  end function;

  -- Stage A: registered inputs, aligned to the cx/cy position counters.
  signal de_a, hs_a, vs_a : std_logic := '0';
  signal r_a, g_a, b_a    : std_logic_vector(7 downto 0) := (others => '0');
  signal de_prev          : std_logic := '0';
  signal vs_a_prev        : std_logic := '1';
  signal cx               : integer range 0 to H_TOT - 1 := 0;
  signal cy               : integer range 0 to V_TOT - 1 := 0;

  -- Video TMDS words (from the reused DVI encoder), 1 cycle behind stage A.
  signal vid0, vid1, vid2 : slv10;

  -- Stage-A blanking codes and the video-select flag, plus their stage-B copies
  -- (delayed one cycle to line up with the video encoder's latency).
  signal aux0, aux1, aux2 : slv10 := CTRL_00;
  signal aux0_b, aux1_b, aux2_b : slv10 := CTRL_00;
  signal de_sel           : std_logic := '0';
begin
  ------------------------------------------------------------------------------
  -- Position counters + input pipeline (stage A)
  ------------------------------------------------------------------------------
  pos : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        de_a <= '0'; hs_a <= '1'; vs_a <= '1';
        r_a <= (others => '0'); g_a <= (others => '0'); b_a <= (others => '0');
        de_prev <= '0'; vs_a_prev <= '1';
        cx <= 0; cy <= 0;
      else
        de_prev <= de;
        de_a <= de; hs_a <= hs; vs_a <= vs;
        r_a <= r8; g_a <= g8; b_a <= b8;
        vs_a_prev <= vs_a;

        -- cx == 0 on the first active pixel. The VIC line length equals H_TOT,
        -- so the free-running wrap and the de edge coincide; re-anchoring on de
        -- keeps the count locked after reset / any hiccup.
        if de = '1' and de_prev = '0' then
          cx <= 0;
        elsif cx = H_TOT - 1 then
          cx <= 0;
        else
          cx <= cx + 1;
        end if;

        -- cy counts lines, re-anchored each frame at the start of VSYNC.
        if vs_a = '0' and vs_a_prev = '1' then
          cy <= V_SYNC;
        elsif cx = H_TOT - 1 then
          if cy = V_TOT - 1 then cy <= 0; else cy <= cy + 1; end if;
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Video pixel encoders (reused DVI 8b/10b encoder). Fed the stage-A pixel so
  -- their 1-cycle output lands together with the registered aux codes.
  ------------------------------------------------------------------------------
  enc2 : entity work.tmds_encoder
    port map (clk => clk, reset_n => reset_n, de => de_a, d => r_a,
              c0 => '0', c1 => '0', q => vid2);
  enc1 : entity work.tmds_encoder
    port map (clk => clk, reset_n => reset_n, de => de_a, d => g_a,
              c0 => '0', c1 => '0', q => vid1);
  enc0 : entity work.tmds_encoder
    port map (clk => clk, reset_n => reset_n, de => de_a, d => b_a,
              c0 => hs_a, c1 => vs_a, q => vid0);

  ------------------------------------------------------------------------------
  -- Blanking-period code selection (combinational, stage A timeline).
  -- Only used when de_a = '0'; during active video the video encoder wins.
  ------------------------------------------------------------------------------
  blank : process(cx, cy, hs_a, vs_a)
    variable next_line_active : boolean;
    variable v_pre, v_guard   : boolean;
    variable di_pre, di_guard, di_period : boolean;
    variable idx              : integer range 0 to 31;
  begin
    next_line_active := (cy < V_ACT - 1) or (cy = V_TOT - 1);
    v_pre   := next_line_active and cx >= H_TOT - 10 and cx < H_TOT - 2;
    v_guard := next_line_active and cx >= H_TOT - 2;

    di_pre    := (cy = DI_LINE) and cx >= DI_START      and cx < DI_START + 8;
    di_guard  := (cy = DI_LINE) and
                 ((cx >= DI_START + 8  and cx < DI_START + 10) or   -- leading
                  (cx >= DI_START + 42 and cx < DI_START + 44));    -- trailing
    di_period := (cy = DI_LINE) and cx >= DI_START + 10 and cx < DI_START + 42;

    if cx >= DI_START + 10 and cx <= DI_START + 41 then
      idx := cx - (DI_START + 10);
    else
      idx := 0;
    end if;

    -- defaults: normal control period
    aux0 <= ctrl_code(vs_a, hs_a);
    aux1 <= CTRL_00;
    aux2 <= CTRL_00;

    if di_period then
      aux0 <= DI_CH0(idx); aux1 <= DI_CH1(idx); aux2 <= DI_CH2(idx);
    elsif di_guard then
      aux0 <= dgb0(vs_a, hs_a); aux1 <= DGB_12; aux2 <= DGB_12;
    elsif di_pre then
      -- data-island preamble: CTL0=1, CTL2=1
      aux0 <= ctrl_code(vs_a, hs_a); aux1 <= CTRL_01; aux2 <= CTRL_01;
    elsif v_guard then
      aux0 <= VGB_02; aux1 <= VGB_1; aux2 <= VGB_02;
    elsif v_pre then
      -- video preamble: CTL0=1
      aux0 <= ctrl_code(vs_a, hs_a); aux1 <= CTRL_01; aux2 <= CTRL_00;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Stage B: register aux + select to match the video encoder latency, then
  -- the final mux registers the output (stage C). 3-cycle total latency.
  ------------------------------------------------------------------------------
  outp : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        aux0_b <= CTRL_00; aux1_b <= CTRL_00; aux2_b <= CTRL_00;
        de_sel <= '0';
        tmds_ch0 <= CTRL_00; tmds_ch1 <= CTRL_00; tmds_ch2 <= CTRL_00;
      else
        aux0_b <= aux0; aux1_b <= aux1; aux2_b <= aux2;
        de_sel <= de_a;
        if de_sel = '1' then
          tmds_ch0 <= vid0; tmds_ch1 <= vid1; tmds_ch2 <= vid2;
        else
          tmds_ch0 <= aux0_b; tmds_ch1 <= aux1_b; tmds_ch2 <= aux2_b;
        end if;
      end if;
    end if;
  end process;
end architecture;
