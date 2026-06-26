-- DDR3 framebuffer controller for the 320x200 8bpp (RGB332) VIC bitmap mode.
--
-- Backend: the official Gowin "DDR3 Memory Interface" IP (DDR3_Memory_Interface_Top)
-- generated as x8 (Dq Width = 8) so it only uses/calibrates DQ[7:0] (bank 5, the
-- only byte lane with internal SSTL15 VREF). 1:4 clock ratio -> 64-bit (BL8) user
-- data, app-style interface (cmd/cmd_en/cmd_ready,
-- wr_data/wr_data_mask/wr_data_en/wr_data_end/wr_data_rdy, rd_data/rd_data_valid).
-- The IP auto-refreshes, so no refresh is issued here.
--
-- Pixel mapping: ONE PIXEL PER BYTE. A BL8 burst is 8 bytes = 8 pixels = the
-- 64-bit user beat. app addr counts bytes and is burst(8)-aligned. For a pixel
-- index P (byte W = FB_BASE_WORD+P):
--   burst app_addr = W & ~7      (8-byte aligned)
--   lane           = W mod 8     (which byte inside the 64-bit beat)
--   pixel byte     = rd_data[lane*8 +: 8]
-- A CPU pixel write is a read-modify-write of the 8-byte burst (one byte changed).
-- A scanline prefetch reads 40 bursts (8 pixels each) into the line buffer --
-- single-byte reads would be far too slow at the IP's read latency.
--
-- Two masters, arbitrated: line-fetch has priority over the CPU.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_fb_ddr3 is
  generic (
    FB_BASE_WORD : natural := 0;        -- word base address of the frame
    LINE_PIX     : positive := 320;     -- pixels per scanline (= words per line)
    NUM_LINES    : positive := 200;
    APP_ADDR_BITS : positive := 28      -- Gowin IP word-address width
  );
  port (
    -- ---- clk_sys (6502 / display) side --------------------------------------
    clk_sys   : in  std_logic;
    rst_sys_n : in  std_logic;

    fb_frame_start : in  std_logic;
    fb_line_adv    : in  std_logic;
    fb_rdaddr      : in  std_logic_vector(9 downto 0);   -- disp_line(0)*320 + col
    fb_rddata      : out std_logic_vector(7 downto 0);

    cpu_req   : in  std_logic;
    cpu_we    : in  std_logic;
    cpu_addr  : in  std_logic_vector(16 downto 0);       -- pixel index
    cpu_din   : in  std_logic_vector(7 downto 0);
    cpu_dout  : out std_logic_vector(7 downto 0);
    cpu_ack   : out std_logic;

    -- ---- clk_x1 = Gowin DDR3 IP clk_out (app interface) --------------------
    clk_x1          : in  std_logic;
    calib_done      : in  std_logic;
    app_cmd_rdy     : in  std_logic;
    app_cmd         : out std_logic_vector(2 downto 0);
    app_cmd_en      : out std_logic;
    app_addr        : out std_logic_vector(APP_ADDR_BITS-1 downto 0);
    app_wdata       : out std_logic_vector(63 downto 0);
    app_wdata_mask  : out std_logic_vector(7 downto 0);
    app_wren        : out std_logic;
    app_wdata_end   : out std_logic;
    app_wdata_rdy   : in  std_logic;
    app_rdata       : in  std_logic_vector(63 downto 0);
    app_rdata_valid : in  std_logic
  );
end entity;

architecture rtl of vic_fb_ddr3 is

  constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
  constant CMD_READ  : std_logic_vector(2 downto 0) := "001";

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

  -- ---- clk_x1 main FSM ----------------------------------------------------
  -- CPU pixel write is a read-modify-write: the Gowin IP write path is used the
  -- way Sipeed's proven tester does it -- full 64-bit burst, wr_data_mask=0
  -- (per-byte DM masking is avoided). So to change one pixel's byte we read the
  -- 8-byte burst, replace the one byte, and write the whole burst back.
  type st_t is (S_CALIB, S_IDLE,
                S_FILL_REQ, S_FILL_WAIT, S_FILL_STORE,
                S_CW_RDREQ, S_CW_RDWAIT, S_CW_WRREQ, S_CW_WRDATA,
                S_CR_REQ,   S_CR_WAIT);
  signal st : st_t := S_CALIB;
  signal cw_data : std_logic_vector(63 downto 0) := (others => '0');

  signal disp_idx   : unsigned(8 downto 0) := (others => '0');
  type half_line_t is array (0 to 1) of unsigned(8 downto 0);
  signal half_line  : half_line_t := (others => (others => '0'));
  signal half_valid : std_logic_vector(1 downto 0) := (others => '0');
  signal cur_line   : unsigned(8 downto 0) := (others => '0');
  signal cur_half   : std_logic := '0';
  signal col        : natural range 0 to LINE_PIX := 0;
  signal fill_data  : std_logic_vector(63 downto 0) := (others => '0');
  signal store_idx  : natural range 0 to 7 := 0;

  signal cpu_pending : std_logic := '0';
  signal cpu_op_we   : std_logic := '0';
  signal cpu_op_addr : std_logic_vector(16 downto 0) := (others => '0');
  signal cpu_op_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_lane    : natural range 0 to 7 := 0;

  signal wd_cnt   : unsigned(13 downto 0) := (others => '0');

  -- burst (8-word aligned) app address for a pixel index
  function burst_addr(pix : natural) return std_logic_vector is
    variable w : natural;
  begin
    w := FB_BASE_WORD + pix;
    return std_logic_vector(to_unsigned((w / 8) * 8, APP_ADDR_BITS));
  end function;

  function lane_of(pix : natural) return natural is
  begin
    return (FB_BASE_WORD + pix) mod 8;
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

  -- clk_x1: main FSM (Gowin IP app interface)
  process(clk_x1, rst_sys_n)
    variable ln : natural range 0 to 7;
  begin
    if rst_sys_n = '0' then
      st <= S_CALIB;
      app_cmd <= CMD_READ; app_cmd_en <= '0';
      app_addr <= (others => '0'); app_wren <= '0'; app_wdata_end <= '0';
      app_wdata <= (others => '0'); app_wdata_mask <= (others => '1');
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
            if cpu_we = '1' then st <= S_CW_RDREQ;
            else                 st <= S_CR_REQ;
            end if;
          end if;

        -- line fetch: one BL8 burst (8 pixels) per request
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
          -- write the 8 pixel low-bytes of the burst, one per cycle
          lbuf(to_integer(unsigned'('0' & cur_half)) * LINE_PIX + col + store_idx)
            <= fill_data(store_idx*8 + 7 downto store_idx*8);
          if store_idx = 7 then
            if col + 8 >= LINE_PIX then
              half_line(to_integer(unsigned'('0' & cur_half)))  <= cur_line;
              half_valid(to_integer(unsigned'('0' & cur_half))) <= '1';
              st <= S_IDLE;
            else
              col <= col + 8;
              st <= S_FILL_REQ;
            end if;
          else
            store_idx <= store_idx + 1;
          end if;

        -- CPU pixel write (read-modify-write): read the 8-word burst ...
        when S_CW_RDREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CW_RDWAIT;
          end if;
        -- ... replace the one target low byte, keep the rest ...
        when S_CW_RDWAIT =>
          if app_rdata_valid = '1' then
            ln := cpu_lane;
            cw_data <= app_rdata;
            cw_data(ln*8 + 7 downto ln*8) <= cpu_op_din;
            st <= S_CW_WRREQ;
          end if;
        -- ... and write the whole burst back. Command and data are DECOUPLED:
        -- issue the WRITE command on cmd_rdy, then present the 64-bit data when
        -- the IP raises wr_data_rdy. Requiring both ready in one cycle deadlocks
        -- if wr_data_rdy only rises after the command (then the watchdog acks the
        -- CPU but nothing is ever written -> reads stay decoupled from writes).
        when S_CW_WRREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_WRITE;
            app_cmd_en <= '1';
            st <= S_CW_WRDATA;
          end if;
        when S_CW_WRDATA =>
          if app_wdata_rdy = '1' then
            app_wdata      <= cw_data;
            app_wdata_mask <= (others => '0');   -- write all bytes (Sipeed style)
            app_wren       <= '1';
            app_wdata_end  <= '1';
            -- a write to a cached line invalidates that half
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

        -- CPU pixel read: read the burst, extract the word lane's low byte
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
