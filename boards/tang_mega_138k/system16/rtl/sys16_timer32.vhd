library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Minimal CLINT-style machine timer. Registers are 32-bit halves:
-- 00 msip, 08 mtimecmp_lo, 0c mtimecmp_hi, 10 mtime_lo, 14 mtime_hi.
entity sys16_timer32 is
  generic (CLK_HZ : positive := 50_000_000; TICK_HZ : positive := 1_000_000);
  port (
    clk, reset_n : in std_logic;
    req, we : in std_logic;
    addr : in std_logic_vector(4 downto 0);
    be : in std_logic_vector(3 downto 0);
    wdata : in std_logic_vector(31 downto 0);
    rdata : out std_logic_vector(31 downto 0);
    ready, timer_irq, software_irq : out std_logic
  );
end entity;

architecture rtl of sys16_timer32 is
  constant DIVISOR : positive := CLK_HZ / TICK_HZ;
  signal div : natural range 0 to DIVISOR-1 := 0;
  signal mtime : unsigned(63 downto 0) := (others => '0');
  signal mtimecmp : unsigned(63 downto 0) := (others => '1');
  signal msip : std_logic := '0';
  signal seen : std_logic := '0';
begin
  ready <= req and not seen;
  timer_irq <= '1' when mtime >= mtimecmp else '0';
  software_irq <= msip;
  with addr select rdata <=
    (31 downto 1 => '0') & msip when "00000",
    std_logic_vector(mtimecmp(31 downto 0)) when "01000",
    std_logic_vector(mtimecmp(63 downto 32)) when "01100",
    std_logic_vector(mtime(31 downto 0)) when "10000",
    std_logic_vector(mtime(63 downto 32)) when "10100",
    (others => '0') when others;

  process(clk)
    variable tmp : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        div <= 0; mtime <= (others => '0'); mtimecmp <= (others => '1');
        msip <= '0'; seen <= '0';
      else
        if div = DIVISOR-1 then div <= 0; mtime <= mtime + 1; else div <= div + 1; end if;
        if req = '0' then seen <= '0';
        elsif seen = '0' then
          seen <= '1';
          if we = '1' then
            case addr is
              when "00000" => if be(0) = '1' then msip <= wdata(0); end if;
              when "01000" => tmp := std_logic_vector(mtimecmp(31 downto 0)); for i in 0 to 3 loop if be(i)='1' then tmp(i*8+7 downto i*8):=wdata(i*8+7 downto i*8); end if; end loop; mtimecmp(31 downto 0)<=unsigned(tmp);
              when "01100" => tmp := std_logic_vector(mtimecmp(63 downto 32)); for i in 0 to 3 loop if be(i)='1' then tmp(i*8+7 downto i*8):=wdata(i*8+7 downto i*8); end if; end loop; mtimecmp(63 downto 32)<=unsigned(tmp);
              when "10000" => tmp := std_logic_vector(mtime(31 downto 0)); for i in 0 to 3 loop if be(i)='1' then tmp(i*8+7 downto i*8):=wdata(i*8+7 downto i*8); end if; end loop; mtime(31 downto 0)<=unsigned(tmp);
              when "10100" => tmp := std_logic_vector(mtime(63 downto 32)); for i in 0 to 3 loop if be(i)='1' then tmp(i*8+7 downto i*8):=wdata(i*8+7 downto i*8); end if; end loop; mtime(63 downto 32)<=unsigned(tmp);
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
