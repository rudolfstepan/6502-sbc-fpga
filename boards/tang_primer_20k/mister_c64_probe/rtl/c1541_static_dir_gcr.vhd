library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c1541_static_dir_gcr is
  generic (
    GCR_TURBO : integer := 1
  );
  port (
    clk    : in  std_logic;
    ce     : in  std_logic;
    reset  : in  std_logic;

    dout   : out std_logic_vector(7 downto 0);
    din    : in  std_logic_vector(7 downto 0);
    mode   : in  std_logic;
    mtr    : in  std_logic;
    freq   : in  std_logic_vector(1 downto 0);
    sync_n : out std_logic;
    byte_n : out std_logic;

    track  : in  std_logic_vector(6 downto 0);

    we        : out std_logic;
    wr_data   : out std_logic_vector(7 downto 0);
    wr_offset : out std_logic_vector(7 downto 0);
    wr_commit : out std_logic;
    wr_block_done : out std_logic;
    wr_checksum_error : out std_logic;
    wr_checksum_calc : out std_logic_vector(7 downto 0);
    wr_checksum_recv : out std_logic_vector(7 downto 0);
    wr_prev_data : out std_logic_vector(7 downto 0);
    wr_last_data : out std_logic_vector(7 downto 0);
    wr_debug : out std_logic_vector(7 downto 0);
    wr_trace_addr : in  std_logic_vector(4 downto 0);
    wr_trace_data : out std_logic_vector(31 downto 0);
    wr_trace_count : out std_logic_vector(5 downto 0);
    wr_trace_clear : in  std_logic;
    wr_stall  : in  std_logic;

    img_track  : out std_logic_vector(7 downto 0);
    img_sector : out std_logic_vector(4 downto 0);
    img_offset : out std_logic_vector(7 downto 0);
    img_dout   : in  std_logic_vector(7 downto 0);
    img_valid  : in  std_logic
  );
end entity;

architecture rtl of c1541_static_dir_gcr is
  constant ID1 : std_logic_vector(7 downto 0) := x"54";
  constant ID2 : std_logic_vector(7 downto 0) := x"50";

  function clipped_step return natural is
  begin
    if GCR_TURBO < 1 then
      return 1;
    elsif GCR_TURBO > 8 then
      return 8;
    else
      return GCR_TURBO;
    end if;
  end function;

  constant BIT_CLK_STEP_I : natural := clipped_step;
  constant BIT_CLK_STEP   : unsigned(5 downto 0) := to_unsigned(BIT_CLK_STEP_I, 6);
  constant BIT_CLK_LIMIT  : unsigned(5 downto 0) := to_unsigned(64 - BIT_CLK_STEP_I, 6);

  function freq_seed(f : std_logic_vector(1 downto 0)) return unsigned is
  begin
    return resize(unsigned(f & "00"), 6);
  end function;

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

  function gcr_decode(value : std_logic_vector(4 downto 0)) return std_logic_vector is
  begin
    case value is
      when "01010" => return x"0";
      when "11010" => return x"1";
      when "01001" => return x"2";
      when "11001" => return x"3";
      when "01110" => return x"4";
      when "11110" => return x"5";
      when "01101" => return x"6";
      when "11101" => return x"7";
      when "10010" => return x"8";
      when "10011" => return x"9";
      when "01011" => return x"A";
      when "11011" => return x"B";
      when "10110" => return x"C";
      when "10111" => return x"D";
      when "01111" => return x"E";
      when "10101" => return x"F";
      when others => return x"F";
    end case;
  end function;

  function gcr_valid(value : std_logic_vector(4 downto 0)) return boolean is
  begin
    case value is
      when "01010" | "11010" | "01001" | "11001" |
           "01110" | "11110" | "01101" | "11101" |
           "10010" | "10011" | "01011" | "11011" |
           "10110" | "10111" | "01111" | "10101" =>
        return true;
      when others =>
        return false;
    end case;
  end function;

  signal logical_track : unsigned(7 downto 0);
  signal sector_max    : unsigned(4 downto 0);
  signal sector        : unsigned(4 downto 0);

  signal data_header : std_logic_vector(7 downto 0);
  signal data_body   : std_logic_vector(7 downto 0);
  signal data        : std_logic_vector(7 downto 0);
  signal gcr_nibble  : std_logic_vector(4 downto 0);

  signal bit_clk_en  : std_logic := '0';
  signal bit_clk_cnt : unsigned(5 downto 0) := (others => '0');
  signal old_track   : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(34, 7));
  signal mode_r1     : std_logic := '1';

  signal sync_in_n     : std_logic := '0';
  signal byte_in       : std_logic := '0';
  signal byte_cnt      : unsigned(8 downto 0) := (others => '0');
  signal nibble        : std_logic := '0';
  signal state         : std_logic := '0';
  signal data_cks      : std_logic_vector(7 downto 0) := (others => '0');
  signal buff_do       : std_logic_vector(7 downto 0) := (others => '0');
  signal gcr_byte_out  : std_logic_vector(7 downto 0) := (others => '0');
  signal gcr_nibble_out : std_logic_vector(4 downto 0) := (others => '0');
  signal hdr_cks       : std_logic_vector(7 downto 0) := (others => '0');
  signal buff_di       : std_logic_vector(7 downto 0) := (others => '0');
  signal nibble_out    : std_logic_vector(3 downto 0);

  signal mode_r2        : std_logic := '1';
  signal autorise_write : std_logic := '0';
  signal autorise_count : std_logic := '0';
  signal sync_cnt       : unsigned(5 downto 0) := (others => '0');
  signal gcr_byte       : std_logic_vector(7 downto 0) := (others => '0');
  signal bit_cnt        : unsigned(2 downto 0) := (others => '0');
  signal gcr_bit_cnt    : unsigned(3 downto 0) := (others => '0');

  signal wr_cnt            : unsigned(8 downto 0) := (others => '0');
  signal wr_committed      : std_logic := '1';
  signal wr_capture        : std_logic := '0';
  signal wr_candidate      : std_logic := '0';
  signal wr_valid_nibbles  : unsigned(5 downto 0) := (others => '0');
  signal wr_seen_sync      : std_logic := '0';
  signal wr_sync_run       : unsigned(5 downto 0) := (others => '0');
  signal wr_post_sync_bits : unsigned(3 downto 0) := (others => '0');
  signal wr_marker_shift   : std_logic_vector(9 downto 0) := (others => '0');
  signal wr_gcr_shift      : std_logic_vector(4 downto 0) := (others => '0');
  signal wr_gcr_cnt        : unsigned(2 downto 0) := (others => '0');
  signal wr_half           : std_logic := '0';
  signal wr_high           : std_logic_vector(3 downto 0) := (others => '0');
  signal wr_cks            : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_invalid_count  : unsigned(6 downto 0) := (others => '0');
  constant WR_TRACE_DEPTH : natural := 2;
  type wr_trace_t is array (0 to WR_TRACE_DEPTH - 1) of std_logic_vector(31 downto 0);
  signal wr_trace_mem   : wr_trace_t := (others => (others => '0'));
  signal wr_trace_count_r : unsigned(5 downto 0) := (others => '0');
  signal wr_trace_data_r  : std_logic_vector(31 downto 0) := (others => '0');
begin
  logical_track <= resize(unsigned(track(6 downto 1)), 8) + 1;
  sector_max <= to_unsigned(20, 5) when logical_track < 18 else
                to_unsigned(18, 5) when logical_track < 25 else
                to_unsigned(17, 5) when logical_track < 31 else
                to_unsigned(16, 5);

  data_header <= x"08" when byte_cnt = 0 else
                 hdr_cks when byte_cnt = 1 else
                 "000" & std_logic_vector(sector) when byte_cnt = 2 else
                 std_logic_vector(logical_track) when byte_cnt = 3 else
                 ID2 when byte_cnt = 4 else
                 ID1 when byte_cnt = 5 else
                 x"0F";

  data_body <= x"07" when byte_cnt = 0 else
               data_cks when byte_cnt = 257 else
               x"00" when byte_cnt = 258 else
               x"00" when byte_cnt = 259 else
               x"0F" when byte_cnt >= 260 else
               buff_do;

  data <= data_body when state = '1' else data_header;
  gcr_nibble <= gcr_encode(data(3 downto 0)) when nibble = '1' else
                gcr_encode(data(7 downto 4));
  nibble_out <= gcr_decode(gcr_nibble_out);

  sync_n <= '1' when mtr = '0' or sync_in_n = '1' else '0';

  img_track  <= std_logic_vector(logical_track);
  img_sector <= std_logic_vector(sector);
  img_offset <= std_logic_vector(byte_cnt(7 downto 0));
  wr_trace_data <= wr_trace_data_r;
  wr_trace_count <= std_logic_vector(wr_trace_count_r);

  process(clk)
  begin
    if rising_edge(clk) then
      bit_clk_en <= '0';

      if reset = '1' then
        old_track <= std_logic_vector(to_unsigned(34, 7));
        mode_r1 <= '1';
        byte_n <= '1';
        bit_clk_cnt <= (others => '0');
      elsif ce = '1' then
        old_track <= track;
        mode_r1 <= mode;
        byte_n <= '1';

        if old_track /= track or (mode_r1 xor mode) = '1' or mtr = '0' then
          bit_clk_cnt <= freq_seed(freq);
        elsif (mode = '1' and img_valid = '0') or (mode = '0' and wr_stall = '1') then
          null;
        else
          bit_clk_cnt <= bit_clk_cnt + BIT_CLK_STEP;
          if byte_in = '1' and bit_clk_cnt(5 downto 4) = "01" then
            byte_n <= '0';
          end if;

          if bit_clk_cnt >= BIT_CLK_LIMIT then
            bit_clk_en <= '1';
            bit_clk_cnt <= freq_seed(freq);
          end if;
        end if;
      end if;
    end if;
  end process;

  process(clk)
    variable write_bit_v           : std_logic;
    variable wr_marker_next_v      : std_logic_vector(9 downto 0);
    variable wr_gcr_next_v         : std_logic_vector(4 downto 0);
    variable wr_nibble_v           : std_logic_vector(3 downto 0);
    variable wr_nibble_valid_v     : boolean;
    variable wr_byte_v             : std_logic_vector(7 downto 0);
    variable wr_trace_count_v      : unsigned(5 downto 0) := (others => '0');
    procedure trace_event(
      constant ev : in std_logic_vector(7 downto 0);
      constant a  : in std_logic_vector(7 downto 0);
      constant b  : in std_logic_vector(7 downto 0);
      constant c  : in std_logic_vector(7 downto 0)) is
    begin
      if wr_trace_count_v < WR_TRACE_DEPTH then
        wr_trace_mem(to_integer(wr_trace_count_v(0 downto 0))) <= ev & a & b & c;
        wr_trace_count_v := wr_trace_count_v + 1;
        wr_trace_count_r <= wr_trace_count_v;
      end if;
    end procedure;
  begin
    if rising_edge(clk) then
      wr_trace_count_v := wr_trace_count_r;
      hdr_cks <= std_logic_vector(logical_track) xor ("000" & std_logic_vector(sector)) xor ID1 xor ID2;

      we <= '0';
      wr_commit <= '0';
      wr_block_done <= '0';
      wr_checksum_error <= '0';

      if reset = '1' then
        sector <= (others => '0');
        sync_in_n <= '0';
        byte_in <= '0';
        byte_cnt <= (others => '0');
        nibble <= '0';
        state <= '0';
        data_cks <= (others => '0');
        buff_do <= (others => '0');
        dout <= x"FF";
        gcr_byte_out <= (others => '0');
        gcr_nibble_out <= (others => '0');
        hdr_cks <= (others => '0');
        mode_r2 <= '1';
        autorise_write <= '0';
        autorise_count <= '0';
        sync_cnt <= (others => '0');
        gcr_byte <= (others => '0');
        bit_cnt <= (others => '0');
        gcr_bit_cnt <= (others => '0');
        we <= '0';
        wr_data <= (others => '0');
        wr_offset <= (others => '0');
        wr_commit <= '0';
        wr_block_done <= '0';
        wr_checksum_error <= '0';
        wr_checksum_calc <= (others => '0');
        wr_checksum_recv <= (others => '0');
        wr_prev_data <= (others => '0');
        wr_last_data <= (others => '0');
        wr_debug <= (others => '0');
        wr_cnt <= (others => '0');
        wr_committed <= '1';
        wr_capture <= '0';
        wr_candidate <= '0';
        wr_valid_nibbles <= (others => '0');
        wr_seen_sync <= '0';
        wr_sync_run <= (others => '0');
        wr_post_sync_bits <= (others => '0');
        wr_marker_shift <= (others => '0');
        wr_gcr_shift <= (others => '0');
        wr_gcr_cnt <= (others => '0');
        wr_half <= '0';
        wr_high <= (others => '0');
        wr_cks <= (others => '0');
        wr_invalid_count <= (others => '0');
        wr_trace_mem <= (others => (others => '0'));
        wr_trace_count_r <= (others => '0');
        wr_trace_count_v := (others => '0');
        wr_trace_data_r <= (others => '0');
      elsif sector > sector_max then
        sector <= (others => '0');
      else
        wr_trace_data_r <= wr_trace_mem(to_integer(unsigned(wr_trace_addr(0 downto 0))));
        if wr_trace_clear = '1' then
          wr_trace_mem <= (others => (others => '0'));
          wr_trace_count_r <= (others => '0');
          wr_trace_count_v := (others => '0');
          wr_trace_data_r <= (others => '0');
        end if;

        if bit_clk_en = '1' then
          mode_r2 <= mode;
          if mode = '1' then
            autorise_write <= '0';
            wr_capture <= '0';
            wr_candidate <= '0';
            wr_valid_nibbles <= (others => '0');
            wr_seen_sync <= '0';
            wr_sync_run <= (others => '0');
            wr_post_sync_bits <= (others => '0');
          end if;

          if (mode xor mode_r2) = '1' then
            if mode = '1' then
              sync_in_n <= '0';
              sync_cnt <= (others => '0');
              state <= '0';
            else
              byte_cnt <= (others => '0');
              nibble <= '0';
              gcr_bit_cnt <= (others => '0');
              bit_cnt <= (others => '0');
              gcr_byte <= (others => '0');
              data_cks <= (others => '0');
              wr_cnt <= (others => '0');
              wr_committed <= '0';
              wr_capture <= '0';
              wr_candidate <= '0';
              wr_valid_nibbles <= (others => '0');
              wr_seen_sync <= '0';
              wr_sync_run <= (others => '0');
              wr_post_sync_bits <= (others => '0');
              wr_marker_shift <= (others => '0');
              wr_gcr_shift <= (others => '0');
              wr_gcr_cnt <= (others => '0');
              wr_half <= '0';
              wr_cks <= (others => '0');
              wr_invalid_count <= (others => '0');
            end if;
          end if;

          byte_in <= '0';

          if sync_in_n = '0' and mode = '1' then
            byte_cnt <= (others => '0');
            nibble <= '0';
            gcr_bit_cnt <= (others => '0');
            bit_cnt <= (others => '0');
            dout <= x"FF";
            gcr_byte <= (others => '0');
            data_cks <= (others => '0');
            sync_cnt <= sync_cnt + 1;
            if sync_cnt = 39 then
              sync_cnt <= (others => '0');
              sync_in_n <= '1';
            end if;
          else
            gcr_bit_cnt <= gcr_bit_cnt + 1;
            if gcr_bit_cnt = 4 then
              gcr_bit_cnt <= (others => '0');
              if nibble = '1' then
                nibble <= '0';
                buff_do <= img_dout;
                if byte_cnt = 0 then
                  data_cks <= (others => '0');
                else
                  data_cks <= data_cks xor data;
                end if;

                if mode = '1' or autorise_count = '1' then
                  byte_cnt <= byte_cnt + 1;
                end if;
              else
                nibble <= '1';
                if byte_cnt(8) = '1' then
                  autorise_write <= '0';
                  autorise_count <= '0';
                end if;
              end if;
            end if;

            bit_cnt <= bit_cnt + 1;
            if bit_cnt = 7 then
              byte_in <= '1';
              gcr_byte_out <= din;
            end if;

            if state = '0' then
              if byte_cnt = 16 then
                sync_in_n <= '0';
                state <= '1';
              end if;
            elsif byte_cnt = 273 then
              sync_in_n <= '0';
              state <= '0';
              if sector = sector_max then
                sector <= (others => '0');
              else
                sector <= sector + 1;
              end if;
            end if;

            gcr_byte <= gcr_byte(6 downto 0) & gcr_nibble(to_integer(gcr_bit_cnt));
            if bit_cnt = 7 then
              dout <= gcr_byte(6 downto 0) & gcr_nibble(to_integer(gcr_bit_cnt));
            end if;

            -- The DOS packs standard GCR codes MSB-first into $1C01, so the
            -- wire order here is the plain standard bit order (e.g. $07 ->
            -- 01010 10111).  The marker register keeps wire order; the group
            -- register shifts in from the LEFT so a finished group reads
            -- bit-reversed, which is exactly how gcr_encode/gcr_decode store
            -- the codes (the read path emits gcr_nibble(0) first for the
            -- same reason).
            write_bit_v := gcr_byte_out(7 - to_integer(bit_cnt));
            wr_marker_next_v := wr_marker_shift(8 downto 0) & write_bit_v;
            wr_gcr_next_v := write_bit_v & wr_gcr_shift(4 downto 1);
            wr_nibble_v := gcr_decode(wr_gcr_next_v);
            wr_nibble_valid_v := gcr_valid(wr_gcr_next_v);

            gcr_nibble_out <= gcr_nibble_out(3 downto 0) & write_bit_v;
            if mode = '0' then
              wr_marker_shift <= wr_marker_next_v;

              if write_bit_v = '1' then
                if wr_sync_run /= 63 then
                  wr_sync_run <= wr_sync_run + 1;
                end if;
              else
                if wr_sync_run >= 32 then
                  wr_seen_sync <= '1';
                  wr_post_sync_bits <= to_unsigned(1, wr_post_sync_bits'length);
                end if;
                wr_sync_run <= (others => '0');
              end if;

              if wr_capture = '0' then
                -- Data-block marker $07 in wire order: $0 -> 01010 and
                -- $7 -> 10111 (standard GCR read MSB-first), i.e.
                -- "0101010111" straight off the serialized DOS bytes.
                -- Start a candidate here, but keep it only if the following
                -- GCR groups stay valid long enough to rule out noise.
                if wr_seen_sync = '1' and wr_marker_next_v = "0101010111" then
                  wr_capture <= '1';
                  wr_candidate <= '1';
                  wr_valid_nibbles <= (others => '0');
                  wr_seen_sync <= '0';
                  wr_post_sync_bits <= (others => '0');
                  wr_gcr_shift <= (others => '0');
                  wr_gcr_cnt <= (others => '0');
                  wr_half <= '0';
                  wr_cnt <= (others => '0');
                  wr_committed <= '0';
                  wr_cks <= (others => '0');
                  wr_invalid_count <= (others => '0');
                  trace_event(x"20", "0000" & std_logic_vector(wr_post_sync_bits),
                              "000000" & wr_marker_next_v(9 downto 8),
                              wr_marker_next_v(7 downto 0));
                else
                  -- The byte-wide VIA handoff can put the first complete
                  -- marker a few bit-times after the first non-sync zero.
                  -- Keep the search narrow so random $07 patterns later in a
                  -- header/data block still cannot start a write.
                  if wr_seen_sync = '1' then
                    if wr_post_sync_bits = 15 then
                      wr_seen_sync <= '0';
                      wr_post_sync_bits <= (others => '0');
                    else
                      wr_post_sync_bits <= wr_post_sync_bits + 1;
                    end if;
                  end if;
                end if;
              else
                wr_gcr_shift <= wr_gcr_next_v;
                if wr_gcr_cnt = 4 then
                  wr_gcr_cnt <= (others => '0');
                  if wr_candidate = '1' and not wr_nibble_valid_v then
                    -- Abort false $07 candidates, but keep the continuously
                    -- updated SYNC/marker scanner intact so the following real
                    -- data block can still be found.
                    wr_checksum_calc <= "000" & wr_gcr_next_v;
                    wr_checksum_recv <= std_logic_vector(wr_cnt(7 downto 0));
                    wr_debug <= "00" & std_logic_vector(wr_valid_nibbles);
                    trace_event(x"30", "000" & wr_gcr_next_v,
                                std_logic_vector(wr_cnt(7 downto 0)),
                                "00" & std_logic_vector(wr_valid_nibbles));
                    wr_capture <= '0';
                    wr_candidate <= '0';
                    wr_valid_nibbles <= (others => '0');
                    wr_cnt <= (others => '0');
                    wr_committed <= '1';
                    wr_gcr_shift <= (others => '0');
                    wr_gcr_cnt <= (others => '0');
                    wr_half <= '0';
                    wr_high <= (others => '0');
                    wr_cks <= (others => '0');
                    wr_invalid_count <= (others => '0');
                  else
                    if not wr_nibble_valid_v and wr_invalid_count /= 127 then
                      wr_invalid_count <= wr_invalid_count + 1;
                    end if;
                    if wr_candidate = '1' then
                      if wr_valid_nibbles /= 63 then
                        wr_valid_nibbles <= wr_valid_nibbles + 1;
                      end if;
                    end if;
                    if wr_half = '0' then
                      wr_high <= wr_nibble_v;
                      wr_half <= '1';
                    else
                      wr_byte_v := wr_high & wr_nibble_v;
                      if wr_cnt(8) = '0' then
                        we <= '1';
                        wr_data <= wr_byte_v;
                        wr_offset <= std_logic_vector(wr_cnt(7 downto 0));
                        wr_prev_data <= wr_last_data;
                        wr_last_data <= wr_byte_v;
                        if wr_cnt = 0 then
                          wr_cks <= wr_byte_v;
                        else
                          wr_cks <= wr_cks xor wr_byte_v;
                        end if;
                        wr_cnt <= wr_cnt + 1;
                      else
                        wr_block_done <= '1';
                        wr_checksum_calc <= wr_cks;
                        wr_checksum_recv <= wr_byte_v;
                        wr_debug <= '0' & std_logic_vector(wr_invalid_count);
                        -- Normal D64 docs define the data checksum over only the
                        -- 256 payload bytes. Some 1541 write paths include the
                        -- already-consumed data-block ID ($07) in the XOR; accept
                        -- both exact variants and reject everything else.
                        if wr_committed = '0'
                           and (wr_cks = wr_byte_v
                                or (wr_cks xor x"07") = wr_byte_v) then
                          wr_commit <= '1';
                          wr_committed <= '1';
                          trace_event(x"50", wr_cks, wr_byte_v,
                                      std_logic_vector(wr_cnt(7 downto 0)));
                        else
                          wr_checksum_error <= '1';
                          trace_event(x"60", wr_cks, wr_byte_v,
                                      '0' & std_logic_vector(wr_invalid_count));
                        end if;
                        wr_capture <= '0';
                        wr_candidate <= '0';
                        wr_valid_nibbles <= (others => '0');
                        wr_seen_sync <= '0';
                        wr_post_sync_bits <= (others => '0');
                      end if;
                      wr_half <= '0';
                    end if;
                  end if;
                else
                  wr_gcr_cnt <= wr_gcr_cnt + 1;
                end if;
              end if;
            end if;

            if gcr_bit_cnt = 0 then
              if nibble = '1' then
                buff_di(7 downto 4) <= nibble_out;
              else
                buff_di(3 downto 0) <= nibble_out;
              end if;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
