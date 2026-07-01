-- virtual-1541 UART sector source for the Tang MiSTer C64 probe.
--
-- Same logical disk interface as c1541_d64_sector_source
--   track / sector / offset -> byte, plus `valid`
-- but the backend fetches each 256-byte sector on demand from the existing
-- tools/virtual_1541 PC GUI using its CMD_SECTOR request/response protocol.
-- No SDRAM, no host changes: MOUNT a .d64 in the GUI and it answers sectors.
--
-- Wire protocol (tools/virtual_1541/c64_1541_uart_gui.py):
--   request  (FPGA->PC): C6 30 02 00 <track> <sector> <cks>
--                        cks = (30 + 02 + 00 + track + sector) & FF
--   response (PC->FPGA): 64 30 <status> <len_lo> <len_hi> <payload..> <cks>
--                        cks = (30 + status + len_lo + len_hi + sum(payload)) & FF
--   a good sector has status=0 and len=256.
--
-- The 256-byte buffer is LUT RAM.  While a sector is being (re)fetched `valid`
-- is low, so c1541_static_dir_gcr freezes its bit clock and the fetch latency
-- (~11 ms/sector at 230400 baud) is hidden as a stretched inter-sector gap.
-- An inter-byte watchdog re-sends the request if a response stalls or is lost.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c1541_v1541_uart_sector_source is
  generic (
    CLK_HZ      : positive := 32_000_000;
    BAUD        : positive := 230_400;
    TIMEOUT_CYC : positive := 8_000_000   -- inter-byte stall before a re-request
  );
  port (
    clk     : in  std_logic;
    reset   : in  std_logic;                       -- synchronous, active-high

    track   : in  std_logic_vector(7 downto 0);    -- 1-based D64 track (1..35)
    sector  : in  std_logic_vector(4 downto 0);    -- 0-based sector
    offset  : in  std_logic_vector(7 downto 0);    -- 0..255 byte
    dout    : out std_logic_vector(7 downto 0);
    valid   : out std_logic;

    uart_rx : in  std_logic;
    uart_tx : out std_logic
  );
end entity;

architecture rtl of c1541_v1541_uart_sector_source is
  constant REQ_MAGIC  : std_logic_vector(7 downto 0) := x"C6";
  constant RESP_MAGIC : std_logic_vector(7 downto 0) := x"64";
  constant CMD_SECTOR : std_logic_vector(7 downto 0) := x"30";

  type buf_t is array(0 to 255) of std_logic_vector(7 downto 0);
  signal sec_buf : buf_t := (others => (others => '0'));

  type st_t is (SERVE, TX_ISSUE, TX_BUSY, TX_DRAIN,
                RX_MAGIC, RX_CMD, RX_STATUS, RX_LENLO, RX_LENHI, RX_DATA, RX_CKSUM);
  signal state : st_t := SERVE;

  signal loaded_track  : std_logic_vector(7 downto 0) := (others => '1');
  signal loaded_sector : std_logic_vector(4 downto 0) := (others => '1');
  signal fill_track    : std_logic_vector(7 downto 0) := (others => '0');
  signal fill_sector   : std_logic_vector(4 downto 0) := (others => '0');
  signal req_change    : std_logic;

  signal tx_idx   : integer range 0 to 6 := 0;
  signal r_status : std_logic_vector(7 downto 0) := (others => '0');
  signal r_len_lo : std_logic_vector(7 downto 0) := (others => '0');
  signal r_len    : integer range 0 to 65535 := 0;
  signal r_idx    : integer range 0 to 65535 := 0;
  signal acc      : unsigned(7 downto 0) := (others => '0');
  signal wd       : integer range 0 to TIMEOUT_CYC := 0;
  signal req_cks  : unsigned(7 downto 0);

  -- UART leaves
  signal rstn      : std_logic;
  signal urx_data  : std_logic_vector(7 downto 0);
  signal urx_valid : std_logic;
  signal utx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal utx_valid : std_logic := '0';
  signal utx_busy  : std_logic;

  function is_rx(s : st_t) return boolean is
  begin
    return s = RX_MAGIC or s = RX_CMD or s = RX_STATUS or s = RX_LENLO
        or s = RX_LENHI or s = RX_DATA or s = RX_CKSUM;
  end function;
begin
  rstn  <= not reset;
  dout  <= sec_buf(to_integer(unsigned(offset)));

  req_change <= '0' when (track = loaded_track and sector = loaded_sector) else '1';
  valid      <= '1' when (state = SERVE and req_change = '0') else '0';

  -- request checksum = (0x30 + 0x02 + 0x00 + track + sector) & 0xFF
  req_cks <= x"32" + unsigned(fill_track) + resize(unsigned(fill_sector), 8);

  rx_i : entity work.uart_rx_ser
    generic map ( CLK_HZ => CLK_HZ, BAUD => BAUD )
    port map ( clk => clk, reset_n => rstn, rx => uart_rx,
               data => urx_data, valid => urx_valid );

  tx_i : entity work.uart_tx_ser
    generic map ( CLK_HZ => CLK_HZ, BAUD => BAUD )
    port map ( clk => clk, reset_n => rstn, data => utx_data, valid => utx_valid,
               tx => uart_tx, busy => utx_busy );

  process(clk)
    variable v_len : integer range 0 to 65535;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state         <= SERVE;
        loaded_track  <= (others => '1');
        loaded_sector <= (others => '1');
        tx_idx        <= 0;
        utx_valid      <= '0';
        wd            <= 0;
        acc           <= (others => '0');
      else
        utx_valid <= '0';

        case state is
          when SERVE =>
            if req_change = '1' then
              fill_track  <= track;
              fill_sector <= sector;
              tx_idx      <= 0;
              state       <= TX_ISSUE;
            end if;

          -- ---- send the 7-byte CMD_SECTOR request ----
          when TX_ISSUE =>
            if utx_busy = '0' then
              case tx_idx is
                when 0 => utx_data <= REQ_MAGIC;
                when 1 => utx_data <= CMD_SECTOR;
                when 2 => utx_data <= x"02";
                when 3 => utx_data <= x"00";
                when 4 => utx_data <= fill_track;
                when 5 => utx_data <= "000" & fill_sector;
                when others => utx_data <= std_logic_vector(req_cks);
              end case;
              utx_valid <= '1';
              state    <= TX_BUSY;
            end if;

          when TX_BUSY =>
            if utx_busy = '1' then
              state <= TX_DRAIN;
            end if;

          when TX_DRAIN =>
            if utx_busy = '0' then
              if tx_idx = 6 then
                wd    <= 0;
                state <= RX_MAGIC;
              else
                tx_idx <= tx_idx + 1;
                state  <= TX_ISSUE;
              end if;
            end if;

          -- ---- parse the response frame ----
          when RX_MAGIC =>
            if urx_valid = '1' and urx_data = RESP_MAGIC then
              state <= RX_CMD;
            end if;

          when RX_CMD =>
            if urx_valid = '1' then
              if urx_data = CMD_SECTOR then
                acc   <= unsigned(CMD_SECTOR);
                state <= RX_STATUS;
              else
                state <= RX_MAGIC;      -- resync
              end if;
            end if;

          when RX_STATUS =>
            if urx_valid = '1' then
              r_status <= urx_data;
              acc      <= acc + unsigned(urx_data);
              state    <= RX_LENLO;
            end if;

          when RX_LENLO =>
            if urx_valid = '1' then
              r_len_lo <= urx_data;
              acc      <= acc + unsigned(urx_data);
              state    <= RX_LENHI;
            end if;

          when RX_LENHI =>
            if urx_valid = '1' then
              v_len := to_integer(unsigned(urx_data)) * 256
                       + to_integer(unsigned(r_len_lo));
              r_len <= v_len;
              acc   <= acc + unsigned(urx_data);
              r_idx <= 0;
              if v_len = 0 then
                state <= RX_CKSUM;
              else
                state <= RX_DATA;
              end if;
            end if;

          when RX_DATA =>
            if urx_valid = '1' then
              if r_idx < 256 then
                sec_buf(r_idx) <= urx_data;
              end if;
              acc <= acc + unsigned(urx_data);
              if r_idx = r_len - 1 then
                state <= RX_CKSUM;
              else
                r_idx <= r_idx + 1;
              end if;
            end if;

          when RX_CKSUM =>
            if urx_valid = '1' then
              if unsigned(urx_data) = acc and r_status = x"00" and r_len = 256 then
                loaded_track  <= fill_track;
                loaded_sector <= fill_sector;
                state         <= SERVE;
              else
                tx_idx <= 0;            -- bad frame: re-request
                state  <= TX_ISSUE;
              end if;
            end if;
        end case;

        -- Inter-byte watchdog over the whole RX phase: a stalled/lost response
        -- re-issues the request instead of hanging the drive forever.
        if is_rx(state) then
          if urx_valid = '1' then
            wd <= 0;
          elsif wd = TIMEOUT_CYC then
            wd     <= 0;
            tx_idx <= 0;
            state  <= TX_ISSUE;
          else
            wd <= wd + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
