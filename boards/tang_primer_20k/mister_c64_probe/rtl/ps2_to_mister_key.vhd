library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_to_mister_key is
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;
    ps2_clk  : in  std_logic;
    ps2_data : in  std_logic;
    ps2_key  : out std_logic_vector(10 downto 0)
  );
end entity;

architecture rtl of ps2_to_mister_key is
  signal clk_sr        : std_logic_vector(2 downto 0) := (others => '1');
  signal bit_count     : unsigned(3 downto 0) := (others => '0');
  signal shift_reg     : std_logic_vector(10 downto 0) := (others => '1');
  signal key_reg       : std_logic_vector(10 downto 0) := (others => '0');
  signal break_seen    : std_logic := '0';
  signal extended_seen : std_logic := '0';
begin
  ps2_key <= key_reg;

  process(clk)
    variable next_sr   : std_logic_vector(10 downto 0);
    variable scan_code : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      clk_sr <= clk_sr(1 downto 0) & ps2_clk;

      if reset_n = '0' then
        bit_count <= (others => '0');
        shift_reg <= (others => '1');
        key_reg <= (others => '0');
        break_seen <= '0';
        extended_seen <= '0';
      elsif clk_sr(2 downto 1) = "10" then
        -- Same PS/2 frame receiver style as the native C64 keyboard matrix:
        -- shift the raw data bit on each filtered PS/2 clock falling edge.
        next_sr := ps2_data & shift_reg(10 downto 1);
        shift_reg <= next_sr;

        if bit_count = 10 then
          bit_count <= (others => '0');
          scan_code := next_sr(8 downto 1);

          if scan_code = x"E0" then
            extended_seen <= '1';
          elsif scan_code = x"F0" then
            break_seen <= '1';
          else
            key_reg(10) <= not key_reg(10);
            key_reg(9) <= not break_seen;
            key_reg(8) <= extended_seen;
            key_reg(7 downto 0) <= scan_code;
            break_seen <= '0';
            extended_seen <= '0';
          end if;
        else
          bit_count <= bit_count + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
