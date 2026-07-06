-- ============================================================================
-- ulpi_rec -- tiny on-chip ULPI bus recorder for hardware bring-up.
--
-- Continuously samples {data[7:0], stp, nxt, dir} into a circular buffer. On the
-- first cycle the wrapper drives a TX CMD (dir=0 and data[7:6] /= 00) it captures
-- a further (DEPTH-PRE) samples, then dumps the whole window over UART as hex --
-- one triplet per sample:  HH C  (HH = data byte, C = {stp,nxt,dir} as 0..7).
-- 16 samples per line. One-shot: after the dump it stays quiet and the normal
-- status printer resumes.
--
-- Purpose: see whether the USB3317 ever asserts NXT (bit1 of C) in response to
-- the wrapper's TX CMD -- the register-level symptom "NXT never pulses" cannot
-- be diagnosed any other way.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ulpi_rec is
  generic (
    DEPTH   : positive := 256;
    PRE     : positive := 64;      -- samples retained before the trigger
    -- Trigger byte on the ULPI data bus (dir=0, FPGA driving). Default 0x4D =
    -- REG_TRANSMIT | (SETUP pid 0x2D low nibble) -> captures the SETUP packet.
    TRIG_BYTE : std_logic_vector(7 downto 0) := x"4D"
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;
    sample   : in  std_logic_vector(10 downto 0);  -- data(10:3) stp(2) nxt(1) dir(0)

    tx_data  : out std_logic_vector(7 downto 0);
    tx_valid : out std_logic;
    tx_busy  : in  std_logic;
    active   : out std_logic                        -- '1' while dumping (UART mux)
  );
end entity;

architecture rtl of ulpi_rec is
  type mem_t is array(0 to DEPTH-1) of std_logic_vector(10 downto 0);
  signal mem : mem_t;

  type st_t is (FILL, POST, D_HDR, D_LOAD, D_EMIT, D_NL, DONE);
  signal st       : st_t := FILL;
  signal wr_ptr   : integer range 0 to DEPTH-1 := 0;
  signal rd_ptr   : integer range 0 to DEPTH-1 := 0;
  signal start_ptr: integer range 0 to DEPTH-1 := 0;
  signal post_cnt : integer range 0 to DEPTH := 0;
  signal n_done   : integer range 0 to DEPTH := 0;
  signal cur      : std_logic_vector(10 downto 0) := (others => '0');
  signal nib      : integer range 0 to 3 := 0;
  signal col      : integer range 0 to 15 := 0;
  signal hdr_i    : integer range 0 to 6 := 0;
  signal armed    : std_logic := '1';

  signal tx_data_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid_r : std_logic := '0';

  function hexc(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : integer := to_integer(unsigned(n));
  begin
    if v < 10 then return std_logic_vector(to_unsigned(16#30#+v, 8));
    else            return std_logic_vector(to_unsigned(16#41#+v-10, 8)); end if;
  end function;

  function hdr_char(i : integer) return std_logic_vector is
  begin
    case i is
      when 0 => return x"55";  -- U
      when 1 => return x"4C";  -- L
      when 2 => return x"50";  -- P
      when 3 => return x"49";  -- I
      when 4 => return x"3A";  -- :
      when 5 => return x"0D";  -- CR
      when others => return x"0A";  -- LF
    end case;
  end function;

begin
  tx_data  <= tx_data_r;
  tx_valid <= tx_valid_r;
  active   <= '1' when (st = D_HDR or st = D_LOAD or st = D_EMIT or st = D_NL) else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      tx_valid_r <= '0';
      if reset_n = '0' then
        st <= FILL; wr_ptr <= 0; post_cnt <= 0; armed <= '1'; n_done <= 0;
      else
        case st is

          when FILL =>
            mem(wr_ptr) <= sample;
            if wr_ptr = DEPTH-1 then wr_ptr <= 0; else wr_ptr <= wr_ptr + 1; end if;
            -- trigger: wrapper driving the SETUP token (or configured byte)
            if armed = '1' and sample(0) = '0' and sample(10 downto 3) = TRIG_BYTE then
              armed    <= '0';
              post_cnt <= 0;
              st       <= POST;
            end if;

          when POST =>
            mem(wr_ptr) <= sample;
            if wr_ptr = DEPTH-1 then wr_ptr <= 0; else wr_ptr <= wr_ptr + 1; end if;
            if post_cnt = DEPTH - PRE - 1 then
              -- after this the buffer holds PRE pre-trigger + (DEPTH-PRE) post.
              -- oldest sample sits at the next write position.
              if wr_ptr = DEPTH-1 then start_ptr <= 0; else start_ptr <= wr_ptr + 1; end if;
              hdr_i <= 0;
              st    <= D_HDR;
            else
              post_cnt <= post_cnt + 1;
            end if;

          when D_HDR =>
            if tx_busy = '0' and tx_valid_r = '0' then
              tx_data_r  <= hdr_char(hdr_i);
              tx_valid_r <= '1';
              if hdr_i = 6 then
                rd_ptr <= start_ptr; n_done <= 0; col <= 0; st <= D_LOAD;
              else
                hdr_i <= hdr_i + 1;
              end if;
            end if;

          when D_LOAD =>
            cur <= mem(rd_ptr);
            nib <= 0;
            st  <= D_EMIT;

          when D_EMIT =>
            if tx_busy = '0' and tx_valid_r = '0' then
              case nib is
                when 0 => tx_data_r <= hexc(cur(10 downto 7));       -- data hi
                when 1 => tx_data_r <= hexc(cur(6 downto 3));        -- data lo
                when others => tx_data_r <= hexc('0' & cur(2 downto 0)); -- stp/nxt/dir
              end case;
              tx_valid_r <= '1';
              if nib = 2 then
                if rd_ptr = DEPTH-1 then rd_ptr <= 0; else rd_ptr <= rd_ptr + 1; end if;
                n_done <= n_done + 1;
                st <= D_NL;
              else
                nib <= nib + 1;
              end if;
            end if;

          when D_NL =>
            if n_done = DEPTH then
              st <= DONE;
            elsif tx_busy = '0' and tx_valid_r = '0' then
              if col = 15 then
                tx_data_r <= x"0A";        -- newline every 16 samples
                tx_valid_r <= '1';
                col <= 0;
                st  <= D_LOAD;
              else
                tx_data_r <= x"20";        -- space between samples
                tx_valid_r <= '1';
                col <= col + 1;
                st  <= D_LOAD;
              end if;
            end if;

          when DONE =>
            null;                          -- one-shot; stay quiet

        end case;
      end if;
    end if;
  end process;

end architecture;
