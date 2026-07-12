-- HDMI framebuffer "graphics card" for the GoRV32 Plus shell.
--
-- 640x360 RGB565 in BSRAM, scanned out pixel- and line-doubled to the
-- proven 1280x720@60 timing of sys16_hdmi_720p. The CPU reaches it
-- through the IP's AXI slave window at 0xE8000000 via a second
-- sys16_axi32_to_bus32 instance; this module is the bus32 device.
--
-- Window layout (addr = byte offset inside the window):
--   $000000-$0707FF  pixel data, linear, stride 1280 bytes,
--                    pixel pair per 32-bit word (even pixel in [15:0])
--   $800000          ID "S16F" (read only)
--   $800004          CTRL: bit0 enable, bit1 test pattern,
--                          bit2 diagnostic stripe overlay (all reset 1)
--   $800008          STATUS: bit0 vblank, [31:16] frame counter
--
-- The dual-port, dual-clock BSRAM banks are the CDC boundary; CTRL
-- crosses into the pixel domain through a two-stage synchronizer,
-- vblank crosses back the same way.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_hdmi_fb is
  port (
    clk_in      : in  std_logic;  -- 50 MHz bus clock
    reset_n     : in  std_logic;
    -- bus32 device port, driven by sys16_axi32_to_bus32
    req         : in  std_logic;
    we          : in  std_logic;
    addr        : in  std_logic_vector(23 downto 0);
    be          : in  std_logic_vector(3 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    rdata       : out std_logic_vector(31 downto 0);
    ready       : out std_logic;
    -- diagnostic stripe color (top 48 lines when CTRL bit2 is set)
    status_word : in  std_logic_vector(15 downto 0);
    pll_lock    : out std_logic;
    tmds_clk_p  : out std_logic;
    tmds_clk_n  : out std_logic;
    tmds_d_p    : out std_logic_vector(2 downto 0);
    tmds_d_n    : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of sys16_hdmi_fb is
  component Gowin_HDMI_720P_PLL is
    port (
      lock    : out std_logic;
      clkout0 : out std_logic;
      clkout1 : out std_logic;
      clkin   : in  std_logic
    );
  end component;

  component dvi_tx_top is
    port (
      pixel_clock   : in  std_logic;
      ddr_bit_clock : in  std_logic;
      reset         : in  std_logic;
      den           : in  std_logic;
      hsync         : in  std_logic;
      vsync         : in  std_logic;
      pixel_data    : in  std_logic_vector(23 downto 0);
      tmds_clk      : out std_logic_vector(1 downto 0);
      tmds_d0       : out std_logic_vector(1 downto 0);
      tmds_d1       : out std_logic_vector(1 downto 0);
      tmds_d2       : out std_logic_vector(1 downto 0)
    );
  end component;

  constant H_ACTIVE : natural := 1280;
  constant H_FP     : natural := 110;
  constant H_SYNC   : natural := 40;
  constant H_BP     : natural := 220;
  constant H_TOTAL  : natural := H_ACTIVE + H_FP + H_SYNC + H_BP;
  constant V_ACTIVE : natural := 720;
  constant V_FP     : natural := 5;
  constant V_SYNC   : natural := 5;
  constant V_BP     : natural := 20;
  constant V_TOTAL  : natural := V_ACTIVE + V_FP + V_SYNC + V_BP;

  constant FB_WORDS : natural := 115200; -- 640*360*2 bytes / 4
  constant FB_AW    : natural := 17;

  -- pixel clock domain
  signal lock_i        : std_logic;
  signal clk_pix       : std_logic;
  signal clk_5x        : std_logic;
  signal reset_sr      : std_logic_vector(7 downto 0) := (others => '0');
  signal reset_video   : std_logic;
  signal x             : unsigned(10 downto 0) := (others => '0');
  signal y             : unsigned(9 downto 0) := (others => '0');
  signal active        : std_logic;
  signal hsync         : std_logic;
  signal vsync         : std_logic;
  signal status_meta   : std_logic_vector(15 downto 0) := (others => '0');
  signal status_sync   : std_logic_vector(15 downto 0) := (others => '0');
  signal ctrl_meta     : std_logic_vector(2 downto 0) := (others => '0');
  signal ctrl_sync     : std_logic_vector(2 downto 0) := (others => '0');
  signal addrb_r       : std_logic_vector(FB_AW-1 downto 0) := (others => '0');
  signal half_d1       : std_logic := '0';
  signal half_d2       : std_logic := '0';
  signal half_d3       : std_logic := '0';
  signal half_d4       : std_logic := '0';
  signal fb_qb         : std_logic_vector(31 downto 0);
  signal fb_qb_r       : std_logic_vector(31 downto 0) := (others => '0');
  signal pixel_data    : std_logic_vector(23 downto 0);
  signal vblank_pix    : std_logic;
  signal tmds_clk_pair : std_logic_vector(1 downto 0);
  signal tmds_d0_pair  : std_logic_vector(1 downto 0);
  signal tmds_d1_pair  : std_logic_vector(1 downto 0);
  signal tmds_d2_pair  : std_logic_vector(1 downto 0);

  -- bus clock domain
  type bus_state_t is (B_IDLE, B_RDWAIT, B_RDWAIT2, B_RESP);
  signal bus_state  : bus_state_t := B_IDLE;
  signal rdata_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal ctrl_reg   : std_logic_vector(2 downto 0) := "111";
  signal frame_cnt  : unsigned(15 downto 0) := (others => '0');
  signal vblank_m   : std_logic := '0';
  signal vblank_s   : std_logic := '0';
  signal vblank_p   : std_logic := '0';
  signal fb_qa      : std_logic_vector(31 downto 0);
  signal fb_wea     : std_logic_vector(3 downto 0);
  signal sel_regs   : std_logic;
  signal word_idx   : std_logic_vector(FB_AW-1 downto 0);
begin
  pll_lock    <= lock_i;
  reset_video <= not reset_sr(7);
  sel_regs    <= addr(23);
  word_idx    <= addr(18 downto 2);
  rdata       <= rdata_r;
  ready       <= '1' when bus_state = B_RESP else '0';

  pll_i : Gowin_HDMI_720P_PLL
    port map (
      lock    => lock_i,
      clkout0 => clk_pix,
      clkout1 => clk_5x,
      clkin   => clk_in
    );

  -- Framebuffer storage: one 8-bit dual-clock bank per byte lane.
  banks : for i in 0 to 3 generate
    bank_i : entity work.sys16_fb_ram8
      generic map (DEPTH => FB_WORDS, AW => FB_AW)
      port map (
        clka  => clk_in,
        wea   => fb_wea(i),
        addra => word_idx,
        dina  => wdata(8*i+7 downto 8*i),
        qa    => fb_qa(8*i+7 downto 8*i),
        clkb  => clk_pix,
        addrb => addrb_r,
        qb    => fb_qb(8*i+7 downto 8*i)
      );
  end generate;

  -- Single-cycle write strobes while the transaction leaves B_IDLE.
  wea_g : for i in 0 to 3 generate
    fb_wea(i) <= '1' when bus_state = B_IDLE and req = '1' and we = '1'
                          and sel_regs = '0' and be(i) = '1' else '0';
  end generate;

  -- Bus device FSM: same req/ready contract as sys16_sdram_bridge
  -- (ready held until the bridge drops req).
  bus_p : process(clk_in)
  begin
    if rising_edge(clk_in) then
      if reset_n = '0' then
        bus_state <= B_IDLE;
        ctrl_reg  <= "111";
        frame_cnt <= (others => '0');
        vblank_m  <= '0';
        vblank_s  <= '0';
        vblank_p  <= '0';
      else
        vblank_m <= vblank_pix;
        vblank_s <= vblank_m;
        vblank_p <= vblank_s;
        if vblank_s = '1' and vblank_p = '0' then
          frame_cnt <= frame_cnt + 1;
        end if;

        case bus_state is
          when B_IDLE =>
            if req = '1' then
              if we = '1' then
                if sel_regs = '1' and addr(3 downto 2) = "01"
                   and be(0) = '1' then
                  ctrl_reg <= wdata(2 downto 0);
                end if;
                bus_state <= B_RESP;
              else
                bus_state <= B_RDWAIT;
              end if;
            end if;

          when B_RDWAIT =>
            -- The banks register their address input; RAM data needs a
            -- second cycle. Register reads only need one, but the extra
            -- wait is harmless there.
            bus_state <= B_RDWAIT2;

          when B_RDWAIT2 =>
            if sel_regs = '1' then
              case addr(3 downto 2) is
                when "00" =>
                  rdata_r <= x"53313646"; -- "S16F"
                when "01" =>
                  rdata_r <= x"0000000" & '0' & ctrl_reg;
                when others =>
                  rdata_r <= std_logic_vector(frame_cnt) &
                             "000000000000000" & vblank_s;
              end case;
            else
              rdata_r <= fb_qa;
            end if;
            bus_state <= B_RESP;

          when B_RESP =>
            if req = '0' then
              bus_state <= B_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- Pixel-domain reset and video timing, identical to sys16_hdmi_720p.
  process(clk_pix, lock_i, reset_n)
  begin
    if lock_i = '0' or reset_n = '0' then
      reset_sr <= (others => '0');
    elsif rising_edge(clk_pix) then
      reset_sr <= reset_sr(6 downto 0) & '1';
    end if;
  end process;

  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if reset_video = '1' then
        x           <= (others => '0');
        y           <= (others => '0');
        status_meta <= (others => '0');
        status_sync <= (others => '0');
        ctrl_meta   <= (others => '0');
        ctrl_sync   <= (others => '0');
      else
        status_meta <= status_word;
        status_sync <= status_meta;
        ctrl_meta   <= ctrl_reg;
        ctrl_sync   <= ctrl_meta;

        if x = to_unsigned(H_TOTAL - 1, x'length) then
          x <= (others => '0');
          if y = to_unsigned(V_TOTAL - 1, y'length) then
            y <= (others => '0');
          else
            y <= y + 1;
          end if;
        else
          x <= x + 1;
        end if;
      end if;
    end if;
  end process;

  active <= '1' when x < to_unsigned(H_ACTIVE, x'length) and
                     y < to_unsigned(V_ACTIVE, y'length) else '0';
  hsync <= '1' when x >= to_unsigned(H_ACTIVE + H_FP, x'length) and
                    x < to_unsigned(H_ACTIVE + H_FP + H_SYNC, x'length) else '0';
  vsync <= '1' when y >= to_unsigned(V_ACTIVE + V_FP, y'length) and
                    y < to_unsigned(V_ACTIVE + V_FP + V_SYNC, y'length) else '0';
  vblank_pix <= '1' when y >= to_unsigned(V_ACTIVE, y'length) else '0';

  -- Scanout fetch, four pixels ahead of the beam: address register here,
  -- address register inside each bank, the BSRAM output register and the
  -- fb_qb_r stage line the data up exactly with x. The word address is
  -- (ny/2)*320 + nx/4, built from shifts (no multiplier); line doubling
  -- falls out of ny/2, pixel doubling out of nx/4.
  fetch_p : process(clk_pix)
    variable nx   : unsigned(10 downto 0);
    variable ny   : unsigned(9 downto 0);
    variable fby  : unsigned(8 downto 0);
    variable wadr : unsigned(FB_AW-1 downto 0);
  begin
    if rising_edge(clk_pix) then
      if reset_video = '1' then
        addrb_r <= (others => '0');
        half_d1 <= '0';
        half_d2 <= '0';
        half_d3 <= '0';
        half_d4 <= '0';
        fb_qb_r <= (others => '0');
      else
        if x < to_unsigned(H_TOTAL - 4, x'length) then
          nx := x + 4;
          ny := y;
        else
          nx := x + 4 - to_unsigned(H_TOTAL, x'length);
          if y = to_unsigned(V_TOTAL - 1, y'length) then
            ny := (others => '0');
          else
            ny := y + 1;
          end if;
        end if;
        fby  := ny(9 downto 1);
        wadr := shift_left(resize(fby, FB_AW), 8) +
                shift_left(resize(fby, FB_AW), 6) +
                resize(nx(10 downto 2), FB_AW);
        addrb_r <= std_logic_vector(wadr);
        fb_qb_r <= fb_qb;
        half_d1 <= nx(1);
        half_d2 <= half_d1;
        half_d3 <= half_d2;
        half_d4 <= half_d3;
      end if;
    end if;
  end process;

  -- Output mux: blanking, diagnostic stripe overlay, enable gate, test
  -- pattern, framebuffer pixel (RGB565 expanded to RGB888).
  paint_p : process(x, y, active, status_sync, ctrl_sync, half_d4, fb_qb_r)
    variable status_rgb : std_logic_vector(23 downto 0);
    variable pix16      : std_logic_vector(15 downto 0);
    variable test_rgb   : std_logic_vector(23 downto 0);
  begin
    status_rgb := status_sync(15 downto 11) & status_sync(15 downto 13) &
                  status_sync(10 downto 5) & status_sync(10 downto 9) &
                  status_sync(4 downto 0) & status_sync(4 downto 2);

    test_rgb := std_logic_vector(x(8 downto 4)) &
                std_logic_vector(x(8 downto 6)) &
                std_logic_vector(y(8 downto 3)) &
                std_logic_vector(y(8 downto 7)) &
                (x(5) xor y(5)) & "0000000";

    if half_d4 = '1' then
      pix16 := fb_qb_r(31 downto 16);
    else
      pix16 := fb_qb_r(15 downto 0);
    end if;

    if active = '0' then
      pixel_data <= x"000000";
    elsif ctrl_sync(2) = '1' and y < to_unsigned(48, y'length) then
      pixel_data <= status_rgb;
    elsif ctrl_sync(0) = '0' then
      pixel_data <= x"000000";
    elsif ctrl_sync(1) = '1' then
      pixel_data <= test_rgb;
    else
      pixel_data <= pix16(15 downto 11) & pix16(15 downto 13) &
                    pix16(10 downto 5)  & pix16(10 downto 9)  &
                    pix16(4 downto 0)   & pix16(4 downto 2);
    end if;
  end process;

  dvi_i : dvi_tx_top
    port map (
      pixel_clock   => clk_pix,
      ddr_bit_clock => clk_5x,
      reset         => reset_video,
      den           => active,
      hsync         => hsync,
      vsync         => vsync,
      pixel_data    => pixel_data,
      tmds_clk      => tmds_clk_pair,
      tmds_d0       => tmds_d0_pair,
      tmds_d1       => tmds_d1_pair,
      tmds_d2       => tmds_d2_pair
    );

  tmds_clk_p  <= tmds_clk_pair(1);
  tmds_clk_n  <= tmds_clk_pair(0);
  tmds_d_p(0) <= tmds_d0_pair(1);
  tmds_d_n(0) <= tmds_d0_pair(0);
  tmds_d_p(1) <= tmds_d1_pair(1);
  tmds_d_n(1) <= tmds_d1_pair(0);
  tmds_d_p(2) <= tmds_d2_pair(1);
  tmds_d_n(2) <= tmds_d2_pair(0);
end architecture;
