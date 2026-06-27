-- ============================================================================
-- Sequential unsigned divider (restoring), fixed W-cycle latency.
--
-- This is the classical baseline the REIST path is measured against: the
-- "division-based remainder handling" a compiler emits for the % operator.
-- One bit of quotient per clock, W clocks per division regardless of operand
-- magnitude -- the same fixed-latency behaviour as a CPU integer divide.
--
-- Restoring (not non-restoring) was chosen for clarity and provable
-- correctness; both are multi-cycle real dividers, so the architectural point
-- of the benchmark (a full divide per step vs. one conditional correction) is
-- identical either way.
--
-- Handshake: pulse 'start' with dividend/divisor valid; 'busy' stays high for
-- the run; 'done' pulses for one cycle when quotient/remainder are valid.
-- divisor = 0 is treated as a no-op (remainder = dividend, quotient = all ones).
-- VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_divider is
  generic (
    W : positive := 32
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    start     : in  std_logic;
    dividend  : in  unsigned(W-1 downto 0);
    divisor   : in  unsigned(W-1 downto 0);
    quotient  : out unsigned(W-1 downto 0);
    remainder : out unsigned(W-1 downto 0);
    busy      : out std_logic;
    done      : out std_logic
  );
end entity;

architecture rtl of seq_divider is
  type state_t is (S_IDLE, S_RUN, S_FIN);
  signal state  : state_t := S_IDLE;
  signal rem_r  : unsigned(W downto 0)   := (others => '0');  -- partial remainder (W+1)
  signal dd_r   : unsigned(W-1 downto 0) := (others => '0');  -- dividend, consumed MSB-first
  signal dv_r   : unsigned(W-1 downto 0) := (others => '0');  -- latched divisor
  signal q_r    : unsigned(W-1 downto 0) := (others => '0');
  signal cnt    : integer range 0 to W   := 0;
  signal done_r : std_logic := '0';
begin
  busy      <= '0' when state = S_IDLE else '1';
  done      <= done_r;
  quotient  <= q_r;
  remainder <= rem_r(W-1 downto 0);

  process(clk)
    variable sh : unsigned(W downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state  <= S_IDLE;
        done_r <= '0';
        rem_r  <= (others => '0');
        q_r    <= (others => '0');
        cnt    <= 0;
      else
        done_r <= '0';
        case state is
          when S_IDLE =>
            if start = '1' then
              rem_r <= (others => '0');
              q_r   <= (others => '0');
              dd_r  <= dividend;
              dv_r  <= divisor;
              cnt   <= W;
              state <= S_RUN;
            end if;

          when S_RUN =>
            -- shift partial remainder left, pull in the next dividend MSB
            sh := rem_r(W-1 downto 0) & dd_r(W-1);
            dd_r <= dd_r(W-2 downto 0) & '0';
            if sh >= ('0' & dv_r) then
              rem_r <= sh - ('0' & dv_r);
              q_r   <= q_r(W-2 downto 0) & '1';
            else
              rem_r <= sh;
              q_r   <= q_r(W-2 downto 0) & '0';
            end if;
            if cnt = 1 then
              state <= S_FIN;
            else
              cnt <= cnt - 1;
            end if;

          when S_FIN =>
            done_r <= '1';
            state  <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
