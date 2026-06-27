-- ============================================================================
-- REIST benchmark reporter.
--
-- Once the engine is done, walk its result registers and stream one line per
-- modulus over UART (8N1) via the shared uart_tx_ser serializer:
--
--   B=000000FB R=00000400 D=0000D080 I=00000422<CR><LF>
--      modulus | REIST cyc | IP dependency-chain cyc | IP independent cyc
--
-- All hex (keeps the formatter divider-free); values are clock-cycle counts read
-- straight from the engine. VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.reist_pkg.all;

entity bench_report is
  generic (
    CLK_HZ : positive := 27_000_000;
    BAUD   : positive := 115_200
  );
  port (
    clk         : in  std_logic;
    reset_n     : in  std_logic;
    start       : in  std_logic;
    res_index   : out integer range 0 to MODULI'length-1;
    res_modulus : in  unsigned(31 downto 0);
    res_reist   : in  unsigned(31 downto 0);
    res_ipdep   : in  unsigned(31 downto 0);
    res_ipind   : in  unsigned(31 downto 0);
    tx          : out std_logic;
    done        : out std_logic
  );
end entity;

architecture rtl of bench_report is

  constant NUM      : positive := MODULI'length;
  constant LINE_LEN : positive := 45;

  function ch(c : character) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(character'pos(c), 8));
  end function;

  function hexd(n : unsigned(3 downto 0)) return std_logic_vector is
  begin
    if n < 10 then
      return std_logic_vector(to_unsigned(character'pos('0') + to_integer(n), 8));
    else
      return std_logic_vector(to_unsigned(character'pos('A') + to_integer(n) - 10, 8));
    end if;
  end function;

  function nib(v : unsigned(31 downto 0); k : integer) return unsigned is
  begin
    return v(31 - 4*k downto 28 - 4*k);           -- k=0 is the MS nibble
  end function;

  function line_byte(p : integer; m, r, d, i : unsigned(31 downto 0))
    return std_logic_vector is
  begin
    case p is
      when 0  => return ch('B');
      when 1  => return ch('=');
      when 2|3|4|5|6|7|8|9         => return hexd(nib(m, p - 2));
      when 10 => return ch(' ');
      when 11 => return ch('R');
      when 12 => return ch('=');
      when 13|14|15|16|17|18|19|20 => return hexd(nib(r, p - 13));
      when 21 => return ch(' ');
      when 22 => return ch('D');
      when 23 => return ch('=');
      when 24|25|26|27|28|29|30|31 => return hexd(nib(d, p - 24));
      when 32 => return ch(' ');
      when 33 => return ch('I');
      when 34 => return ch('=');
      when 35|36|37|38|39|40|41|42 => return hexd(nib(i, p - 35));
      when 43 => return x"0D";                      -- CR
      when others => return x"0A";                  -- LF (p = 44)
    end case;
  end function;

  type state_t is (S_IDLE, S_LOAD, S_PUT, S_HOLD, S_DRAIN, S_NEXT, S_DONE);
  signal state : state_t := S_IDLE;
  signal idx   : integer range 0 to NUM-1 := 0;
  signal pos   : integer range 0 to LINE_LEN := 0;

  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid : std_logic := '0';
  signal tx_busy  : std_logic;

begin

  res_index <= idx;
  done      <= '1' when state = S_DONE else '0';

  uart : entity work.uart_tx_ser
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => clk, reset_n => reset_n,
              data => tx_data, valid => tx_valid, tx => tx, busy => tx_busy);

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state    <= S_IDLE;
        idx      <= 0;
        pos      <= 0;
        tx_valid <= '0';
      else
        tx_valid <= '0';
        case state is
          when S_IDLE =>
            if start = '1' then
              idx <= 0; pos <= 0; state <= S_LOAD;
            end if;

          when S_LOAD =>
            state <= S_PUT;            -- res_index settled

          when S_PUT =>
            if tx_busy = '0' then
              tx_data  <= line_byte(pos, res_modulus, res_reist, res_ipdep, res_ipind);
              tx_valid <= '1';
              state    <= S_HOLD;
            end if;

          when S_HOLD =>
            state <= S_DRAIN;

          when S_DRAIN =>
            if tx_busy = '0' then
              if pos = LINE_LEN - 1 then
                pos <= 0; state <= S_NEXT;
              else
                pos <= pos + 1; state <= S_PUT;
              end if;
            end if;

          when S_NEXT =>
            if idx = NUM - 1 then
              state <= S_DONE;
            else
              idx <= idx + 1; state <= S_LOAD;
            end if;

          when S_DONE =>
            null;
        end case;
      end if;
    end if;
  end process;

end architecture;
