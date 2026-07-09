-- Simple SDRAM-backed framebuffer/blitter for Tang Console SDRAM0 bring-up.
--
-- Pixels are stored one byte per SDRAM word (lower byte used) to keep byte
-- writes simple with the existing controller. Line prefetch uses full-page
-- read bursts chunked at the 512-word page boundary: with BL8 the per-burst
-- ACT/CAS/PRE overhead (~25 clks per 8 words) exceeds one scanline for the
-- 640-pixel hi-res mode, which starved both the scanner and the CPU write
-- port. A full-page burst streams one word per clock until the controller
-- precharges, so a whole 640-word line costs ~700 clks of the 1600-clk line.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity sdram_fb is
  generic (
    LINE_PIX       : positive := 320;
    NUM_LINES      : positive := 200;
    HIRES_LINE_PIX : positive := 640;
    HIRES_LINES    : positive := 400
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    ready     : out std_logic;

    fb_frame_start : in  std_logic;
    fb_line_adv    : in  std_logic;
    fb_rdaddr      : in  std_logic_vector(10 downto 0);
    fb_rddata      : out std_logic_vector(15 downto 0);
    hires          : in  std_logic := '0';

    cpu_req   : in  std_logic;
    cpu_we    : in  std_logic;
    cpu_addr  : in  std_logic_vector(17 downto 0);
    cpu_din   : in  data_t;
    cpu_dout  : out data_t;
    cpu_ack   : out std_logic;

    blit_op      : in  std_logic_vector(2 downto 0) := (others => '0');
    blit_x0      : in  unsigned(9 downto 0) := (others => '0');
    blit_y0      : in  unsigned(9 downto 0) := (others => '0');
    blit_x1      : in  unsigned(9 downto 0) := (others => '0');
    blit_y1      : in  unsigned(9 downto 0) := (others => '0');
    blit_color   : in  std_logic_vector(7 downto 0) := (others => '0');
    blit_page    : in  std_logic := '0';
    blit_gap_cfg : in  std_logic_vector(7 downto 0) := x"0C";
    blit_dstx    : in  unsigned(9 downto 0) := (others => '0');
    blit_dsty    : in  unsigned(9 downto 0) := (others => '0');
    blit_tex_base  : in  unsigned(17 downto 0) := (others => '0');
    blit_tex_u0    : in  signed(15 downto 0) := (others => '0');
    blit_tex_v0    : in  signed(15 downto 0) := (others => '0');
    blit_tex_dudx  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dvdx  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dudy  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dvdy  : in  signed(15 downto 0) := (others => '0');
    blit_tex_flags : in  std_logic_vector(7 downto 0) := (others => '0');
    blit_start   : in  std_logic := '0';
    blit_busy    : out std_logic;

    sdram_cke   : out   std_logic;
    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sdram_fb is
  constant HALF : natural := 640;
  -- sdram_ctrl maps addr(8:0) to the column, so one open row holds 512 words.
  constant PAGE_WORDS   : natural := 512;
  constant WR_BURST_LEN : std_logic_vector(9 downto 0) :=
    std_logic_vector(to_unsigned(1, 10));

  type lbuf_t is array (0 to 2 * HALF - 1) of std_logic_vector(15 downto 0);
  signal lbuf : lbuf_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of lbuf : signal is "block";

  type st_t is (
    S_RESET,
    S_IDLE,
    S_FETCH_CALC,
    S_FETCH_REQ,
    S_FETCH_WAIT,
    S_CPU_RD_REQ,
    S_CPU_RD_WAIT,
    S_CPU_WR_REQ,
    S_CPU_WR_WAIT,
    S_BLIT_WR_REQ,
    S_BLIT_WR_WAIT,
    S_BLIT_RD_REQ,
    S_BLIT_RD_WAIT
  );
  signal st : st_t := S_RESET;

  signal ctrl_rst      : std_logic;
  signal ctrl_idle     : std_logic;
  signal init_done     : std_logic := '0';
  signal wr_req        : std_logic := '0';
  signal wr_data       : std_logic_vector(15 downto 0) := (others => '0');
  signal wr_len        : std_logic_vector(9 downto 0) := (0 => '1', others => '0');
  signal wr_addr       : std_logic_vector(23 downto 0) := (others => '0');
  signal wr_dqm        : std_logic_vector(1 downto 0) := "10";
  signal wr_data_req   : std_logic;
  signal wr_finish     : std_logic;
  signal rd_req        : std_logic := '0';
  signal rd_len        : std_logic_vector(9 downto 0) :=
    std_logic_vector(to_unsigned(1, 10));
  signal rd_addr       : std_logic_vector(23 downto 0) := (others => '0');
  signal rd_data       : std_logic_vector(15 downto 0);
  signal rd_valid      : std_logic;
  signal rd_finish     : std_logic;

  signal disp_line     : unsigned(8 downto 0) := (others => '0');
  signal half0_valid   : std_logic := '0';
  signal half1_valid   : std_logic := '0';
  signal half0_line    : unsigned(8 downto 0) := (others => '0');
  signal half1_line    : unsigned(8 downto 0) := (others => '0');
  -- Pixel-address range [base, end) buffered in each half. CPU/blit writes only
  -- invalidate the half whose buffered line they actually touch; writes to
  -- off-screen lines (the common case while drawing) cost no refetch at all.
  signal half0_base    : unsigned(18 downto 0) := (others => '0');
  signal half0_end     : unsigned(18 downto 0) := (others => '0');
  signal half1_base    : unsigned(18 downto 0) := (others => '0');
  signal half1_end     : unsigned(18 downto 0) := (others => '0');
  signal fetch_line    : unsigned(8 downto 0) := (others => '0');
  signal fetch_half    : std_logic := '0';
  signal fetch_col     : unsigned(9 downto 0) := (others => '0');
  signal burst_left    : unsigned(9 downto 0) := (others => '0');

  signal cpu_addr_lat  : std_logic_vector(17 downto 0) := (others => '0');
  signal cpu_din_lat   : data_t := (others => '0');
  signal cpu_we_lat    : std_logic := '0';
  signal cpu_pending   : std_logic := '0';
  signal cpu_ack_r     : std_logic := '0';
  signal cpu_dout_r    : data_t := (others => '0');

  signal blit_we       : std_logic;
  signal blit_addr     : std_logic_vector(17 downto 0);
  signal blit_data     : std_logic_vector(7 downto 0);
  signal blit_ready    : std_logic := '0';
  signal blit_start_i  : std_logic;
  signal blit_addr_lat : std_logic_vector(17 downto 0) := (others => '0');
  signal blit_data_lat : std_logic_vector(7 downto 0) := (others => '0');
  -- blitter COPY source read channel
  signal blit_rd        : std_logic;
  signal blit_rd_addr   : std_logic_vector(17 downto 0);
  signal blit_rdata_r   : std_logic_vector(7 downto 0) := (others => '0');
  signal blit_rd_ready_r: std_logic := '0';

  function fb_addr(a : std_logic_vector(17 downto 0)) return std_logic_vector is
    variable r : unsigned(23 downto 0);
  begin
    r := resize(unsigned(a), 24);
    return std_logic_vector(r);
  end function;

  function line_addr(line : unsigned(8 downto 0); col : unsigned(9 downto 0);
                     line_pix : natural)
    return std_logic_vector is
    variable pix : unsigned(18 downto 0);
    variable r   : unsigned(23 downto 0);
  begin
    pix := resize(line * to_unsigned(line_pix, 10), 19) + resize(col, 19);
    r := resize(pix, 24);
    return std_logic_vector(r);
  end function;

begin
  ctrl_rst <= not reset_n;
  ready    <= init_done;
  cpu_ack  <= cpu_ack_r;
  cpu_dout <= cpu_dout_r;

  blit_start_i <= blit_start when init_done = '1' else '0';

  wr_len <= WR_BURST_LEN;

  blit_i : entity work.vic_blit
    generic map (LINE_PIX => HIRES_LINE_PIX, ADDR_BITS => 18)
    port map (
      clk       => clk,
      rst_n     => reset_n,
      op        => blit_op,
      x0        => blit_x0,
      y0        => blit_y0,
      x1        => blit_x1,
      y1        => blit_y1,
      color     => blit_color,
      dst_x     => blit_dstx,
      dst_y     => blit_dsty,
      tex_base  => blit_tex_base,
      tex_u0    => blit_tex_u0,
      tex_v0    => blit_tex_v0,
      tex_dudx  => blit_tex_dudx,
      tex_dvdx  => blit_tex_dvdx,
      tex_dudy  => blit_tex_dudy,
      tex_dvdy  => blit_tex_dvdy,
      tex_flags => blit_tex_flags,
      start     => blit_start_i,
      busy      => blit_busy,
      fbo_we    => blit_we,
      fbo_addr  => blit_addr,
      fbo_data  => blit_data,
      fbo_ready => blit_ready,
      fbi_re    => blit_rd,
      fbi_addr  => blit_rd_addr,
      fbi_data  => blit_rdata_r,
      fbi_ready => blit_rd_ready_r
    );

  sdram_i : entity work.sdram_ctrl
    generic map (
      -- CAS=3, sequential FULL-PAGE reads, single-location writes (A9=1).
      MODE_REG => "0001000110111"
    )
    port map (
      clk               => clk,
      rst               => ctrl_rst,
      wr_burst_req      => wr_req,
      wr_burst_data     => wr_data,
      wr_burst_len      => wr_len,
      wr_burst_addr     => wr_addr,
      wr_dqm            => wr_dqm,
      wr_burst_data_req => wr_data_req,
      wr_burst_finish   => wr_finish,
      rd_burst_req      => rd_req,
      rd_burst_len      => rd_len,
      rd_burst_addr     => rd_addr,
      rd_burst_data     => rd_data,
      rd_burst_data_valid => rd_valid,
      rd_burst_finish   => rd_finish,
      sdram_cke         => sdram_cke,
      sdram_cs_n        => sdram_cs_n,
      sdram_ras_n       => sdram_ras_n,
      sdram_cas_n       => sdram_cas_n,
      sdram_we_n        => sdram_we_n,
      sdram_ba          => sdram_ba,
      sdram_addr        => sdram_addr,
      sdram_dqm         => sdram_dqm,
      sdram_dq          => sdram_dq,
      ctrl_idle         => ctrl_idle
    );

  process(clk)
    variable ridx : natural range 0 to 2 * HALF - 1;
  begin
    if rising_edge(clk) then
      ridx := to_integer(unsigned(fb_rdaddr));
      if ridx < 2 * HALF then
        fb_rddata <= lbuf(ridx);
      else
        fb_rddata <= (others => '0');
      end if;
    end if;
  end process;

  process(clk)
    variable next_line  : unsigned(8 downto 0);
    variable half_valid : std_logic;
    variable half_line  : unsigned(8 downto 0);
    variable next_valid : std_logic;
    variable next_half_line : unsigned(8 downto 0);
    variable lb_idx     : natural range 0 to 2 * HALF - 1;
    variable active_lp  : natural range 1 to HIRES_LINE_PIX;
    variable active_ln  : natural range 1 to HIRES_LINES;
    variable page_rem   : natural range 1 to PAGE_WORDS;
    variable line_rem   : natural range 0 to HIRES_LINE_PIX;
    variable lbase      : unsigned(18 downto 0);
    variable waddr      : unsigned(18 downto 0);
  begin
    if rising_edge(clk) then
      cpu_ack_r  <= '0';
      blit_ready <= '0';
      blit_rd_ready_r <= '0';
      rd_req     <= '0';
      wr_req     <= '0';

      if hires = '1' then
        active_lp := HIRES_LINE_PIX;
        active_ln := HIRES_LINES;
      else
        active_lp := LINE_PIX;
        active_ln := NUM_LINES;
      end if;

      if reset_n = '0' then
        st <= S_RESET;
        init_done <= '0';
        disp_line <= (others => '0');
        half0_valid <= '0';
        half1_valid <= '0';
        fetch_line <= (others => '0');
        fetch_half <= '0';
        fetch_col <= (others => '0');
        burst_left <= (others => '0');
        cpu_pending <= '0';
        cpu_dout_r <= (others => '0');
      else
        -- cpu_req is a single-cycle pulse from the core's fbw port; latch it,
        -- because the FSM is usually mid-fetch when it arrives and would
        -- otherwise drop the request (the CPU then hangs waiting for the ack).
        if cpu_req = '1' then
          cpu_pending  <= '1';
          cpu_addr_lat <= cpu_addr;
          cpu_din_lat  <= cpu_din;
          cpu_we_lat   <= cpu_we;
        end if;

        if fb_frame_start = '1' then
          disp_line <= (others => '0');
          half0_valid <= '0';
          half1_valid <= '0';
        elsif fb_line_adv = '1' and to_integer(disp_line) < active_ln - 1 then
          disp_line <= disp_line + 1;
        end if;

        case st is
          when S_RESET =>
            if ctrl_idle = '1' then
              init_done <= '1';
              st <= S_IDLE;
            end if;

          when S_IDLE =>
            if ctrl_idle = '1' then
              half_valid := half0_valid;
              half_line  := half0_line;
              if disp_line(0) = '1' then
                half_valid := half1_valid;
                half_line  := half1_line;
              end if;

              next_line := disp_line;
              if to_integer(disp_line) < active_ln - 1 then
                next_line := disp_line + 1;
              end if;
              next_valid := half1_valid;
              next_half_line := half1_line;
              if disp_line(0) = '1' then
                next_valid := half0_valid;
                next_half_line := half0_line;
              end if;

              if half_valid = '0' or half_line /= disp_line then
                fetch_line <= disp_line;
                fetch_half <= disp_line(0);
                fetch_col  <= (others => '0');
                rd_addr    <= line_addr(disp_line, (others => '0'), active_lp);
                lbase := resize(disp_line * to_unsigned(active_lp, 10), 19);
                if disp_line(0) = '0' then
                  half0_base <= lbase;
                  half0_end  <= lbase + active_lp;
                else
                  half1_base <= lbase;
                  half1_end  <= lbase + active_lp;
                end if;
                st <= S_FETCH_CALC;
              elsif to_integer(disp_line) < active_ln - 1 and
                    (next_valid = '0' or next_half_line /= next_line) then
                fetch_line <= next_line;
                fetch_half <= not disp_line(0);
                fetch_col  <= (others => '0');
                rd_addr    <= line_addr(next_line, (others => '0'), active_lp);
                lbase := resize(next_line * to_unsigned(active_lp, 10), 19);
                if disp_line(0) = '1' then
                  half0_base <= lbase;
                  half0_end  <= lbase + active_lp;
                else
                  half1_base <= lbase;
                  half1_end  <= lbase + active_lp;
                end if;
                st <= S_FETCH_CALC;
              elsif cpu_pending = '1' then
                cpu_pending <= '0';
                if cpu_we_lat = '1' then
                  wr_addr <= fb_addr(cpu_addr_lat);
                  wr_data <= x"00" & cpu_din_lat;
                  wr_dqm  <= "10";
                  st <= S_CPU_WR_REQ;
                else
                  rd_addr <= fb_addr(cpu_addr_lat);
                  rd_len  <= std_logic_vector(to_unsigned(1, 10));
                  st <= S_CPU_RD_REQ;
                end if;
              elsif blit_we = '1' then
                blit_addr_lat <= blit_addr;
                blit_data_lat <= blit_data;
                wr_addr <= fb_addr(blit_addr);
                wr_data <= x"00" & blit_data;
                wr_dqm  <= "10";
                st <= S_BLIT_WR_REQ;
              elsif blit_rd = '1' then
                rd_addr <= fb_addr(blit_rd_addr);
                rd_len  <= std_logic_vector(to_unsigned(1, 10));
                st <= S_BLIT_RD_REQ;
              end if;
            end if;

          when S_FETCH_CALC =>
            -- Split the line fetch at SDRAM page boundaries: a full-page burst
            -- wraps at the end of the open row (column bits addr(8:0)), so each
            -- chunk must stay inside its 512-word page.
            -- rd_len feeds the controller's end-of-burst compare combinationally,
            -- so it must only change once the controller has drained the previous
            -- burst back to S_IDLE (ctrl_idle also covers pending refreshes).
            if ctrl_idle = '1' then
              page_rem := PAGE_WORDS - to_integer(unsigned(rd_addr(8 downto 0)));
              line_rem := active_lp - to_integer(fetch_col);
              if page_rem < line_rem then
                rd_len     <= std_logic_vector(to_unsigned(page_rem, 10));
                burst_left <= to_unsigned(page_rem, 10);
              else
                rd_len     <= std_logic_vector(to_unsigned(line_rem, 10));
                burst_left <= to_unsigned(line_rem, 10);
              end if;
              st <= S_FETCH_REQ;
            end if;

          when S_FETCH_REQ =>
            rd_req <= '1';
            if rd_valid = '1' then
              lb_idx := to_integer(unsigned'('0' & fetch_half)) * HALF +
                        to_integer(fetch_col);
              lbuf(lb_idx) <= x"00" & rd_data(7 downto 0);
              if to_integer(fetch_col) = active_lp - 1 then
                if fetch_half = '0' then
                  half0_valid <= '1';
                  half0_line  <= fetch_line;
                else
                  half1_valid <= '1';
                  half1_line  <= fetch_line;
                end if;
                st <= S_IDLE;
              elsif burst_left = to_unsigned(1, burst_left'length) then
                rd_addr   <= line_addr(fetch_line, fetch_col + 1, active_lp);
                fetch_col <= fetch_col + 1;
                st <= S_FETCH_CALC;
              else
                fetch_col  <= fetch_col + 1;
                burst_left <= burst_left - 1;
                st <= S_FETCH_WAIT;
              end if;
            end if;

          when S_FETCH_WAIT =>
            if rd_valid = '1' then
              lb_idx := to_integer(unsigned'('0' & fetch_half)) * HALF +
                        to_integer(fetch_col);
              lbuf(lb_idx) <= x"00" & rd_data(7 downto 0);
              if to_integer(fetch_col) = active_lp - 1 then
                if fetch_half = '0' then
                  half0_valid <= '1';
                  half0_line  <= fetch_line;
                else
                  half1_valid <= '1';
                  half1_line  <= fetch_line;
                end if;
                st <= S_IDLE;
              elsif burst_left = to_unsigned(1, burst_left'length) then
                rd_addr   <= line_addr(fetch_line, fetch_col + 1, active_lp);
                fetch_col <= fetch_col + 1;
                st <= S_FETCH_CALC;
              else
                fetch_col  <= fetch_col + 1;
                burst_left <= burst_left - 1;
              end if;
            elsif rd_finish = '1' then
              -- Defensive: the burst ended before the chunk was complete.
              -- Restart the current chunk from the next unwritten column.
              rd_addr <= line_addr(fetch_line, fetch_col, active_lp);
              st <= S_FETCH_CALC;
            end if;

          when S_CPU_RD_REQ =>
            rd_req <= '1';
            if rd_valid = '1' then
              cpu_dout_r <= rd_data(7 downto 0);
              cpu_ack_r  <= '1';
              st <= S_IDLE;
            end if;

          when S_CPU_RD_WAIT =>
            st <= S_IDLE;

          when S_CPU_WR_REQ =>
            wr_req <= '1';
            if wr_finish = '1' then
              cpu_ack_r <= '1';
              waddr := unsigned(wr_addr(18 downto 0));
              if waddr >= half0_base and waddr < half0_end then
                half0_valid <= '0';
              end if;
              if waddr >= half1_base and waddr < half1_end then
                half1_valid <= '0';
              end if;
              st <= S_IDLE;
            end if;

          when S_CPU_WR_WAIT =>
            st <= S_IDLE;

          when S_BLIT_WR_REQ =>
            wr_req <= '1';
            if wr_finish = '1' then
              blit_ready <= '1';
              waddr := unsigned(wr_addr(18 downto 0));
              if waddr >= half0_base and waddr < half0_end then
                half0_valid <= '0';
              end if;
              if waddr >= half1_base and waddr < half1_end then
                half1_valid <= '0';
              end if;
              st <= S_BLIT_WR_WAIT;
            end if;

          when S_BLIT_WR_WAIT =>
            st <= S_IDLE;

          -- blitter COPY source read: single-word full-page read, byte to the
          -- engine with a one-cycle ready pulse
          when S_BLIT_RD_REQ =>
            rd_req <= '1';
            if rd_valid = '1' then
              blit_rdata_r    <= rd_data(7 downto 0);
              blit_rd_ready_r <= '1';
              st <= S_BLIT_RD_WAIT;
            end if;

          when S_BLIT_RD_WAIT =>
            st <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
