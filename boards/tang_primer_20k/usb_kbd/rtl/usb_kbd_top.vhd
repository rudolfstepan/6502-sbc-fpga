-- ============================================================================
-- usb_kbd_top -- standalone Tang Primer 20K top to bring up a USB HID keyboard.
--
-- Minimal, self-contained bring-up harness for the nand2mario usb_hid_host core
-- (via the work.usb_hid_host VHDL wrapper). It shares nothing with the SBC/C64
-- builds. Purpose: get a low-speed (1.5 Mbps) USB keyboard enumerating and
-- typing, in isolation, so signal integrity / clock / wiring can be debugged
-- without the rest of the machine in the way.
--
-- What you see:
--   * LEDs  = USB phase nibble (active-low): 3 = idle/no device,
--             4 = device connected+enumerated, F = connection/protocol error.
--             (Same "PH" diagnostic used in the earlier attempt, now on LEDs.)
--   * UART  = every printable key you type is sent as its ASCII byte at
--             115200 8N1 on the CH340 TX (M11). Open a serial terminal to watch.
--
-- Physical wiring (USB-A breakout on PMOD 0, Bank 3):
--   usb_dp -> USB D+  (T7)   + 15 kOhm pull-down D+ to GND
--   usb_dm -> USB D-  (T8)   + 15 kOhm pull-down D- to GND
--   VBUS   -> 5 V  (supply externally to the keyboard)
--   GND    -> GND
--
-- Clocks:
--   clk_27mhz  27 MHz on-board oscillator (H11) -> system + register domain
--   usb_clk    12 MHz from rPLL (Gowin_rPLL_USB) -> nand2mario bit-bang engine
--
-- Reset:
--   Power-on only (held until the PLL locks). No external reset pin -- the dock
--   buttons are on dedicated SSPI/config pins that can't be GPIO here.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_kbd_top is
  generic (
    CLK_HZ : positive := 27_000_000;
    BAUD   : positive := 115_200
  );
  port (
    clk_27mhz : in    std_logic;
    -- No external reset pin: the dock buttons sit on dedicated SSPI/config pins
    -- (T10 etc.) that cannot be used as GPIO here, so reset is power-on only
    -- (also gated on PLL lock below). To re-run: reprogram or power-cycle.

    usb_dp    : inout std_logic;                     -- USB D+
    usb_dm    : inout std_logic;                     -- USB D-

    uart_tx   : out   std_logic;                     -- CH340 TX, 115200 8N1
    led       : out   std_logic_vector(3 downto 0)   -- active-low, USB phase
  );
end entity;

architecture rtl of usb_kbd_top is

  -- 27 MHz -> 12 MHz rPLL (defparams: IDIV_SEL=8, FBDIV_SEL=3, ODIV_SEL=48)
  component Gowin_rPLL_USB is
    port (
      clkout : out std_logic;
      lock   : out std_logic;
      reset  : in  std_logic;
      clkin  : in  std_logic
    );
  end component;

  signal usb_clk  : std_logic;
  signal pll_lock : std_logic;

  -- Reset: hold until PLL locked + a short power-on interval, then follow button
  signal por_cnt  : unsigned(15 downto 0) := (others => '0');
  signal reset_n  : std_logic := '0';

  -- Diagnostics out of the usb_hid_host wrapper (all in clk_27mhz domain)
  signal d_conn   : std_logic;
  signal d_key    : std_logic_vector(7 downto 0);
  signal d_mod    : std_logic_vector(7 downto 0);
  signal d_ascii  : std_logic_vector(7 downto 0);
  signal d_phase  : std_logic_vector(3 downto 0);
  signal d_kev    : std_logic;

  -- Key-event -> UART handshake (1-deep pending slot)
  signal kev_d     : std_logic := '0';
  signal pend      : std_logic := '0';
  signal pend_data : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid  : std_logic := '0';
  signal tx_busy   : std_logic;

begin

  -- --------------------------------------------------------------------------
  -- 12 MHz USB clock
  -- --------------------------------------------------------------------------
  pll_i : Gowin_rPLL_USB
    port map (
      clkout => usb_clk,
      lock   => pll_lock,
      reset  => '0',
      clkin  => clk_27mhz
    );

  -- --------------------------------------------------------------------------
  -- Reset generation (clk_27mhz domain)
  -- --------------------------------------------------------------------------
  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      if pll_lock = '0' then
        por_cnt <= (others => '0');
        reset_n <= '0';
      elsif por_cnt /= x"FFFF" then
        por_cnt <= por_cnt + 1;
        reset_n <= '0';
      else
        reset_n <= '1';                   -- released after lock + power-on hold
      end if;
    end if;
  end process;

  -- --------------------------------------------------------------------------
  -- USB HID host (register interface unused here: cs/we tied off)
  -- --------------------------------------------------------------------------
  usb_i : entity work.usb_hid_host
    port map (
      clk            => clk_27mhz,
      reset_n        => reset_n,
      usb_clk        => usb_clk,
      usb_dm         => usb_dm,
      usb_dp         => usb_dp,
      cs             => '0',
      we             => '0',
      addr           => "00",
      dout           => open,
      irq            => open,
      diag_connected => d_conn,
      diag_keycode   => d_key,
      diag_modif     => d_mod,
      diag_ascii     => d_ascii,
      diag_phase     => d_phase,
      diag_key_event => d_kev,
      diag_polling   => open
    );

  -- LEDs (active-low) show the USB phase nibble: 3 idle, 4 connected, F error
  led <= not d_phase;

  -- --------------------------------------------------------------------------
  -- Forward each printable keypress to the UART
  -- --------------------------------------------------------------------------
  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      tx_valid <= '0';                    -- default: single-cycle pulse
      kev_d    <= d_kev;
      if reset_n = '0' then
        pend <= '0';
      else
        -- New HID report: capture the ASCII if it is a printable key
        if (d_kev /= kev_d) and (d_ascii /= x"00") then
          pend_data <= d_ascii;
          pend      <= '1';
        end if;
        -- Push the pending byte once the serializer is free
        if pend = '1' and tx_busy = '0' and tx_valid = '0' then
          tx_data  <= pend_data;
          tx_valid <= '1';
          pend     <= '0';
        end if;
      end if;
    end if;
  end process;

  uart_i : entity work.uart_tx_ser
    generic map (
      CLK_HZ => CLK_HZ,
      BAUD   => BAUD
    )
    port map (
      clk     => clk_27mhz,
      reset_n => reset_n,
      data    => tx_data,
      valid   => tx_valid,
      tx      => uart_tx,
      busy    => tx_busy
    );

end architecture;
