-- ============================================================================
-- REIST benchmark engine.
--
-- For every modulus in MODULI it measures three clock-cycle counts:
--
--   reist : REIST centered correction in a dependency chain
--           acc <- center(acc + x). One conditional add/sub per step, 1 cyc.
--   ipdep : the SAME dependency chain reduced with the divider IP -- issue,
--           wait LATENCY for the result, feed it back, repeat. The pipeline
--           cannot be filled, so every step costs the full divider latency.
--   ipind : INDEPENDENT reductions streamed through the pipelined divider IP
--           (one issue per clock). This is the divider's best case (~N+LATENCY)
--           and shows where a pipelined IP catches up with REIST.
--
-- Honest reading: in dependency chains (the realistic modular-accumulate
-- pattern) REIST beats the divider IP by roughly its latency; for independent
-- work a pipelined IP nearly matches REIST on throughput. The divider behind
-- the IP port is ip_divider (a model now, the Gowin Integer Division IP later);
-- the cycle counts hold either way. VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.reist_pkg.all;

entity reist_bench_engine is
  generic (
    W       : positive := 32;
    N_ITERS : positive := 256;
    IP_LAT  : positive := 2           -- divider-IP latency (Gowin Integer Division = 2)
  );
  port (
    clk         : in  std_logic;
    reset_n     : in  std_logic;
    start       : in  std_logic;
    busy        : out std_logic;
    done        : out std_logic;
    res_index   : in  integer range 0 to MODULI'length-1 := 0;
    res_modulus : out unsigned(31 downto 0);
    res_reist   : out unsigned(31 downto 0);
    res_ipdep   : out unsigned(31 downto 0);
    res_ipind   : out unsigned(31 downto 0)
  );
end entity;

architecture rtl of reist_bench_engine is

  constant NUM : positive := MODULI'length;

  type cyc_array is array (0 to NUM-1) of unsigned(31 downto 0);
  signal reist_cyc : cyc_array := (others => (others => '0'));
  signal ipdep_cyc : cyc_array := (others => (others => '0'));
  signal ipind_cyc : cyc_array := (others => (others => '0'));

  type state_t is (S_IDLE,
                   R_SETUP, R_STEP, R_STORE,
                   D_SETUP, D_ISSUE, D_WAIT, D_STORE,
                   I_SETUP, I_RUN, I_STORE,
                   S_NEXT, S_FIN);
  signal state : state_t := S_IDLE;

  signal mi    : integer range 0 to NUM-1 := 0;
  signal iter  : integer range 0 to N_ITERS := 0;   -- issued / reist counter
  signal recv  : integer range 0 to N_ITERS := 0;   -- received (streaming) counter
  signal cyc   : unsigned(31 downto 0) := (others => '0');

  constant LFSR_SEED : std_logic_vector(15 downto 0) := x"ACE1";
  signal lfsr : std_logic_vector(15 downto 0) := LFSR_SEED;

  -- REIST datapath
  signal acc_s  : signed(W downto 0) := (others => '0');
  signal add_s  : signed(W downto 0);
  signal mod_s  : signed(W downto 0);
  signal sum_s  : signed(W downto 0);
  signal cent_s : signed(W downto 0);

  -- divider-IP datapath
  signal acc_u      : unsigned(W-1 downto 0) := (others => '0');
  signal ip_in_v    : std_logic := '0';
  signal ip_dvd     : unsigned(W-1 downto 0) := (others => '0');
  signal ip_dvs     : unsigned(W-1 downto 0) := (others => '0');
  signal ip_out_v   : std_logic;
  signal ip_rem     : unsigned(W-1 downto 0);

  function lfsr_next(v : std_logic_vector(15 downto 0)) return std_logic_vector is
    variable fb : std_logic;
  begin
    fb := v(15) xor v(13) xor v(12) xor v(10);
    return v(14 downto 0) & fb;
  end function;

begin

  busy <= '0' when state = S_IDLE else '1';
  done <= '1' when state = S_FIN  else '0';

  mod_s <= to_signed(MODULI(mi), W+1);
  add_s <= signed(resize(unsigned(lfsr(6 downto 0)), W+1)) - to_signed(64, W+1);
  sum_s <= acc_s + add_s;

  reist_step : entity work.reist_core
    generic map (W => W)
    port map (b => mod_s, sum => sum_s, r => cent_s);

  ip : entity work.ip_divider
    generic map (W => W, LATENCY => IP_LAT)
    port map (clk => clk, reset_n => reset_n,
              in_valid => ip_in_v, in_dividend => ip_dvd, in_divisor => ip_dvs,
              out_valid => ip_out_v, out_remainder => ip_rem);

  res_modulus <= to_unsigned(MODULI(res_index), 32);
  res_reist   <= reist_cyc(res_index);
  res_ipdep   <= ipdep_cyc(res_index);
  res_ipind   <= ipind_cyc(res_index);

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state  <= S_IDLE;
        mi     <= 0;
        ip_in_v<= '0';
      else
        ip_in_v <= '0';
        case state is

          when S_IDLE =>
            if start = '1' then
              mi <= 0; state <= R_SETUP;
            end if;

          -- ---- REIST dependency chain: 1 centered correction per clock ----
          when R_SETUP =>
            acc_s <= (others => '0'); lfsr <= LFSR_SEED;
            iter  <= 0; cyc <= (others => '0'); state <= R_STEP;

          when R_STEP =>
            acc_s <= cent_s;
            lfsr  <= lfsr_next(lfsr);
            cyc   <= cyc + 1;
            if iter = N_ITERS - 1 then state <= R_STORE; else iter <= iter + 1; end if;

          when R_STORE =>
            reist_cyc(mi) <= cyc; state <= D_SETUP;

          -- ---- divider IP, dependency chain: wait full latency each step ----
          when D_SETUP =>
            acc_u <= (others => '0'); lfsr <= LFSR_SEED;
            iter  <= 0; cyc <= (others => '0'); state <= D_ISSUE;

          when D_ISSUE =>
            ip_in_v <= '1';
            ip_dvd  <= acc_u + resize(unsigned(lfsr(6 downto 0)), W);
            ip_dvs  <= to_unsigned(MODULI(mi), W);
            lfsr    <= lfsr_next(lfsr);
            cyc     <= cyc + 1;
            state   <= D_WAIT;

          when D_WAIT =>
            cyc <= cyc + 1;
            if ip_out_v = '1' then
              acc_u <= ip_rem;
              if iter = N_ITERS - 1 then
                state <= D_STORE;
              else
                iter  <= iter + 1; state <= D_ISSUE;
              end if;
            end if;

          when D_STORE =>
            ipdep_cyc(mi) <= cyc; state <= I_SETUP;

          -- ---- divider IP, independent stream: one issue per clock ----
          when I_SETUP =>
            lfsr <= LFSR_SEED; iter <= 0; recv <= 0;
            cyc  <= (others => '0'); state <= I_RUN;

          when I_RUN =>
            cyc <= cyc + 1;
            if iter < N_ITERS then
              ip_in_v <= '1';
              ip_dvd  <= resize(unsigned(lfsr), W);   -- independent operand
              ip_dvs  <= to_unsigned(MODULI(mi), W);
              lfsr    <= lfsr_next(lfsr);
              iter    <= iter + 1;
            end if;
            if ip_out_v = '1' then
              if recv = N_ITERS - 1 then
                ipind_cyc(mi) <= cyc;
                state <= I_STORE;
              else
                recv <= recv + 1;
              end if;
            end if;

          when I_STORE =>
            if mi = NUM - 1 then state <= S_FIN;
            else mi <= mi + 1; state <= R_SETUP; end if;

          when S_NEXT =>
            state <= S_FIN;             -- unused, kept for clarity

          when S_FIN =>
            null;
        end case;
      end if;
    end if;
  end process;

end architecture;
