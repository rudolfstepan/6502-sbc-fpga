-- DDR3 backend for the sys16 HDMI framebuffer "graphics card".
--
-- Replaces the four BSRAM byte banks of sys16_hdmi_fb: the pixel data
-- lives in the on-board DDR3 behind the Gowin DDR3 Memory Interface IP;
-- on-chip remains only a double line buffer (2 x 240 words). Three
-- clock domains:
--   clk_bus (50 MHz)    CPU word port, driven by the sys16_hdmi_fb bus FSM
--   clk_x1  (100 MHz)   DDR3 IP app interface (the IP's clk_out)
--   clk_pix (74.25 MHz) line-buffer reads and prefetch requests
-- Every crossing is a toggle handshake through a 3-stage synchroniser
-- (the pattern proven in ddr3_byte_bridge / vic_fb_ddr3); the payloads
-- next to the toggles are quasi-static while the handshake runs.
--
-- The app-interface usage copies the 138K SBC port of vic_fb_ddr3:
-- 128-bit beats (the board top masks the upper half of the 32-bit IP's
-- 256-bit beat), BL8 = 16-byte bursts, CMD 000 write / 001 read. CPU
-- writes are MASKED single-burst writes -- no read-modify-write, so a
-- marginal DDR3 read can never smear neighbour bytes. A line fetch
-- reads LINE_WORDS/4 bursts back to back, one outstanding at a time.
--
-- CPU port contract (clk_bus): cpu_req is a level, held together with
-- we/addr/be/wdata until cpu_ack pulses; cpu_req must be low during the
-- ack cycle (sys16_hdmi_fb gates it with "and not ack"), which makes a
-- back-to-back retrigger impossible. While the DDR3 is uncalibrated the
-- engine still acknowledges (writes dropped, reads return zeros) so a
-- stray access can never wedge the CPU's AXI fabric.
--
-- Scanout contract (clk_pix): line_req pulses at the start of a screen
-- line, two lines before the framebuffer line line_num is displayed;
-- line_num stays stable until the next request (>= 2 scan lines). The
-- fetch fills buffer half line_num(0); rd_addr = half & word-in-line
-- reads with the same 2-cycle latency as sys16_fb_ram8 port B, so the
-- sys16_hdmi_fb fetch pipeline alignment is unchanged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_fb_ddr3 is
  generic (
    LINE_WORDS    : natural  := 240;  -- 32-bit words per framebuffer line
    NUM_LINES     : natural  := 270;
    APP_ADDR_BITS : positive := 27    -- 16-bit-word address width (SBC scheme)
  );
  port (
    -- CPU side (clk_bus)
    clk_bus   : in  std_logic;
    rst_bus_n : in  std_logic;
    cpu_req   : in  std_logic;
    cpu_we    : in  std_logic;
    cpu_addr  : in  std_logic_vector(16 downto 0);  -- 32-bit word index
    cpu_be    : in  std_logic_vector(3 downto 0);
    cpu_wdata : in  std_logic_vector(31 downto 0);
    cpu_rdata : out std_logic_vector(31 downto 0);
    cpu_ack   : out std_logic;                      -- 1-cycle pulse
    calib_bus : out std_logic;                      -- calib_done, bus view
    -- scanout side (clk_pix)
    clk_pix   : in  std_logic;
    rst_pix_n : in  std_logic;
    line_req  : in  std_logic;                      -- 1-cycle pulse
    line_num  : in  std_logic_vector(8 downto 0);   -- fb line to prefetch
    rd_addr   : in  std_logic_vector(8 downto 0);   -- half & word-in-line
    rd_data   : out std_logic_vector(31 downto 0);
    -- DDR3 IP app interface, 128-bit view (clk_x1)
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

architecture rtl of sys16_fb_ddr3 is

  constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
  constant CMD_READ  : std_logic_vector(2 downto 0) := "001";
  constant BURSTS_PL : natural := LINE_WORDS / 4;     -- 16-byte bursts/line
  constant LINE_BYTES: natural := LINE_WORDS * 4;

  -- Double line buffer: half select in bit 8, word-in-line below. Dual
  -- clock (write clk_x1, registered read clk_pix), same inference trick
  -- as sys16_fb_ram8 / vic_fb_ddr3's lbuf.
  type lbuf_t is array (0 to 511) of std_logic_vector(31 downto 0);
  signal lbuf : lbuf_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of lbuf : signal is "block";

  -- clk_bus domain
  signal start_tgl_bus : std_logic := '0';
  signal busy_bus      : std_logic := '0';
  signal ack_sync      : std_logic_vector(2 downto 0) := (others => '0');
  signal calib_sync    : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal cpu_ack_r     : std_logic := '0';

  -- clk_pix domain
  signal line_tgl_pix  : std_logic := '0';
  signal rd_addr_q     : std_logic_vector(8 downto 0) := (others => '0');
  signal rd_data_r     : std_logic_vector(31 downto 0) := (others => '0');

  -- clk_x1 domain
  type st_t is (S_CALIB, S_IDLE,
                S_FILL_REQ, S_FILL_WAIT, S_FILL_STORE,
                S_CW_REQ, S_CW_DATA, S_CR_REQ, S_CR_WAIT);
  signal st          : st_t := S_CALIB;
  signal start_sync  : std_logic_vector(2 downto 0) := (others => '0');
  signal line_sync   : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_pending : std_logic := '0';
  signal fill_pending: std_logic := '0';
  signal op_we       : std_logic := '0';
  signal op_addr     : std_logic_vector(16 downto 0) := (others => '0');
  signal op_be       : std_logic_vector(3 downto 0) := (others => '0');
  signal op_wdata    : std_logic_vector(31 downto 0) := (others => '0');
  signal fill_line   : std_logic_vector(8 downto 0) := (others => '0');
  signal cur_half    : std_logic := '0';
  signal line_base   : unsigned(24 downto 0) := (others => '0');
  signal col         : natural range 0 to BURSTS_PL := 0;
  signal store_idx   : natural range 0 to 3 := 0;
  signal fill_data   : std_logic_vector(127 downto 0) := (others => '0');
  signal ack_tgl_x1  : std_logic := '0';
  signal cpu_dout_x1 : std_logic_vector(31 downto 0) := (others => '0');
  signal wd_cnt      : unsigned(13 downto 0) := (others => '0');

  -- app word address (16-bit words) of the 16-byte burst holding byteoff
  function beat_addr(byteoff : unsigned(24 downto 0)) return std_logic_vector is
    variable w : unsigned(23 downto 0);
  begin
    w := byteoff(24 downto 4) & "000";
    return std_logic_vector(resize(w, APP_ADDR_BITS));
  end function;

begin

  cpu_ack   <= cpu_ack_r;
  cpu_rdata <= cpu_rdata_r;
  calib_bus <= calib_sync(2);
  rd_data   <= rd_data_r;

  -- clk_bus: request toggle out, ack toggle in. cpu_dout_x1 is stable
  -- when the ack edge arrives (written before the toggle flips).
  bus_p : process(clk_bus)
  begin
    if rising_edge(clk_bus) then
      if rst_bus_n = '0' then
        start_tgl_bus <= '0';
        busy_bus      <= '0';
        ack_sync      <= (others => '0');
        calib_sync    <= (others => '0');
        cpu_ack_r     <= '0';
        cpu_rdata_r   <= (others => '0');
      else
        cpu_ack_r  <= '0';
        ack_sync   <= ack_sync(1 downto 0) & ack_tgl_x1;
        calib_sync <= calib_sync(1 downto 0) & calib_done;
        if busy_bus = '0' then
          -- The ack-cycle guard closes the retrigger race for clients
          -- that hold cpu_req one cycle into the ack (the bus FSM in
          -- sys16_hdmi_fb additionally gates its request with the ack).
          if cpu_req = '1' and cpu_ack_r = '0' then
            start_tgl_bus <= not start_tgl_bus;
            busy_bus      <= '1';
          end if;
        elsif ack_sync(2) /= ack_sync(1) then
          cpu_rdata_r <= cpu_dout_x1;
          cpu_ack_r   <= '1';
          busy_bus    <= '0';
        end if;
      end if;
    end if;
  end process;

  -- clk_pix: prefetch toggle out, registered line-buffer read (address
  -- register + output register = the sys16_fb_ram8 port-B latency).
  pix_p : process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if rst_pix_n = '0' then
        line_tgl_pix <= '0';
      elsif line_req = '1' then
        line_tgl_pix <= not line_tgl_pix;
      end if;
      rd_addr_q <= rd_addr;
      rd_data_r <= lbuf(to_integer(unsigned(rd_addr_q)));
    end if;
  end process;

  -- clk_x1: app-interface engine. One request in flight at a time; the
  -- line fetch outranks the CPU (it has a display deadline, the CPU op
  -- is retried by the AXI bridge and guarded by the watchdog below).
  x1_p : process(clk_x1, rst_bus_n)
    variable byteoff : unsigned(24 downto 0);
    variable wl      : natural range 0 to 3;
    variable bi      : natural range 0 to 511;
    variable m       : std_logic_vector(15 downto 0);
    variable wd      : std_logic_vector(127 downto 0);
  begin
    if rst_bus_n = '0' then
      st <= S_CALIB;
      start_sync <= (others => '0');
      line_sync  <= (others => '0');
      cpu_pending <= '0'; fill_pending <= '0';
      op_we <= '0'; op_addr <= (others => '0');
      op_be <= (others => '0'); op_wdata <= (others => '0');
      fill_line <= (others => '0'); cur_half <= '0';
      line_base <= (others => '0'); col <= 0; store_idx <= 0;
      fill_data <= (others => '0');
      ack_tgl_x1 <= '0'; cpu_dout_x1 <= (others => '0');
      wd_cnt <= (others => '0');
      app_cmd <= CMD_READ; app_cmd_en <= '0';
      app_addr <= (others => '0');
      app_wdata <= (others => '0'); app_wdata_mask <= (others => '0');
      app_wren <= '0'; app_wdata_end <= '0';
    elsif rising_edge(clk_x1) then
      app_cmd_en <= '0'; app_wren <= '0'; app_wdata_end <= '0';

      start_sync <= start_sync(1 downto 0) & start_tgl_bus;
      line_sync  <= line_sync(1 downto 0)  & line_tgl_pix;

      if start_sync(2) /= start_sync(1) then
        cpu_pending <= '1';
      end if;
      if line_sync(2) /= line_sync(1) then
        -- line_num is quasi-static around the toggle (held >= 2 scan lines)
        fill_line    <= line_num;
        fill_pending <= '1';
      end if;

      if st = S_IDLE or st = S_CALIB then
        wd_cnt <= (others => '0');
      else
        wd_cnt <= wd_cnt + 1;
      end if;

      case st is
        when S_CALIB =>
          -- Never wedge the AXI fabric: acknowledge CPU ops even while
          -- the DDR3 is (re)calibrating. Writes are dropped, reads zero.
          if cpu_pending = '1' then
            cpu_dout_x1 <= (others => '0');
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
          end if;
          if calib_done = '1' then
            st <= S_IDLE;
          end if;

        when S_IDLE =>
          if fill_pending = '1' then
            fill_pending <= '0';
            cur_half  <= fill_line(0);
            line_base <= to_unsigned(
                           to_integer(unsigned(fill_line)) * LINE_BYTES, 25);
            col <= 0;
            st  <= S_FILL_REQ;
          elsif cpu_pending = '1' then
            -- The bus FSM holds we/addr/be/wdata stable until the ack.
            op_we    <= cpu_we;
            op_addr  <= cpu_addr;
            op_be    <= cpu_be;
            op_wdata <= cpu_wdata;
            if cpu_we = '1' then
              st <= S_CW_REQ;
            else
              st <= S_CR_REQ;
            end if;
          end if;

        -- line fetch: BURSTS_PL BL8 bursts, one outstanding at a time
        when S_FILL_REQ =>
          if app_cmd_rdy = '1' then
            byteoff := line_base + shift_left(to_unsigned(col, 25), 4);
            app_addr   <= beat_addr(byteoff);
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
          bi := col * 4 + store_idx;
          if cur_half = '1' then
            bi := bi + 256;
          end if;
          lbuf(bi) <= fill_data(store_idx*32 + 31 downto store_idx*32);
          if store_idx = 3 then
            if col + 1 = BURSTS_PL then
              st <= S_IDLE;
            else
              col <= col + 1;
              st  <= S_FILL_REQ;
            end if;
          else
            store_idx <= store_idx + 1;
          end if;

        -- CPU word write: one masked burst, only the be-selected bytes
        -- of the addressed word land in memory (no read-modify-write)
        when S_CW_REQ =>
          if app_cmd_rdy = '1' then
            byteoff := resize(unsigned(op_addr) & "00", 25);
            app_addr   <= beat_addr(byteoff);
            app_cmd    <= CMD_WRITE;
            app_cmd_en <= '1';
            st <= S_CW_DATA;
          end if;
        when S_CW_DATA =>
          if app_wdata_rdy = '1' then
            wl := to_integer(unsigned(op_addr(1 downto 0)));
            wd := (others => '0');
            wd(wl*32 + 31 downto wl*32) := op_wdata;
            m  := (others => '1');
            for i in 0 to 3 loop
              m(wl*4 + i) := not op_be(i);
            end loop;
            app_wdata      <= wd;
            app_wdata_mask <= m;
            app_wren       <= '1';
            app_wdata_end  <= '1';
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;

        -- CPU word read: read the burst, extract the addressed word
        when S_CR_REQ =>
          if app_cmd_rdy = '1' then
            byteoff := resize(unsigned(op_addr) & "00", 25);
            app_addr   <= beat_addr(byteoff);
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CR_WAIT;
          end if;
        when S_CR_WAIT =>
          if app_rdata_valid = '1' then
            wl := to_integer(unsigned(op_addr(1 downto 0)));
            cpu_dout_x1 <= app_rdata(wl*32 + 31 downto wl*32);
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;

        when others =>
          st <= S_IDLE;
      end case;

      -- watchdog: abort a stuck op so the CPU never hangs forever
      if wd_cnt = "11111111111111" and st /= S_IDLE and st /= S_CALIB then
        if st = S_CW_REQ or st = S_CW_DATA
           or st = S_CR_REQ or st = S_CR_WAIT then
          ack_tgl_x1  <= not ack_tgl_x1;
          cpu_pending <= '0';
        end if;
        st <= S_IDLE;
      end if;

      if calib_done = '0' then
        st <= S_CALIB;
      end if;
    end if;
  end process;

end architecture;
