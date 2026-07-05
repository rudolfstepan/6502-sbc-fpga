library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Tang Primer 20K standalone 1541/D64 SD write selftest.
--
-- This intentionally avoids the C64 core and IEC bus.  It feeds a known GCR
-- data block into c1541_static_dir_gcr, lets c1541_sd_d64_sector_source flush
-- the decoded sector to the SD card, then reads the same D64 sector back and
-- compares it byte for byte.
--
-- Test target: packed D64 file at SD LBA 0, track 35 sector 0.
-- Use a disposable D64 image: this selftest overwrites that sector.
entity tang20k_c1541_selftest_top is
  port (
    clk_27mhz : in  std_logic;
    key       : in  std_logic_vector(0 downto 0);

    sd_dclk   : out std_logic;
    sd_ncs    : out std_logic;
    sd_mosi   : out std_logic;
    sd_miso   : in  std_logic;

    led       : out std_logic_vector(3 downto 0);

    uart_tx   : out std_logic;
    uart_rx   : in  std_logic
  );
end entity;

architecture rtl of tang20k_c1541_selftest_top is
  constant CLK_HZ : integer := 27_000_000;
  constant BAUD   : integer := 115_200;

  constant TEST_TRACK        : std_logic_vector(7 downto 0) := x"23"; -- 35
  constant TEST_TRACK_HALF   : std_logic_vector(6 downto 0) :=
    std_logic_vector(to_unsigned((35 - 1) * 2, 7));
  constant TEST_SECTOR       : std_logic_vector(4 downto 0) := "00000";
  constant RAW_SYNC_BYTES    : natural := 10;
  constant GCR_DATA_BYTES    : natural := 260; -- $07 + 256 data + cks + 2 gaps
  constant RAW_STREAM_BYTES  : natural := RAW_SYNC_BYTES + (GCR_DATA_BYTES * 10) / 8;

  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 268;
      SPI_HIGH_SPEED_DIV : integer := 8
    );
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      SD_nCS                 : out std_logic;
      SD_DCLK                : out std_logic;
      SD_MOSI                : out std_logic;
      SD_MISO                : in  std_logic;
      sd_init_done           : out std_logic;
      sd_sec_read            : in  std_logic;
      sd_sec_read_addr       : in  std_logic_vector(31 downto 0);
      sd_sec_read_data       : out std_logic_vector(7 downto 0);
      sd_sec_read_data_valid : out std_logic;
      sd_sec_read_end        : out std_logic;
      sd_sec_write           : in  std_logic;
      sd_sec_write_addr      : in  std_logic_vector(31 downto 0);
      sd_sec_write_data      : in  std_logic_vector(7 downto 0);
      sd_sec_write_data_req  : out std_logic;
      sd_sec_write_end       : out std_logic;
      debug_sec_state        : out std_logic_vector(4 downto 0);
      debug_cmd_state        : out std_logic_vector(3 downto 0);
      debug_cmd_error        : out std_logic
    );
  end component;

  type raw_rom_t is array (0 to RAW_STREAM_BYTES - 1) of std_logic_vector(7 downto 0);

  function pattern(i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 37 + 16#5A#) mod 256, 8));
  end function;

  function payload_checksum return std_logic_vector is
    variable c : std_logic_vector(7 downto 0) := (others => '0');
  begin
    for i in 0 to 255 loop
      if i = 0 then
        c := pattern(i);
      else
        c := c xor pattern(i);
      end if;
    end loop;
    return c;
  end function;

  constant PAYLOAD_CKS : std_logic_vector(7 downto 0) := payload_checksum;

  function gcr_encode(value : std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    case value is
      when x"0" => return "01010";
      when x"1" => return "11010";
      when x"2" => return "01001";
      when x"3" => return "11001";
      when x"4" => return "01110";
      when x"5" => return "11110";
      when x"6" => return "01101";
      when x"7" => return "11101";
      when x"8" => return "10010";
      when x"9" => return "10011";
      when x"A" => return "01011";
      when x"B" => return "11011";
      when x"C" => return "10110";
      when x"D" => return "10111";
      when x"E" => return "01111";
      when others => return "10101";
    end case;
  end function;

  function gcr_payload_byte(i : natural) return std_logic_vector is
  begin
    if i = 0 then
      return x"07";
    elsif i <= 256 then
      return pattern(i - 1);
    elsif i = 257 then
      return PAYLOAD_CKS;
    else
      return x"00";
    end if;
  end function;

  function gcr_stream_bit(pos : natural) return std_logic is
    variable byte_i : natural;
    variable bit_i  : natural;
    variable b      : std_logic_vector(7 downto 0);
    variable g      : std_logic_vector(4 downto 0);
  begin
    byte_i := pos / 10;
    bit_i  := pos mod 10;
    b := gcr_payload_byte(byte_i);
    if bit_i < 5 then
      g := gcr_encode(b(7 downto 4));
      return g(bit_i);
    else
      g := gcr_encode(b(3 downto 0));
      return g(bit_i - 5);
    end if;
  end function;

  function raw_stream_byte(i : natural) return std_logic_vector is
    variable r       : std_logic_vector(7 downto 0) := (others => '0');
    variable bit_pos : natural;
  begin
    if i < RAW_SYNC_BYTES then
      return x"FF";
    end if;

    for b in 0 to 7 loop
      bit_pos := ((i - RAW_SYNC_BYTES) * 8) + b;
      r(7 - b) := gcr_stream_bit(bit_pos);
    end loop;
    return r;
  end function;

  function init_raw_rom return raw_rom_t is
    variable r : raw_rom_t;
  begin
    for i in r'range loop
      r(i) := raw_stream_byte(i);
    end loop;
    return r;
  end function;

  function hex_char(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u : unsigned(3 downto 0);
  begin
    u := unsigned(n);
    if u < 10 then
      return std_logic_vector(to_unsigned(48 + to_integer(u), 8));
    end if;
    return std_logic_vector(to_unsigned(55 + to_integer(u), 8));
  end function;

  constant RAW_ROM : raw_rom_t := init_raw_rom;

  type test_state_t is (
    ST_WAIT_SD,
    ST_MOUNT,
    ST_START_WRITE,
    ST_WRITE,
    ST_WAIT_FLUSH_BUSY,
    ST_WAIT_FLUSH_DONE,
    ST_START_VERIFY,
    ST_WAIT_VALID,
    ST_VERIFY_SET,
    ST_VERIFY_CHECK,
    ST_PASS,
    ST_FAIL
  );

  type msg_t is (
    MSG_NONE,
    MSG_START,
    MSG_SD_OK,
    MSG_COMMIT,
    MSG_PASS,
    MSG_FAIL
  );

  function msg_len(m : msg_t) return natural is
  begin
    case m is
      when MSG_START  => return 16; -- "C1541 SELFTEST\r\n"
      when MSG_SD_OK  => return 7;  -- "SD OK\r\n"
      when MSG_COMMIT => return 14; -- "WRITE COMMIT\r\n"
      when MSG_PASS   => return 6;  -- "PASS\r\n"
      when MSG_FAIL   => return 10; -- "FAIL $xx\r\n"
      when others     => return 0;
    end case;
  end function;

  function msg_char(
    m : msg_t;
    pos : natural;
    code : std_logic_vector(7 downto 0))
    return std_logic_vector is
  begin
    case m is
      when MSG_START =>
        case pos is
          when 0 => return x"43"; -- C
          when 1 => return x"31"; -- 1
          when 2 => return x"35"; -- 5
          when 3 => return x"34"; -- 4
          when 4 => return x"31"; -- 1
          when 5 => return x"20";
          when 6 => return x"53"; -- S
          when 7 => return x"45"; -- E
          when 8 => return x"4C"; -- L
          when 9 => return x"46"; -- F
          when 10 => return x"54"; -- T
          when 11 => return x"45"; -- E
          when 12 => return x"53"; -- S
          when 13 => return x"54"; -- T
          when 14 => return x"0D";
          when others => return x"0A";
        end case;
      when MSG_SD_OK =>
        case pos is
          when 0 => return x"53"; -- S
          when 1 => return x"44"; -- D
          when 2 => return x"20";
          when 3 => return x"4F"; -- O
          when 4 => return x"4B"; -- K
          when 5 => return x"0D";
          when others => return x"0A";
        end case;
      when MSG_COMMIT =>
        case pos is
          when 0 => return x"57"; -- W
          when 1 => return x"52"; -- R
          when 2 => return x"49"; -- I
          when 3 => return x"54"; -- T
          when 4 => return x"45"; -- E
          when 5 => return x"20";
          when 6 => return x"43"; -- C
          when 7 => return x"4F"; -- O
          when 8 => return x"4D"; -- M
          when 9 => return x"4D"; -- M
          when 10 => return x"49"; -- I
          when 11 => return x"54"; -- T
          when 12 => return x"0D";
          when others => return x"0A";
        end case;
      when MSG_PASS =>
        case pos is
          when 0 => return x"50"; -- P
          when 1 => return x"41"; -- A
          when 2 => return x"53"; -- S
          when 3 => return x"53"; -- S
          when 4 => return x"0D";
          when others => return x"0A";
        end case;
      when MSG_FAIL =>
        case pos is
          when 0 => return x"46"; -- F
          when 1 => return x"41"; -- A
          when 2 => return x"49"; -- I
          when 3 => return x"4C"; -- L
          when 4 => return x"20";
          when 5 => return x"24";
          when 6 => return hex_char(code(7 downto 4));
          when 7 => return hex_char(code(3 downto 0));
          when 8 => return x"0D";
          when others => return x"0A";
        end case;
      when others =>
        return x"00";
    end case;
  end function;

  signal reset_sr : std_logic_vector(7 downto 0) := (others => '1');
  signal rst      : std_logic := '1';
  signal reset_n  : std_logic := '0';

  signal sd_init_done : std_logic;
  signal sd_read      : std_logic;
  signal sd_read_addr : std_logic_vector(31 downto 0);
  signal sd_read_data : std_logic_vector(7 downto 0);
  signal sd_read_valid : std_logic;
  signal sd_read_end : std_logic;
  signal sd_write      : std_logic;
  signal sd_write_addr : std_logic_vector(31 downto 0);
  signal sd_write_data : std_logic_vector(7 downto 0);
  signal sd_write_req  : std_logic;
  signal sd_write_end  : std_logic;
  signal sd_sec_state  : std_logic_vector(4 downto 0);
  signal sd_cmd_state  : std_logic_vector(3 downto 0);
  signal sd_cmd_error  : std_logic;

  signal gcr_din       : std_logic_vector(7 downto 0) := x"FF";
  signal gcr_dout      : std_logic_vector(7 downto 0);
  signal gcr_mode      : std_logic := '0';
  signal gcr_mtr       : std_logic := '0';
  signal gcr_sync_n    : std_logic;
  signal gcr_byte_n    : std_logic;
  signal gcr_byte_n_d  : std_logic := '1';
  signal gcr_wr_en     : std_logic;
  signal gcr_wr_data   : std_logic_vector(7 downto 0);
  signal gcr_wr_offset : std_logic_vector(7 downto 0);
  signal gcr_wr_commit : std_logic;
  signal gcr_wr_done   : std_logic;
  signal gcr_wr_ckerr  : std_logic;
  signal gcr_img_track : std_logic_vector(7 downto 0);
  signal gcr_img_sector : std_logic_vector(4 downto 0);
  signal gcr_img_offset : std_logic_vector(7 downto 0);

  signal src_track  : std_logic_vector(7 downto 0);
  signal src_sector : std_logic_vector(4 downto 0);
  signal src_offset : std_logic_vector(7 downto 0);
  signal src_dout   : std_logic_vector(7 downto 0);
  signal src_valid  : std_logic;
  signal src_wr_busy : std_logic;
  signal src_uart_tx : std_logic;
  signal source_from_gcr : std_logic := '1';
  signal mount_strobe : std_logic := '0';

  signal state : test_state_t := ST_WAIT_SD;
  signal raw_idx : unsigned(8 downto 0) := to_unsigned(1, 9);
  signal timeout : unsigned(27 downto 0) := (others => '0');
  signal verify_idx : unsigned(7 downto 0) := (others => '0');
  signal fail_code : std_logic_vector(7 downto 0) := x"00";
  signal blink_cnt : unsigned(23 downto 0) := (others => '0');

  signal uart_data  : std_logic_vector(7 downto 0) := x"00";
  signal uart_valid : std_logic := '0';
  signal uart_busy  : std_logic;
  signal uart_active : std_logic := '0';
  signal uart_msg : msg_t := MSG_NONE;
  signal uart_next_msg : msg_t := MSG_START;
  signal uart_pos : unsigned(4 downto 0) := (others => '0');
  signal uart_last_state : test_state_t := ST_WAIT_SD;

begin
  reset_n <= not rst;

  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      reset_sr <= reset_sr(reset_sr'high - 1 downto 0) & key(0);
      rst <= not reset_sr(reset_sr'high);
    end if;
  end process;

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 8
    )
    port map (
      clk                    => clk_27mhz,
      rst                    => rst,
      SD_nCS                 => sd_ncs,
      SD_DCLK                => sd_dclk,
      SD_MOSI                => sd_mosi,
      SD_MISO                => sd_miso,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_read,
      sd_sec_read_addr       => sd_read_addr,
      sd_sec_read_data       => sd_read_data,
      sd_sec_read_data_valid => sd_read_valid,
      sd_sec_read_end        => sd_read_end,
      sd_sec_write           => sd_write,
      sd_sec_write_addr      => sd_write_addr,
      sd_sec_write_data      => sd_write_data,
      sd_sec_write_data_req  => sd_write_req,
      sd_sec_write_end       => sd_write_end,
      debug_sec_state        => sd_sec_state,
      debug_cmd_state        => sd_cmd_state,
      debug_cmd_error        => sd_cmd_error
    );

  gcr_i : entity work.c1541_static_dir_gcr
    generic map (
      GCR_TURBO => 8
    )
    port map (
      clk    => clk_27mhz,
      ce     => '1',
      reset  => rst,
      dout   => gcr_dout,
      din    => gcr_din,
      mode   => gcr_mode,
      mtr    => gcr_mtr,
      freq   => "00",
      sync_n => gcr_sync_n,
      byte_n => gcr_byte_n,
      track  => TEST_TRACK_HALF,

      we        => gcr_wr_en,
      wr_data   => gcr_wr_data,
      wr_offset => gcr_wr_offset,
      wr_commit => gcr_wr_commit,
      wr_block_done => gcr_wr_done,
      wr_checksum_error => gcr_wr_ckerr,
      wr_checksum_calc => open,
      wr_checksum_recv => open,
      wr_prev_data => open,
      wr_last_data => open,
      wr_debug => open,
      wr_trace_addr => (others => '0'),
      wr_trace_data => open,
      wr_trace_count => open,
      wr_trace_clear => '0',
      wr_stall  => src_wr_busy,

      img_track  => gcr_img_track,
      img_sector => gcr_img_sector,
      img_offset => gcr_img_offset,
      img_dout   => src_dout,
      img_valid  => src_valid
    );

  src_track  <= gcr_img_track  when source_from_gcr = '1' else TEST_TRACK;
  src_sector <= gcr_img_sector when source_from_gcr = '1' else TEST_SECTOR;
  src_offset <= gcr_img_offset when source_from_gcr = '1' else std_logic_vector(verify_idx);

  d64_i : entity work.c1541_sd_d64_sector_source
    generic map (
      RAW_D64_LBA       => x"00000000",
      PACKED_D64_FILE   => true,
      SD_BYTE_ADDRESSING => false,
      SD_WRITE_ENABLE   => true,
      CLK_HZ            => CLK_HZ,
      BAUD              => BAUD,
      DEBUG_UART        => false
    )
    port map (
      clk     => clk_27mhz,
      reset   => rst,
      track   => src_track,
      sector  => src_sector,
      offset  => src_offset,
      dout    => src_dout,
      valid   => src_valid,

      wr_en     => gcr_wr_en,
      wr_offset => gcr_wr_offset,
      wr_data   => gcr_wr_data,
      wr_commit => gcr_wr_commit,
      wr_busy   => src_wr_busy,

      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_read,
      sd_sec_read_addr       => sd_read_addr,
      sd_sec_read_data       => sd_read_data,
      sd_sec_read_data_valid => sd_read_valid,
      sd_sec_read_end        => sd_read_end,

      sd_sec_write           => sd_write,
      sd_sec_write_addr      => sd_write_addr,
      sd_sec_write_data      => sd_write_data,
      sd_sec_write_data_req  => sd_write_req,
      sd_sec_write_end       => sd_write_end,

      mount_lba    => x"00000000",
      mount_strobe => mount_strobe,
      uart_tx      => src_uart_tx
    );

  tx_i : entity work.uart_tx_ser
    generic map (
      CLK_HZ => CLK_HZ,
      BAUD   => BAUD
    )
    port map (
      clk     => clk_27mhz,
      reset_n => reset_n,
      data    => uart_data,
      valid   => uart_valid,
      tx      => uart_tx,
      busy    => uart_busy
    );

  process(clk_27mhz)
    variable transition_msg : msg_t;
  begin
    if rising_edge(clk_27mhz) then
      uart_valid <= '0';

      if rst = '1' then
        uart_active <= '0';
        uart_msg <= MSG_NONE;
        uart_next_msg <= MSG_START;
        uart_pos <= (others => '0');
        uart_last_state <= ST_WAIT_SD;
      else
        transition_msg := MSG_NONE;
        if state /= uart_last_state then
          uart_last_state <= state;
          case state is
            when ST_MOUNT =>
              transition_msg := MSG_SD_OK;
            when ST_WAIT_FLUSH_BUSY =>
              transition_msg := MSG_COMMIT;
            when ST_PASS =>
              transition_msg := MSG_PASS;
            when ST_FAIL =>
              transition_msg := MSG_FAIL;
            when others =>
              transition_msg := MSG_NONE;
          end case;
        end if;

        if transition_msg /= MSG_NONE then
          uart_next_msg <= transition_msg;
        end if;

        if uart_active = '0' and uart_next_msg /= MSG_NONE then
          uart_active <= '1';
          uart_msg <= uart_next_msg;
          uart_next_msg <= MSG_NONE;
          uart_pos <= (others => '0');
        elsif uart_active = '1' and uart_busy = '0' then
          uart_data <= msg_char(uart_msg, to_integer(uart_pos), fail_code);
          uart_valid <= '1';
          if to_integer(uart_pos) = msg_len(uart_msg) - 1 then
            uart_active <= '0';
            uart_pos <= (others => '0');
          else
            uart_pos <= uart_pos + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  process(clk_27mhz)
    procedure fail(constant code : in std_logic_vector(7 downto 0)) is
    begin
      fail_code <= code;
      gcr_mtr <= '0';
      source_from_gcr <= '0';
      state <= ST_FAIL;
    end procedure;
  begin
    if rising_edge(clk_27mhz) then
      mount_strobe <= '0';
      gcr_byte_n_d <= gcr_byte_n;
      blink_cnt <= blink_cnt + 1;

      if rst = '1' then
        state <= ST_WAIT_SD;
        source_from_gcr <= '1';
        gcr_mode <= '0';
        gcr_mtr <= '0';
        gcr_din <= RAW_ROM(0);
        raw_idx <= to_unsigned(1, raw_idx'length);
        timeout <= (others => '0');
        verify_idx <= (others => '0');
        fail_code <= x"00";
      else
        case state is
          when ST_WAIT_SD =>
            timeout <= timeout + 1;
            if sd_init_done = '1' then
              mount_strobe <= '1';
              timeout <= (others => '0');
              state <= ST_MOUNT;
            elsif timeout = x"FFFFFFF" then
              fail(x"01");
            end if;

          when ST_MOUNT =>
            timeout <= timeout + 1;
            if timeout = to_unsigned(1024, timeout'length) then
              timeout <= (others => '0');
              state <= ST_START_WRITE;
            end if;

          when ST_START_WRITE =>
            source_from_gcr <= '1';
            gcr_mode <= '0';
            gcr_mtr <= '1';
            gcr_din <= RAW_ROM(0);
            raw_idx <= to_unsigned(1, raw_idx'length);
            timeout <= (others => '0');
            state <= ST_WRITE;

          when ST_WRITE =>
            timeout <= timeout + 1;
            if gcr_byte_n_d = '1' and gcr_byte_n = '0' then
              if raw_idx < RAW_STREAM_BYTES then
                gcr_din <= RAW_ROM(to_integer(raw_idx));
                raw_idx <= raw_idx + 1;
              else
                gcr_din <= x"FF";
              end if;
            end if;
            if gcr_wr_commit = '1' then
              timeout <= (others => '0');
              state <= ST_WAIT_FLUSH_BUSY;
            elsif gcr_wr_ckerr = '1' then
              fail(x"02");
            elsif timeout = x"0FFFFFF" then
              fail(x"03");
            end if;

          when ST_WAIT_FLUSH_BUSY =>
            timeout <= timeout + 1;
            if src_wr_busy = '1' then
              timeout <= (others => '0');
              state <= ST_WAIT_FLUSH_DONE;
            elsif timeout = x"0FFFFFF" then
              fail(x"04");
            end if;

          when ST_WAIT_FLUSH_DONE =>
            timeout <= timeout + 1;
            if src_wr_busy = '0' then
              gcr_mtr <= '0';
              source_from_gcr <= '0';
              verify_idx <= (others => '0');
              timeout <= (others => '0');
              state <= ST_START_VERIFY;
            elsif timeout = x"FFFFFFF" then
              fail(x"05");
            end if;

          when ST_START_VERIFY =>
            source_from_gcr <= '0';
            verify_idx <= (others => '0');
            timeout <= (others => '0');
            state <= ST_WAIT_VALID;

          when ST_WAIT_VALID =>
            timeout <= timeout + 1;
            if src_valid = '1' then
              timeout <= (others => '0');
              state <= ST_VERIFY_SET;
            elsif timeout = x"FFFFFFF" then
              fail(x"06");
            end if;

          when ST_VERIFY_SET =>
            state <= ST_VERIFY_CHECK;

          when ST_VERIFY_CHECK =>
            if src_valid = '0' then
              fail(x"07");
            elsif src_dout /= pattern(to_integer(verify_idx)) then
              fail("1" & std_logic_vector(verify_idx(6 downto 0)));
            elsif verify_idx = x"FF" then
              state <= ST_PASS;
            else
              verify_idx <= verify_idx + 1;
              state <= ST_VERIFY_SET;
            end if;

          when ST_PASS =>
            gcr_mtr <= '0';

          when ST_FAIL =>
            gcr_mtr <= '0';
        end case;
      end if;
    end if;
  end process;

  process(state, sd_init_done, src_wr_busy, src_valid, blink_cnt)
  begin
    led <= (others => '1');
    if state = ST_FAIL then
      led <= (others => blink_cnt(23));
    else
      if sd_init_done = '0' then
        led(0) <= '0';
      end if;
      if state = ST_WRITE or state = ST_WAIT_FLUSH_BUSY
         or state = ST_WAIT_FLUSH_DONE or src_wr_busy = '1' then
        led(1) <= '0';
      end if;
      if state = ST_WAIT_VALID or state = ST_VERIFY_SET
         or state = ST_VERIFY_CHECK or src_valid = '1' then
        led(2) <= '0';
      end if;
      if state = ST_PASS then
        led(3) <= '0';
      end if;
    end if;
  end process;
end architecture;
