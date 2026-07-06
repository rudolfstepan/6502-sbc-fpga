-- ============================================================================
-- usb_host_seq -- Stage 2a: bring up the host, reset+detect the device, then
-- control-read GET_DESCRIPTOR(DEVICE, 18) on EP0.
--
-- Observability first: a separate always-on printer emits a status line ~2x/sec
--   Pp Ee Rrr: bb bb bb ...        (p=phase, e=error flag, rr=last handshake/
--                                   data PID, then the 18 descriptor bytes hex)
-- Phase codes: 1 bring-up  2 wait-detect  3 setup  4 in-data  5 status  6 done.
-- So even when enumeration stalls you can see WHERE it stalls and WHAT the device
-- answered (e.g. P4 E1 R5A = stuck on the IN stage, device keeps NAKing).
--
-- Register-level protocol per ultraembedded usb_hw.c / usb_core.c. 60 MHz domain.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_host_seq is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;

    rq_valid  : out std_logic;
    rq_we     : out std_logic;
    rq_addr   : out std_logic_vector(7 downto 0);
    rq_wdata  : out std_logic_vector(31 downto 0);
    rq_done   : in  std_logic;
    rq_rdata  : in  std_logic_vector(31 downto 0);

    tx_data   : out std_logic_vector(7 downto 0);
    tx_valid  : out std_logic;
    tx_busy   : in  std_logic;

    -- wrapper probes from the top, shown as four hex digits in the line:
    -- [15:12] STP pulse count  [11:8] NXT pulse count  [7:4] txready pulse count
    -- [3:0] sticky flags: rxa-low / rxa-high / txr-high / dir-high
    -- The counters roll over; if SOFs are flowing they CHANGE between lines.
    dbg_in    : in  std_logic_vector(15 downto 0);

    dbg       : out std_logic_vector(3 downto 0)   -- [0]run [1]present [2]descok [3]err
  );
end entity;

architecture rtl of usb_host_seq is

  -- Build ID, printed at the start of every status line ("V7 ..."). Bump this
  -- on every design change so the terminal shows WHICH bitstream is running --
  -- ends the "is the new build actually flashed?" guessing.
  constant VERSION_CHAR : std_logic_vector(7 downto 0) := x"45";  -- 'E' (build 14, VBUS enable)

  constant R_CTRL   : std_logic_vector(7 downto 0) := x"00";
  constant R_STATUS : std_logic_vector(7 downto 0) := x"04";
  constant R_XDATA  : std_logic_vector(7 downto 0) := x"14";
  constant R_XTOKEN : std_logic_vector(7 downto 0) := x"18";
  constant R_RXSTAT : std_logic_vector(7 downto 0) := x"1C";
  constant R_WRDATA : std_logic_vector(7 downto 0) := x"20";
  constant R_RDDATA : std_logic_vector(7 downto 0) := x"20";

  constant C_SE0  : std_logic_vector(31 downto 0) := x"000000C4";
  -- USB_CTRL host-enable, full-speed (XcvrSelect=01). LS (0x1F0/0x1F1) was
  -- tried and ruled out: the device reads SE0 in LS mode -> it is full-speed.
  -- The host core's USB_CTRL now also RESETS to FS host config (patched
  -- defaults in usbh_host_defs.v) so the PHY never transiently enters HS mode.
  constant C_HOST : std_logic_vector(31 downto 0) := x"000001E8";
  constant C_SOF  : std_logic_vector(31 downto 0) := x"000001E9";

  constant T_SETUP  : std_logic_vector(31 downto 0) := x"A02D0000";
  constant T_IN     : std_logic_vector(31 downto 0) := x"E0690000";
  constant T_OUT_D1 : std_logic_vector(31 downto 0) := x"B0E10000";

  constant PID_ACK   : std_logic_vector(7 downto 0) := x"D2";
  constant PID_NAK   : std_logic_vector(7 downto 0) := x"5A";
  constant PID_DATA0 : std_logic_vector(7 downto 0) := x"C3";
  constant PID_DATA1 : std_logic_vector(7 downto 0) := x"4B";

  constant D_3MS  : integer := 180_000;
  constant D_20MS : integer := 1_200_000;
  constant D_1S   : integer := 60_000_000;

  type state_t is (
    S_RESET,
    B_EN, B_DLY1, B_DET, B_DETC, B_SE0, B_DLYR, B_SOF, B_DLYS,
    SU_WRB, SU_LEN, SU_TOK, SU_P1, SU_P1C, SU_P2, SU_P2C, SU_CHK,
    IN_LEN, IN_TOK, IN_P1, IN_P1C, IN_P2, IN_P2C, IN_CHK, IN_RD, IN_STORE,
    ST_LEN, ST_TOK, ST_P1, ST_P1C, ST_P2, ST_P2C, ST_CHK,
    W_DLY, S_ERR, S_REGWAIT
  );
  signal st, ret_st : state_t := S_RESET;

  signal rq_valid_r : std_logic := '0';
  signal rq_we_r    : std_logic := '0';
  signal rq_addr_r  : std_logic_vector(7 downto 0)  := (others => '0');
  signal rq_wdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rd     : std_logic_vector(31 downto 0) := (others => '0');

  signal dly     : unsigned(25 downto 0) := (others => '0');
  signal bcnt    : integer range 0 to 31 := 0;
  signal rxtot   : integer range 0 to 31 := 0;
  signal rxcnt   : integer range 0 to 31 := 0;
  signal nak_cnt : integer range 0 to 1023 := 0;
  -- poll watchdog: no single transaction may take longer than ~10 ms; if a
  -- START_PEND/IDLE poll loop exceeds this, give up and retry (S_ERR).
  signal ptmo    : unsigned(19 downto 0) := (others => '0');
  constant PTMO_MAX : unsigned(19 downto 0) := to_unsigned(600_000, 20); -- 10ms

  type buf_t is array(0 to 17) of std_logic_vector(7 downto 0);
  signal rx_buf : buf_t := (others => (others => '0'));

  -- shared status (main FSM -> printer)
  signal r_phase   : std_logic_vector(3 downto 0) := (others => '0');
  signal r_resp    : std_logic_vector(7 downto 0) := (others => '0');
  signal r_last    : std_logic_vector(31 downto 0) := (others => '0');  -- last reg read
  signal r_running : std_logic := '0';
  signal r_present : std_logic := '0';
  signal r_descok  : std_logic := '0';
  signal r_err     : std_logic := '0';

  -- printer
  signal tx_data_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid_r : std_logic := '0';
  signal ptmr       : unsigned(24 downto 0) := (others => '0');
  signal psend      : std_logic := '0';
  signal pidx       : integer range 0 to 63 := 0;

  function setup_byte(i : integer) return std_logic_vector is
  begin
    case i is
      when 0 => return x"80";
      when 1 => return x"06";
      when 2 => return x"00";
      when 3 => return x"01";
      when 4 => return x"00";
      when 5 => return x"00";
      when 6 => return x"12";
      when others => return x"00";
    end case;
  end function;

  function hexc(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : integer := to_integer(unsigned(n));
  begin
    if v < 10 then return std_logic_vector(to_unsigned(16#30# + v, 8));
    else            return std_logic_vector(to_unsigned(16#41# + v - 10, 8)); end if;
  end function;

begin
  rq_valid <= rq_valid_r;
  rq_we    <= rq_we_r;
  rq_addr  <= rq_addr_r;
  rq_wdata <= rq_wdata_r;
  tx_data  <= tx_data_r;
  tx_valid <= tx_valid_r;
  dbg      <= r_err & r_descok & r_present & r_running;

  -- ==========================================================================
  -- Main sequencer (drives rq_*, updates status; does NOT touch the UART)
  -- ==========================================================================
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        st        <= S_RESET;
        rq_valid_r <= '0';
        dly <= (others=>'0'); bcnt <= 0; rxtot <= 0; rxcnt <= 0; nak_cnt <= 0;
        ptmo <= (others=>'0');
        r_phase <= x"0"; r_resp <= x"00";
        r_running <= '0'; r_present <= '0'; r_descok <= '0'; r_err <= '0';
      else
        -- poll watchdog: free-running, zeroed whenever a transaction starts
        if ptmo /= PTMO_MAX then
          ptmo <= ptmo + 1;
        end if;

        case st is

          when S_REGWAIT =>
            if rq_done = '1' then
              rq_valid_r <= '0';
              reg_rd     <= rq_rdata;
              r_last     <= rq_rdata;      -- expose last reg value for diagnostics
              st         <= ret_st;
            end if;

          when S_RESET =>
            st <= B_EN;

          -- ---- host bring-up ----
          when B_EN =>
            r_phase <= x"1";
            rq_we_r <= '1'; rq_addr_r <= R_CTRL; rq_wdata_r <= C_HOST;
            rq_valid_r <= '1'; ret_st <= B_DLY1; st <= S_REGWAIT;
          when B_DLY1 =>
            r_running <= '1';
            if dly = to_unsigned(D_3MS, dly'length) then dly <= (others=>'0'); st <= B_DET;
            else dly <= dly + 1; end if;
          when B_DET =>
            r_phase <= x"2";
            rq_we_r <= '0'; rq_addr_r <= R_STATUS;
            rq_valid_r <= '1'; ret_st <= B_DETC; st <= S_REGWAIT;
          when B_DETC =>
            if reg_rd(1 downto 0) /= "00" then r_present <= '1'; st <= B_SE0;
            else st <= B_DET; end if;
          when B_SE0 =>
            rq_we_r <= '1'; rq_addr_r <= R_CTRL; rq_wdata_r <= C_SE0;
            rq_valid_r <= '1'; ret_st <= B_DLYR; st <= S_REGWAIT;
          when B_DLYR =>
            if dly = to_unsigned(D_20MS, dly'length) then dly <= (others=>'0'); st <= B_SOF;
            else dly <= dly + 1; end if;
          when B_SOF =>
            rq_we_r <= '1'; rq_addr_r <= R_CTRL; rq_wdata_r <= C_SOF;
            rq_valid_r <= '1'; ret_st <= B_DLYS; st <= S_REGWAIT;
          when B_DLYS =>
            if dly = to_unsigned(D_20MS, dly'length) then
              dly <= (others=>'0'); bcnt <= 0; st <= SU_WRB;
            else dly <= dly + 1; end if;

          -- ---- SETUP stage ----
          when SU_WRB =>
            r_phase <= x"3";
            if bcnt = 8 then st <= SU_LEN;
            else
              rq_we_r <= '1'; rq_addr_r <= R_WRDATA;
              rq_wdata_r <= x"000000" & setup_byte(bcnt);
              bcnt <= bcnt + 1; rq_valid_r <= '1'; ret_st <= SU_WRB; st <= S_REGWAIT;
            end if;
          when SU_LEN =>
            rq_we_r <= '1'; rq_addr_r <= R_XDATA; rq_wdata_r <= x"00000008";
            rq_valid_r <= '1'; ret_st <= SU_TOK; st <= S_REGWAIT;
          when SU_TOK =>
            rq_we_r <= '1'; rq_addr_r <= R_XTOKEN; rq_wdata_r <= T_SETUP;
            ptmo <= (others=>'0');
            rq_valid_r <= '1'; ret_st <= SU_P1; st <= S_REGWAIT;
          when SU_P1 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= SU_P1C; st <= S_REGWAIT;
          when SU_P1C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(31) = '1' then st <= SU_P1; else st <= SU_P2; end if;
          when SU_P2 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= SU_P2C; st <= S_REGWAIT;
          when SU_P2C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(28) = '0' then st <= SU_P2; else st <= SU_CHK; end if;
          when SU_CHK =>
            r_resp <= reg_rd(23 downto 16);
            if reg_rd(29) = '1' then st <= S_ERR;
            elsif reg_rd(23 downto 16) = PID_ACK then
              rxtot <= 0; nak_cnt <= 0; st <= IN_LEN;
            else st <= S_ERR; end if;

          -- ---- IN data stage ----
          when IN_LEN =>
            r_phase <= x"4";
            rq_we_r <= '1'; rq_addr_r <= R_XDATA; rq_wdata_r <= x"00000000";
            rq_valid_r <= '1'; ret_st <= IN_TOK; st <= S_REGWAIT;
          when IN_TOK =>
            rq_we_r <= '1'; rq_addr_r <= R_XTOKEN; rq_wdata_r <= T_IN;
            ptmo <= (others=>'0');
            rq_valid_r <= '1'; ret_st <= IN_P1; st <= S_REGWAIT;
          when IN_P1 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= IN_P1C; st <= S_REGWAIT;
          when IN_P1C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(31) = '1' then st <= IN_P1; else st <= IN_P2; end if;
          when IN_P2 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= IN_P2C; st <= S_REGWAIT;
          when IN_P2C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(28) = '0' then st <= IN_P2; else st <= IN_CHK; end if;
          when IN_CHK =>
            r_resp <= reg_rd(23 downto 16);
            if reg_rd(30) = '1' or reg_rd(29) = '1' then st <= S_ERR;
            elsif reg_rd(23 downto 16) = PID_NAK then
              if nak_cnt = 1000 then st <= S_ERR;
              else nak_cnt <= nak_cnt + 1; st <= IN_LEN; end if;
            elsif reg_rd(23 downto 16) = PID_DATA0 or reg_rd(23 downto 16) = PID_DATA1 then
              rxcnt <= to_integer(unsigned(reg_rd(4 downto 0)));
              bcnt  <= 0; st <= IN_RD;
            else st <= S_ERR; end if;
          when IN_RD =>
            if bcnt = rxcnt then
              rxtot <= rxtot + rxcnt;
              if rxcnt < 8 or (rxtot + rxcnt) >= 18 then
                nak_cnt <= 0; st <= ST_LEN;
              else
                nak_cnt <= 0; st <= IN_LEN;
              end if;
            else
              rq_we_r <= '0'; rq_addr_r <= R_RDDATA;
              rq_valid_r <= '1'; ret_st <= IN_STORE; st <= S_REGWAIT;
            end if;
          when IN_STORE =>
            if (rxtot + bcnt) <= 17 then rx_buf(rxtot + bcnt) <= reg_rd(7 downto 0); end if;
            bcnt <= bcnt + 1;
            st   <= IN_RD;

          -- ---- OUT status stage (ZLP, DATA1) ----
          when ST_LEN =>
            r_phase <= x"5";
            rq_we_r <= '1'; rq_addr_r <= R_XDATA; rq_wdata_r <= x"00000000";
            rq_valid_r <= '1'; ret_st <= ST_TOK; st <= S_REGWAIT;
          when ST_TOK =>
            rq_we_r <= '1'; rq_addr_r <= R_XTOKEN; rq_wdata_r <= T_OUT_D1;
            ptmo <= (others=>'0');
            rq_valid_r <= '1'; ret_st <= ST_P1; st <= S_REGWAIT;
          when ST_P1 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= ST_P1C; st <= S_REGWAIT;
          when ST_P1C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(31) = '1' then st <= ST_P1; else st <= ST_P2; end if;
          when ST_P2 =>
            rq_we_r <= '0'; rq_addr_r <= R_RXSTAT;
            rq_valid_r <= '1'; ret_st <= ST_P2C; st <= S_REGWAIT;
          when ST_P2C =>
            if ptmo = PTMO_MAX then dly <= (others=>'0'); st <= S_ERR;
            elsif reg_rd(28) = '0' then st <= ST_P2; else st <= ST_CHK; end if;
          when ST_CHK =>
            r_phase <= x"6"; r_descok <= '1';
            dly <= (others=>'0'); st <= W_DLY;

          when W_DLY =>
            if dly = to_unsigned(D_1S, dly'length) then
              dly <= (others=>'0'); bcnt <= 0; st <= SU_WRB;   -- re-read
            else dly <= dly + 1; end if;

          when S_ERR =>
            r_err <= '1';
            if dly = to_unsigned(D_1S, dly'length) then
              dly <= (others=>'0'); r_err <= '0'; bcnt <= 0; st <= SU_WRB;  -- retry
            else dly <= dly + 1; end if;

        end case;
      end if;
    end if;
  end process;

  -- ==========================================================================
  -- Diagnostic printer (owns the UART): ~2x/sec emit a status + descriptor line
  --   "Pp Ee Rrr: b0 b1 .. b17\r\n"
  -- ==========================================================================
  process(clk)
    variable ki   : integer;
    variable bidx : integer;
    variable ch   : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      tx_valid_r <= '0';
      if reset_n = '0' then
        psend <= '0'; pidx <= 0; ptmr <= (others=>'0');
      else
        if ptmr = to_unsigned(30_000_000, ptmr'length) then
          ptmr <= (others=>'0');
          if psend = '0' then psend <= '1'; pidx <= 0; end if;
        else
          ptmr <= ptmr + 1;
        end if;

        if psend = '1' then
          if tx_busy = '0' and tx_valid_r = '0' then
            case pidx is
              when 0 => ch := x"56";                       -- 'V' (build id)
              when 1 => ch := VERSION_CHAR;
              when 2 => ch := x"20";                       -- ' '
              when 3 => ch := x"50";                       -- 'P'
              when 4 => ch := hexc(r_phase);
              when 5 => ch := x"20";                       -- ' '
              when 6 => ch := x"45";                       -- 'E'
              when 7 => if r_err = '1' then ch := x"31"; else ch := x"30"; end if;
              when 8 => ch := x"20";                       -- ' '
              when 9  => ch := x"53";                      -- 'S' (raw RX_STAT)
              when 10 => ch := hexc(r_last(31 downto 28));
              when 11 => ch := hexc(r_last(27 downto 24));
              when 12 => ch := hexc(r_last(23 downto 20));
              when 13 => ch := hexc(r_last(19 downto 16));
              when 14 => ch := hexc(r_last(15 downto 12));
              when 15 => ch := hexc(r_last(11 downto 8));
              when 16 => ch := hexc(r_last(7 downto 4));
              when 17 => ch := hexc(r_last(3 downto 0));
              when 18 => ch := x"20";                      -- ' '
              when 19 => ch := x"46";                      -- 'F' (probes)
              when 20 => ch := hexc(dbg_in(15 downto 12)); -- STP count
              when 21 => ch := hexc(dbg_in(11 downto 8));  -- NXT count
              when 22 => ch := hexc(dbg_in(7 downto 4));   -- txready count
              when 23 => ch := hexc(dbg_in(3 downto 0));   -- sticky flags
              when 24 => ch := x"3A";                      -- ':'
              when 61 => ch := x"0D";                      -- CR
              when 62 => ch := x"0A";                      -- LF
              when others =>                               -- 25..60 : 18 bytes hex
                ki   := pidx - 25;
                bidx := ki / 2;
                if (ki mod 2) = 0 then ch := hexc(rx_buf(bidx)(7 downto 4));
                else                   ch := hexc(rx_buf(bidx)(3 downto 0)); end if;
            end case;
            tx_data_r  <= ch;
            tx_valid_r <= '1';
            if pidx = 62 then psend <= '0';
            else pidx <= pidx + 1; end if;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
