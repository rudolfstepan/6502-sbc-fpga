-- HDMI framebuffer "graphics card" for the GoRV32 Plus shell.
--
-- 480x270 RGB565, scanned out pixel- and line-doubled to a centred
-- 960x540 window in the proven 1280x720@60 timing. The CPU reaches it
-- through the IP's AXI slave window at 0xE8000000 via a second
-- sys16_axi32_to_bus32 instance; this module is the bus32 device.
--
-- Window layout (addr = byte offset inside the window):
--   $000000-$03F47F  pixel data, linear, stride 960 bytes,
--                    pixel pair per 32-bit word (even pixel in [15:0])
--   $800000          ID "S16F" (read only)
--   $800004          CTRL: bit0 enable, bit1 test pattern,
--                          bit2 diagnostic stripe overlay (all reset 1)
--   $800008          STATUS: bit0 vblank, [31:16] frame counter
--
-- The dual-port, dual-clock BSRAM banks are the CDC boundary; CTRL
-- crosses into the pixel domain through a two-stage synchronizer,
-- vblank crosses back the same way.
--
-- Storage backends (generic FB_DDR3):
--   false: four sys16_fb_ram8 BSRAM byte banks (the bring-up backend)
--   true:  sys16_fb_ddr3 -- pixel data in the on-board DDR3, on-chip
--          only a double line buffer. Register map, bus FSM contract
--          and the scanout pipeline alignment are identical; the top
--          feeds the Gowin DDR3 IP app interface through the app_*
--          ports. STATUS bit1 reports the DDR3 calibration (constant
--          '1' on the BSRAM backend).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_hdmi_fb is
  generic (
    FB_DDR3 : boolean := true
  );
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
    tmds_d_n    : out std_logic_vector(2 downto 0);
    -- DDR3 backend only (FB_DDR3 = true): Gowin DDR3 IP app interface,
    -- 128-bit view (the top masks the upper half of the 256-bit beat).
    clk_x1          : in  std_logic := '0';
    calib_done      : in  std_logic := '0';
    app_cmd_rdy     : in  std_logic := '0';
    app_cmd         : out std_logic_vector(2 downto 0);
    app_cmd_en      : out std_logic;
    app_addr        : out std_logic_vector(26 downto 0);
    app_wdata       : out std_logic_vector(127 downto 0);
    app_wdata_mask  : out std_logic_vector(15 downto 0);
    app_wren        : out std_logic;
    app_wdata_end   : out std_logic;
    app_wdata_rdy   : in  std_logic := '0';
    app_rdata       : in  std_logic_vector(127 downto 0) := (others => '0');
    app_rdata_valid : in  std_logic := '0'
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

  -- 480x270 RGB565 shown 2x (960x540) centred in the 1280x720 frame.
  -- Fewer BSRAM blocks than 640x360 leaves routing headroom for the CPU
  -- domain; the pixel/line doubling stays integer so the image is sharp.
  constant FB_W     : natural := 480;
  constant FB_H     : natural := 270;
  constant WORDS_PL : natural := FB_W / 2;               -- 240 words / line
  constant FB_WORDS : natural := WORDS_PL * FB_H;        -- 64800
  constant FB_BYTES : natural := FB_W * FB_H * 2;        -- 259200
  constant FB_AW    : natural := 17;
  constant HBORDER  : natural := (H_ACTIVE - FB_W * 2) / 2; -- 160
  constant VBORDER  : natural := (V_ACTIVE - FB_H * 2) / 2; -- 90
  constant WIN_XE   : natural := HBORDER + FB_W * 2;         -- 1120
  constant WIN_YE   : natural := VBORDER + FB_H * 2;         -- 630

  -- pixel clock domain
  signal lock_i        : std_logic;
  signal clk_pix       : std_logic;
  signal clk_5x        : std_logic;
  signal reset_sr      : std_logic_vector(7 downto 0) := (others => '0');
  signal reset_video   : std_logic;
  signal x             : unsigned(10 downto 0) := (others => '0');
  signal y             : unsigned(9 downto 0) := (others => '0');
  signal active        : std_logic;
  signal in_window     : std_logic;
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
  type bus_state_t is (B_IDLE, B_RDWAIT, B_RDWAIT2, B_DDR, B_RESP);
  signal bus_state  : bus_state_t := B_IDLE;
  signal rdata_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal ctrl_reg   : std_logic_vector(2 downto 0) := "001";
  signal frame_cnt  : unsigned(15 downto 0) := (others => '0');
  signal vblank_m   : std_logic := '0';
  signal vblank_s   : std_logic := '0';
  signal vblank_p   : std_logic := '0';
  signal fb_qa      : std_logic_vector(31 downto 0);
  signal fb_wea     : std_logic_vector(3 downto 0);
  signal sel_regs   : std_logic;
  signal sel_pixels : std_logic;
  signal word_idx   : std_logic_vector(FB_AW-1 downto 0);

  -- DDR3 backend hookup (tied off by the BSRAM generate)
  signal dcpu_req    : std_logic;
  signal dcpu_ack    : std_logic;
  signal dcpu_rdata  : std_logic_vector(31 downto 0);
  signal calib_bus_s : std_logic;
  signal rd_addr_r   : std_logic_vector(8 downto 0) := (others => '0');
  signal line_req_p  : std_logic := '0';
  signal line_num_r  : std_logic_vector(8 downto 0) := (others => '0');
begin
  pll_lock    <= lock_i;
  reset_video <= not reset_sr(7);
  sel_regs    <= addr(23);
  sel_pixels  <= '1' when addr(23) = '0' and
                          unsigned(addr) < to_unsigned(FB_BYTES, addr'length)
                 else '0';
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

  -- Framebuffer storage, BSRAM backend: one 8-bit dual-clock bank per
  -- byte lane, single-cycle write strobes while the transaction leaves
  -- B_IDLE.
  bsram_g : if not FB_DDR3 generate
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

    wea_g : for i in 0 to 3 generate
      fb_wea(i) <= '1' when bus_state = B_IDLE and req = '1' and we = '1'
                            and sel_pixels = '1' and be(i) = '1' else '0';
    end generate;

    dcpu_ack    <= '0';
    dcpu_rdata  <= (others => '0');
    calib_bus_s <= '1';
    app_cmd <= "001"; app_cmd_en <= '0'; app_addr <= (others => '0');
    app_wdata <= (others => '0'); app_wdata_mask <= (others => '0');
    app_wren <= '0'; app_wdata_end <= '0';
  end generate;

  -- Framebuffer storage, DDR3 backend: pixel data behind the Gowin IP,
  -- scanout from the backend's double line buffer (same port-B latency
  -- as sys16_fb_ram8, so the fetch pipeline below is unchanged).
  ddr_g : if FB_DDR3 generate
    backend_i : entity work.sys16_fb_ddr3
      generic map (LINE_WORDS => WORDS_PL, NUM_LINES => FB_H)
      port map (
        clk_bus   => clk_in,
        rst_bus_n => reset_n,
        cpu_req   => dcpu_req,
        cpu_we    => we,
        cpu_addr  => word_idx,
        cpu_be    => be,
        cpu_wdata => wdata,
        cpu_rdata => dcpu_rdata,
        cpu_ack   => dcpu_ack,
        calib_bus => calib_bus_s,
        clk_pix   => clk_pix,
        rst_pix_n => reset_sr(7),
        line_req  => line_req_p,
        line_num  => line_num_r,
        rd_addr   => rd_addr_r,
        rd_data   => fb_qb,
        clk_x1          => clk_x1,
        calib_done      => calib_done,
        app_cmd_rdy     => app_cmd_rdy,
        app_cmd         => app_cmd,
        app_cmd_en      => app_cmd_en,
        app_addr        => app_addr,
        app_wdata       => app_wdata,
        app_wdata_mask  => app_wdata_mask,
        app_wren        => app_wren,
        app_wdata_end   => app_wdata_end,
        app_wdata_rdy   => app_wdata_rdy,
        app_rdata       => app_rdata,
        app_rdata_valid => app_rdata_valid
      );
    fb_qa  <= (others => '0');
    fb_wea <= (others => '0');
  end generate;

  -- Backend request: level while B_DDR waits, dropped in the ack cycle
  -- (the backend's handshake contract; kills any retrigger race).
  dcpu_req <= '1' when bus_state = B_DDR and dcpu_ack = '0' else '0';

  -- Bus device FSM: same req/ready contract as sys16_sdram_bridge
  -- (ready held until the bridge drops req).
  bus_p : process(clk_in)
  begin
    if rising_edge(clk_in) then
      if reset_n = '0' then
        bus_state <= B_IDLE;
        -- Linux simple-framebuffer has no board-specific CTRL write. Enable
        -- scanout by default, with test pattern and diagnostic overlay off.
        ctrl_reg  <= "001";
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
              if sel_regs = '1' then
                if we = '1' then
                  if addr(3 downto 2) = "01" and be(0) = '1' then
                    ctrl_reg <= wdata(2 downto 0);
                  end if;
                  bus_state <= B_RESP;
                else
                  bus_state <= B_RDWAIT;
                end if;
              elsif sel_pixels = '0' then
                -- The decoded CPU aperture is larger than the physical
                -- framebuffer. Do not alias accesses beyond 480x270 RGB565.
                rdata_r   <= (others => '0');
                bus_state <= B_RESP;
              elsif FB_DDR3 then
                -- pixel window -> DDR3 backend. Uncalibrated the device
                -- answers immediately (write dropped, read zero) so the
                -- AXI fabric can never wedge on a cold DDR3.
                if calib_bus_s = '0' then
                  rdata_r   <= (others => '0');
                  bus_state <= B_RESP;
                else
                  bus_state <= B_DDR;
                end if;
              elsif we = '1' then
                bus_state <= B_RESP;   -- BSRAM write strobed by wea_g
              else
                bus_state <= B_RDWAIT;
              end if;
            end if;

          when B_DDR =>
            if dcpu_ack = '1' then
              rdata_r   <= dcpu_rdata;
              bus_state <= B_RESP;
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
                  -- STATUS: [31:16] frame counter, bit1 DDR3 calibrated
                  -- (constant '1' on the BSRAM backend), bit0 vblank.
                  rdata_r <= std_logic_vector(frame_cnt) &
                             "00000000000000" & calib_bus_s & vblank_s;
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
  -- fb_qb_r stage line the data up exactly with x. The image sits in a
  -- centred 960x540 window; inside it the source word address is
  -- ((ny-VBORDER)/2)*240 + (nx-HBORDER)/4, built from shifts (no
  -- multiplier: 240 = 256-16). Line doubling falls out of /2, pixel
  -- doubling out of /4. Outside the window the address is parked at 0;
  -- the paint stage blanks those pixels anyway.
  fetch_p : process(clk_pix)
    variable nx   : unsigned(10 downto 0);
    variable ny   : unsigned(9 downto 0);
    variable ax   : unsigned(10 downto 0);
    variable ay   : unsigned(9 downto 0);
    variable fbl  : unsigned(8 downto 0);
    variable wadr : unsigned(FB_AW-1 downto 0);
  begin
    if rising_edge(clk_pix) then
      if reset_video = '1' then
        addrb_r   <= (others => '0');
        rd_addr_r <= (others => '0');
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
        if nx >= to_unsigned(HBORDER, nx'length) and
           nx < to_unsigned(WIN_XE, nx'length) and
           ny >= to_unsigned(VBORDER, ny'length) and
           ny < to_unsigned(WIN_YE, ny'length) then
          ax   := nx - to_unsigned(HBORDER, nx'length);
          ay   := ny - to_unsigned(VBORDER, ny'length);
          fbl  := ay(9 downto 1);
          wadr := shift_left(resize(fbl, FB_AW), 8) -
                  shift_left(resize(fbl, FB_AW), 4) +
                  resize(ax(9 downto 2), FB_AW);
          addrb_r   <= std_logic_vector(wadr);
          -- DDR3 backend: line-buffer half (fb line LSB) & word-in-line
          rd_addr_r <= std_logic_vector(fbl(0) & ax(9 downto 2));
          half_d1 <= ax(1);
        else
          addrb_r   <= (others => '0');
          rd_addr_r <= (others => '0');
          half_d1 <= '0';
        end if;
        fb_qb_r <= fb_qb;
        half_d2 <= half_d1;
        half_d3 <= half_d2;
        half_d4 <= half_d3;
      end if;
    end if;
  end process;

  -- DDR3 line prefetch (unused loads pruned on the BSRAM backend): at
  -- the start of screen line y request the framebuffer line whose first
  -- doubled row is y+2. That fetches every line exactly once per frame,
  -- two scan lines (~44 us) before it is displayed -- the fetch itself
  -- takes ~2 us -- and always into the buffer half the display is not
  -- reading (ping-pong on the line LSB). No V_TOTAL wrap is needed:
  -- y+2 stays below 2**10 and rows past the window simply never match.
  prefetch_p : process(clk_pix)
    variable ny2 : unsigned(9 downto 0);
    variable ay2 : unsigned(9 downto 0);
  begin
    if rising_edge(clk_pix) then
      if reset_video = '1' then
        line_req_p <= '0';
        line_num_r <= (others => '0');
      else
        line_req_p <= '0';
        if x = to_unsigned(0, x'length) then
          ny2 := y + 2;
          if ny2 >= to_unsigned(VBORDER, ny2'length) and
             ny2 < to_unsigned(WIN_YE, ny2'length) then
            ay2 := ny2 - to_unsigned(VBORDER, ny2'length);
            if ay2(0) = '0' then
              line_num_r <= std_logic_vector(ay2(9 downto 1));
              line_req_p <= '1';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Pixel inside the centred 960x540 window?
  in_window <= '1' when x >= to_unsigned(HBORDER, x'length) and
                        x < to_unsigned(WIN_XE, x'length) and
                        y >= to_unsigned(VBORDER, y'length) and
                        y < to_unsigned(WIN_YE, y'length) else '0';

  -- Output mux: blanking, diagnostic stripe overlay, window border,
  -- enable gate, test pattern, framebuffer pixel (RGB565 -> RGB888).
  paint_p : process(x, y, active, in_window, status_sync, ctrl_sync,
                    half_d4, fb_qb_r)
    variable status_rgb : std_logic_vector(23 downto 0);
    variable pix16      : std_logic_vector(15 downto 0);
    variable test_rgb   : std_logic_vector(23 downto 0);
  begin
    status_rgb := status_sync(15 downto 11) & status_sync(15 downto 13) &
                  status_sync(10 downto 5) & status_sync(10 downto 9) &
                  status_sync(4 downto 0) & status_sync(4 downto 2);

    -- Test pattern in window-local coordinates so its bounds mark the
    -- active image area exactly.
    test_rgb := std_logic_vector(x(7 downto 3)) &
                std_logic_vector(x(7 downto 5)) &
                std_logic_vector(y(7 downto 2)) &
                std_logic_vector(y(7 downto 6)) &
                (x(4) xor y(4)) & "0000000";

    if half_d4 = '1' then
      pix16 := fb_qb_r(31 downto 16);
    else
      pix16 := fb_qb_r(15 downto 0);
    end if;

    if active = '0' then
      pixel_data <= x"000000";
    elsif ctrl_sync(2) = '1' and y < to_unsigned(48, y'length) then
      pixel_data <= status_rgb;
    elsif in_window = '0' then
      pixel_data <= x"000000";  -- border around the centred image
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
