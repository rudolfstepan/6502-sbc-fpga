library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_bram is
  generic (
    ADDR_BITS : natural := 14
  );
  port (
    clk   : in  std_logic;
    we    : in  std_logic;
    be    : in  std_logic_vector(1 downto 0);
    addr  : in  std_logic_vector(ADDR_BITS - 1 downto 0);
    din   : in  std_logic_vector(15 downto 0);
    dout  : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sys16_bram is
  type byte_ram_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- Separate byte lanes map the 68k byte enables onto two simple single-port
  -- memories. This is the native inference pattern for Gowin block RAM.
  signal ram_lo : byte_ram_t(0 to (2 ** ADDR_BITS) - 1) := (others => (others => '0'));
  signal ram_hi : byte_ram_t(0 to (2 ** ADDR_BITS) - 1) := (others => (others => '0'));
  signal q_lo   : std_logic_vector(7 downto 0) := (others => '0');
  signal q_hi   : std_logic_vector(7 downto 0) := (others => '0');

  attribute ram_style : string;
  attribute ram_style of ram_lo : signal is "block";
  attribute ram_style of ram_hi : signal is "block";

  attribute syn_ramstyle : string;
  attribute syn_ramstyle of ram_lo : signal is "block_ram";
  attribute syn_ramstyle of ram_hi : signal is "block_ram";
begin
  process(clk)
    variable index_v : natural;
  begin
    if rising_edge(clk) then
      index_v := to_integer(unsigned(addr));

      if we = '1' and be(0) = '1' then
        ram_lo(index_v) <= din(7 downto 0);
        q_lo <= din(7 downto 0);
      else
        q_lo <= ram_lo(index_v);
      end if;

      if we = '1' and be(1) = '1' then
        ram_hi(index_v) <= din(15 downto 8);
        q_hi <= din(15 downto 8);
      else
        q_hi <= ram_hi(index_v);
      end if;
    end if;
  end process;

  dout <= q_hi & q_lo;
end architecture;
