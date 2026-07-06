-- DDR3 framebuffer controller for the 320x200 8bpp (RGB332) VIC bitmap mode.
--
-- Backend: the Gowin "DDR3 Memory Interface" IP (DDR3_Memory_Interface_Top) in
-- the x16 / 128-bit user configuration (same IP/PLL/pins as the c64_ddr project,
-- which is known-good). 1:4 clock ratio -> BL8 = 8x 16-bit words = 128-bit user
-- beat = 16 bytes, app-style interface (cmd/cmd_en/cmd_rdy, wr_data/wr_data_mask/
-- wr_data_en/wr_data_end/wr_data_rdy, rd_data/rd_data_valid). The IP auto-refreshes.
--
-- Pixel mapping (ONE PIXEL PER BYTE): a BL8 burst is 16 bytes = 16 pixels. Using
-- the SAME address/lane convention as ddr3_byte_bridge for this IP:
--   app_addr (counts 16-bit words) = (byteAddr[.. : 4]) & "000"   (= byteAddr/16*8)
--   lane = byteAddr[3:0]           (which byte inside the 128-bit beat)
--   pixel byte = rd_data[lane*8 +: 8]
-- For pixel index P the byte address is FB_BASE_WORD + P.
-- A CPU pixel write is a read-modify-write of the 16-byte burst (one byte changed,
-- whole beat written back, mask=0) -- the conservative path the x8 bring-up used.
-- A scanline prefetch reads 20 bursts (16 px each) into a double line buffer.
--
-- Two masters, arbitrated on clk_x1: line-fetch has priority over the CPU.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_fb_ddr3 is
  generic (
    FB_BASE_WORD  : natural  := 0;       -- byte base address of the frame in DDR3
    LINE_PIX      : positive := 320;     -- pixels per scanline (multiple of 16)
    NUM_LINES     : positive := 200;
    APP_ADDR_BITS : positive := 27       -- Gowin IP word-address width (x16 IP: 27)
  );
  port (
    -- ---- clk_sys (6502 / display) side --------------------------------------
    clk_sys   : in  std_logic;
    rst_sys_n : in  std_logic;

    fb_frame_start : in  std_logic;                      -- pulse at frame start
    fb_line_adv    : in  std_logic;                      -- pulse per logical line
    fb_rdaddr      : in  std_logic_vector(9 downto 0);   -- (disp_line mod 2)*320 + col
    fb_rddata      : out std_logic_vector(7 downto 0);

    cpu_req   : in  std_logic;
    cpu_we    : in  std_logic;
    cpu_addr  : in  std_logic_vector(16 downto 0);       -- pixel index
    cpu_din   : in  std_logic_vector(7 downto 0);
    cpu_dout  : out std_logic_vector(7 downto 0);
    cpu_ack   : out std_logic;

    -- ---- clk_x1 = Gowin DDR3 IP clk_out (app interface, 128-bit) -------------
    clk_x1          : in  std_logic;
    calib_done      : in  std_logic;
    app_cmd_rdy     : in  std_logic;
    app_cmd         : out std_logic_vector(2 downto 0);
    app_cmd_en      : out std_logic;
    app_addr        : out std_logic_vector(APP_ADDR_BITS-1 downto 0);
    app_wdata       : out std_logic_vector(127 downto 0);
    app_wdata_mask  : out std_logic_vector(15 downto 0);
    app_wren        : out std_logic;
    app_wdata_end   : out std_logic;
    app_wdata_rdy   : in  std_logic;
    app_rdata       : in  std_logic_vector(127 downto 0);
    app_rdata_valid : in  std_logic
  );
end entity;

architecture rtl of vic_fb_ddr3 is

  constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
  constant CMD_READ  : std_logic_vector(2 downto 0) := "001";
  constant BURST_PIX : natural := 16;   -- pixels per 128-bit BL8 beat

  -- Double line buffer: 2 halves x LINE_PIX bytes, dual-clock block RAM
  -- (write clk_x1 fill, read clk_sys registered).
  type lbuf_t is array (0 to 2*LINE_PIX - 1) of std_logic_vector(7 downto 0);
  signal lbuf : lbuf_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of lbuf : signal is "block";

  -- CDC sys->x1 single-bit toggles
  signal fs_tgl_sys  : std_logic := '0';
  signal adv_tgl_sys : std_logic := '0';
  signal cpu_tgl_sys : std_logic := '0';
  signal fs_tgl_x1   : std_logic_vector(2 downto 0) := (others => '0');
  signal adv_tgl_x1  : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_tgl_x1  : std_logic_vector(2 downto 0) := (others => '0');

  -- CDC x1->sys ack toggle
  signal ack_tgl_x1  : std_logic := '0';
  signal ack_tgl_sys : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_dout_x1 : std_logic_vector(7 downto 0) := (others => '0');

  signal cpu_busy_sys : std_logic := '0';
  signal cpu_dout_reg : std_logic_vector(7 downto 0) := (others => '0');

  type st_t is (S_CALIB, S_IDLE,
                S_FILL_REQ, S_FILL_WAIT, S_FILL_STORE,
                S_CW_RDREQ, S_CW_RDWAIT, S_CW_WRREQ, S_CW_WRDATA,
                S_CR_REQ,   S_CR_WAIT);
  signal st : st_t := S_CALIB;
  signal cw_data : std_logic_vector(127 downto 0) := (others => '0');

  signal disp_idx   : unsigned(8 downto 0) := (others => '0');
  type half_line_t is array (0 to 1) of unsigned(8 downto 0);
  signal half_line  : half_line_t := (others => (others => '0'));
  signal half_valid : std_logic_vector(1 downto 0) := (others => '0');
  signal cur_line   : unsigned(8 downto 0) := (others => '0');
  signal cur_half   : std_logic := '0';
  signal col        : natural range 0 to LINE_PIX := 0;
  signal fill_data  : std_logic_vector(127 downto 0) := (others => '0');
  signal store_idx  : natural range 0 to BURST_PIX-1 := 0;

  signal cpu_pending : std_logic := '0';
  signal cpu_op_we   : std_logic := '0';
  signal cpu_op_addr : std_logic_vector(16 downto 0) := (others => '0');
  signal cpu_op_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_lane    : natural range 0 to 15 := 0;

  signal wd_cnt   : unsigned(13 downto 0) := (others => '0');

  -- app word address (16-bit words) for a pixel; lane = byte within the beat.
  function burst_addr(pix : natural) return std_logic_vector is
    variable ba : unsigned(23 downto 0);
  begin
    ba := to_unsigned(FB_BASE_WORD + pix, 24);
    return std_logic_vector(resize(ba(23 downto 4) & "000", APP_ADDR_BITS));
  end function;

  function lane_of(pix : natural) return natural is
    variable ba : unsigned(23 downto 0);
  begin
    ba := to_unsigned(FB_BASE_WORD + pix, 24);
    return to_integer(ba(3 downto 0));
  end function;

begin

  -- display read (registered, clk_sys)
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      fb_rddata <= lbuf(to_integer(unsigned(fb_rdaddr)));
    end if;
  end process;

  cpu_dout <= cpu_dout_reg;

  -- clk_sys: pulse->toggle, CPU req/ack handshake
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst_sys_n = '0' then
        fs_tgl_sys <= '0'; adv_tgl_sys <= '0'; cpu_tgl_sys <= '0';
        cpu_busy_sys <= '0'; ack_tgl_sys <= (others => '0');
        cpu_ack <= '0'; cpu_dout_reg <= (others => '0');
      else
        cpu_ack <= '0';
        ack_tgl_sys <= ack_tgl_sys(1 downto 0) & ack_tgl_x1;
        if fb_frame_start = '1' then fs_tgl_sys  <= not fs_tgl_sys;  end if;
        if fb_line_adv   = '1' then adv_tgl_sys <= not adv_tgl_sys; end if;
        if cpu_busy_sys = '0' then
          if cpu_req = '1' then
            cpu_tgl_sys  <= not cpu_tgl_sys;
            cpu_busy_sys <= '1';
          end if;
        else
          if ack_tgl_sys(2) /= ack_tgl_sys(1) then
            cpu_dout_reg <= cpu_dout_x1;
            cpu_ack      <= '1';
            cpu_busy_sys <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- clk_x1: main FSM (Gowin IP app interface, 128-bit)
  process(clk_x1, rst_sys_n)
    variable ln : natural range 0 to 15;
  begin
    if rst_sys_n = '0' then
      st <= S_CALIB;
      app_cmd <= CMD_READ; app_cmd_en <= '0';
      app_addr <= (others => '0'); app_wren <= '0'; app_wdata_end <= '0';
      app_wdata <= (others => '0'); app_wdata_mask <= (others => '0');
      disp_idx <= (others => '0');
      half_line <= (others => (others => '0'));
      half_valid <= (others => '0');
      cur_line <= (others => '0'); cur_half <= '0'; col <= 0;
      fill_data <= (others => '0'); store_idx <= 0;
      cpu_pending <= '0'; cpu_op_we <= '0';
      cpu_op_addr <= (others => '0'); cpu_op_din <= (others => '0');
      cpu_lane <= 0; cpu_dout_x1 <= (others => '0'); ack_tgl_x1 <= '0';
      wd_cnt <= (others => '0');
      fs_tgl_x1 <= (others => '0'); adv_tgl_x1 <= (others => '0');
      cpu_tgl_x1 <= (others => '0');
    elsif rising_edge(clk_x1) then
      app_cmd_en <= '0'; app_wren <= '0'; app_wdata_end <= '0';  -- 1-cycle pulses

      fs_tgl_x1  <= fs_tgl_x1(1 downto 0)  & fs_tgl_sys;
      adv_tgl_x1 <= adv_tgl_x1(1 downto 0) & adv_tgl_sys;
      cpu_tgl_x1 <= cpu_tgl_x1(1 downto 0) & cpu_tgl_sys;
      if cpu_tgl_x1(2) /= cpu_tgl_x1(1) then cpu_pending <= '1'; end if;

      if fs_tgl_x1(2) /= fs_tgl_x1(1) then
        disp_idx <= (others => '0'); half_valid <= (others => '0');
      elsif adv_tgl_x1(2) /= adv_tgl_x1(1) then
        if to_integer(disp_idx) + 1 < NUM_LINES then disp_idx <= disp_idx + 1; end if;
      end if;

      if st = S_IDLE or st = S_CALIB then wd_cnt <= (others => '0');
      else wd_cnt <= wd_cnt + 1; end if;

      case st is
        when S_CALIB =>
          if calib_done = '1' then st <= S_IDLE; end if;

        when S_IDLE =>
          if half_valid(to_integer(disp_idx(0 downto 0))) = '0'
             or half_line(to_integer(disp_idx(0 downto 0))) /= disp_idx then
            cur_line <= disp_idx; cur_half <= disp_idx(0); col <= 0;
            st <= S_FILL_REQ;
          elsif to_integer(disp_idx) + 1 < NUM_LINES
                and (half_valid(1 - to_integer(disp_idx(0 downto 0))) = '0'
                     or half_line(1 - to_integer(disp_idx(0 downto 0))) /= disp_idx + 1) then
            cur_line <= disp_idx + 1; cur_half <= not disp_idx(0); col <= 0;
            st <= S_FILL_REQ;
          elsif cpu_pending = '1' then
            cpu_op_we   <= cpu_we;
            cpu_op_addr <= cpu_addr;
            cpu_op_din  <= cpu_din;
            cpu_lane    <= lane_of(to_integer(unsigned(cpu_addr)));
            -- masked single-byte write: no read-modify-write, so a marginal DDR3
            -- read can't corrupt the 15 neighbour bytes (the scattered-pixel bug).
            if cpu_we = '1' then st <= S_CW_WRREQ;
            else                 st <= S_CR_REQ;
            end if;
          end if;

        -- line fetch: one BL8 burst (16 pixels) per request
        when S_FILL_REQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(cur_line) * LINE_PIX + col);
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_FILL_WAIT;
          end if;
        when S_FILL_WAIT =>
          if app_rdata_valid = '1' then
            fill_data <= app_rdata;
            store_idx <= 0;
            st <= S_FILL_STORE;
          end if;
        when S_FILL_STORE =>
          -- write the 16 pixel bytes of the burst, one per cycle
          lbuf(to_integer(unsigned'('0' & cur_half)) * LINE_PIX + col + store_idx)
            <= fill_data(store_idx*8 + 7 downto store_idx*8);
          if store_idx = BURST_PIX-1 then
            if col + BURST_PIX >= LINE_PIX then
              half_line(to_integer(unsigned'('0' & cur_half)))  <= cur_line;
              half_valid(to_integer(unsigned'('0' & cur_half))) <= '1';
              st <= S_IDLE;
            else
              col <= col + BURST_PIX;
              st <= S_FILL_REQ;
            end if;
          else
            store_idx <= store_idx + 1;
          end if;

        -- CPU pixel write (read-modify-write of the 16-byte burst)
        when S_CW_RDREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CW_RDWAIT;
          end if;
        when S_CW_RDWAIT =>
          if app_rdata_valid = '1' then
            ln := cpu_lane;
            cw_data <= app_rdata;
            cw_data(ln*8 + 7 downto ln*8) <= cpu_op_din;
            st <= S_CW_WRREQ;
          end if;
        -- decoupled write: WRITE command on cmd_rdy, then data on wr_data_rdy
        when S_CW_WRREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_WRITE;
            app_cmd_en <= '1';
            st <= S_CW_WRDATA;
          end if;
        when S_CW_WRDATA =>
          if app_wdata_rdy = '1' then
            ln := cpu_lane;
            -- write ONLY the target lane byte; mask ('1' = disabled) the other 15
            -- so the burst's neighbour bytes keep their stored DDR3 value.
            app_wdata(ln*8 + 7 downto ln*8) <= cpu_op_din;
            app_wdata_mask <= (others => '1');
            app_wdata_mask(ln) <= '0';
            app_wren       <= '1';
            app_wdata_end  <= '1';
            for h in 0 to 1 loop
              if half_valid(h) = '1'
                 and unsigned(cpu_op_addr) >= half_line(h) * LINE_PIX
                 and unsigned(cpu_op_addr) <  half_line(h) * LINE_PIX + LINE_PIX then
                half_valid(h) <= '0';
              end if;
            end loop;
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;

        -- CPU pixel read: read the burst, extract the lane byte
        when S_CR_REQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CR_WAIT;
          end if;
        when S_CR_WAIT =>
          if app_rdata_valid = '1' then
            ln := cpu_lane;
            cpu_dout_x1 <= app_rdata(ln*8 + 7 downto ln*8);
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;

        when others =>
          st <= S_IDLE;
      end case;

      -- watchdog: abort a stuck op so the CPU never hangs forever
      if wd_cnt = "11111111111111" and st /= S_IDLE and st /= S_CALIB then
        if st = S_CR_REQ or st = S_CR_WAIT
           or st = S_CW_RDREQ or st = S_CW_RDWAIT
           or st = S_CW_WRREQ or st = S_CW_WRDATA then
          ack_tgl_x1  <= not ack_tgl_x1;
          cpu_pending <= '0';
        end if;
        st <= S_IDLE;
      end if;

      if calib_done = '0' then st <= S_CALIB; end if;
    end if;
  end process;

end architecture;
