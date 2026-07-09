-- UART keyboard register backend.
--
-- Drop-in replacement for the PS/2/USB keyboard register file:
--   +0 STATUS  R   [7]=connected [0]=key_ready
--   +1 KEY     R   last received byte, read clears key_ready
--   +2 MODIF   R   always 0
--   +3 ASCII   R   last received ASCII byte, read clears key_ready
--
-- The UART deserializer lives outside this block. This module only converts its
-- byte-valid strobe into the small keyboard register interface used by firmware.
library ieee;
use ieee.std_logic_1164.all;

entity uart_keyboard is
  port (
    clk            : in  std_logic;
    reset_n        : in  std_logic;
    rx_data        : in  std_logic_vector(7 downto 0);
    rx_valid       : in  std_logic;
    cs             : in  std_logic;
    we             : in  std_logic;
    addr           : in  std_logic_vector(1 downto 0);
    dout           : out std_logic_vector(7 downto 0);
    irq            : out std_logic;
    diag_connected : out std_logic;
    diag_keycode   : out std_logic_vector(7 downto 0);
    diag_modif     : out std_logic_vector(7 downto 0);
    diag_ascii     : out std_logic_vector(7 downto 0);
    diag_phase     : out std_logic_vector(3 downto 0);
    diag_key_event : out std_logic;
    diag_polling   : out std_logic
  );
end entity;

architecture rtl of uart_keyboard is
  signal key_r       : std_logic_vector(7 downto 0) := (others => '0');
  signal ascii_r     : std_logic_vector(7 downto 0) := (others => '0');
  signal key_ready   : std_logic := '0';
  signal key_ev_tog  : std_logic := '0';
  signal last_was_cr : std_logic := '0';

  function normalize_ascii(c : std_logic_vector(7 downto 0))
    return std_logic_vector is
  begin
    if c = x"7F" then
      return x"08"; -- terminal DEL/backspace -> BS
    elsif c = x"0A" then
      return x"0D"; -- LF-only terminal enter -> CR
    else
      return c;
    end if;
  end function;
begin
  process(clk)
    variable ch : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        key_r       <= (others => '0');
        ascii_r     <= (others => '0');
        key_ready   <= '0';
        key_ev_tog  <= '0';
        last_was_cr <= '0';
      else
        if rx_valid = '1' then
          ch := normalize_ascii(rx_data);

          if rx_data = x"0A" and last_was_cr = '1' then
            last_was_cr <= '0';
          else
            key_r      <= ch;
            ascii_r    <= ch;
            key_ready  <= '1';
            key_ev_tog <= not key_ev_tog;
            if ch = x"0D" then
              last_was_cr <= '1';
            else
              last_was_cr <= '0';
            end if;
          end if;
        end if;

        if cs = '1' and we = '0' then
          if addr = "01" or addr = "11" then
            key_ready <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  process(cs, we, addr, key_ready, key_r, ascii_r)
  begin
    dout <= (others => '0');
    if cs = '1' and we = '0' then
      case addr is
        when "00"   => dout <= '1' & "000000" & key_ready;
        when "01"   => dout <= key_r;
        when "10"   => dout <= (others => '0');
        when others => dout <= ascii_r;
      end case;
    end if;
  end process;

  irq <= key_ready;

  diag_connected <= '1';
  diag_keycode   <= key_r;
  diag_modif     <= (others => '0');
  diag_ascii     <= ascii_r;
  diag_phase     <= x"5";
  diag_key_event <= key_ev_tog;
  diag_polling   <= '1';
end architecture;
