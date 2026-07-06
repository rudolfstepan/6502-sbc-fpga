-- ============================================================================
-- usb_otg_diag_top -- Tang Primer 20K OTG-port (USB3317 ULPI PHY) bring-up.
--
-- The dock's USB-OTG connector is NOT a bare D+/D- pair -- it is wired to an
-- on-board Microchip USB3317 Hi-Speed USB PHY through an 8-bit ULPI bus
-- (clk/dir/nxt/stp + data[7:0], PHY RESETB). The 26 MHz PHY reference clock and
-- the 60 MHz ULPI CLKOUT are generated on the dock; the FPGA receives CLKOUT on
-- ulpi_clk (T15). Because of this, the low-speed nand2mario bit-bang core CANNOT
-- drive this port -- ULPI needs a completely different controller.
--
-- This is a *bring-up* design, not a keyboard yet: it wires the existing
-- work.usb_ulpi_diag sampler to the PHY, releases it from reset, reads the four
-- USB3317 ULPI ID registers + a scratch write/read test, and prints the result
-- over UART. It proves the OTG port, the PHY and the ULPI bus are alive -- the
-- necessary foundation before a USB host stack can be added.
--
-- Expected result on the UART (115200 8N1, CH340 / M11), one line ~2x/second:
--   ID=xxxx0424 S=xx
-- The printed ID is reg3 reg2 reg1 reg0 (MSB first). A working USB3317 returns
-- vendor ID 0x0424 (SMSC/Microchip), so reg1 reg0 = 04 24 -> the line ends in
-- "0424"; the leading four hex are the product-ID registers. Status bits:
--   [7] ULPI clock seen  [6] ULPI domain running  [5] DIR seen  [4] NXT seen
--   [3] DATA changed     [2] DIR now  [1] NXT now  [0] 4 ID registers read
--
-- Pins (boards/tang_primer_20k/usb_otg/usb_otg.cst) -- from the Sipeed
-- TangPrimer-20K-example USB demo constraints:
--   ulpi_clk T15  ulpi_dir K12  ulpi_nxt K13  ulpi_stp K11  ulpi_rst F10
--   ulpi_data[7:0] R12 P13 R13 T14 H13 J12 H12 G11
--   clk_27mhz H11  uart_tx M11  led[3:0] L16/L14/N14/N16  (reset = power-on only)
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_otg_diag_top is
  generic (
    CLK_HZ      : positive := 27_000_000;
    BAUD        : positive := 115_200;
    LINE_PERIOD : positive := 13_500_000    -- ~0.5 s between report lines
  );
  port (
    clk_27mhz : in    std_logic;
    -- No external reset pin: the dock buttons sit on dedicated SSPI/config pins
    -- (T10 etc.) that cannot be used as GPIO here, so reset is power-on only.
    -- To re-run: reprogram, or power-cycle / replug USB.

    ulpi_clk  : in    std_logic;                     -- 60 MHz CLKOUT from PHY
    ulpi_dir  : in    std_logic;
    ulpi_nxt  : in    std_logic;
    ulpi_stp  : out   std_logic;
    ulpi_rst  : out   std_logic;                     -- PHY RESETB (active-low)
    ulpi_data : inout std_logic_vector(7 downto 0);

    uart_tx   : out   std_logic;
    led       : out   std_logic_vector(3 downto 0)   -- active-low status
  );
end entity;

architecture rtl of usb_otg_diag_top is

  constant MSG_LEN : positive := 18;

  -- Reset: short power-on hold, then follow the button
  signal por_cnt : unsigned(15 downto 0) := (others => '0');
  signal reset_n : std_logic := '0';

  -- usb_ulpi_diag interface
  signal d_data_i  : std_logic_vector(7 downto 0);
  signal d_data_o  : std_logic_vector(7 downto 0);
  signal d_data_oe : std_logic;
  signal d_status  : std_logic_vector(7 downto 0);
  signal d_id      : std_logic_vector(31 downto 0);

  -- UART line printer
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid : std_logic := '0';
  signal tx_busy  : std_logic;

  signal line_id  : std_logic_vector(31 downto 0) := (others => '0');
  signal line_st  : std_logic_vector(7 downto 0)  := (others => '0');
  signal idx      : integer range 0 to MSG_LEN-1  := 0;
  signal sending  : std_logic := '0';
  signal tick_cnt : unsigned(23 downto 0) := (others => '0');

  function nib(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : integer;
  begin
    v := to_integer(unsigned(n));
    if v < 10 then
      return std_logic_vector(to_unsigned(16#30# + v, 8));      -- '0'..'9'
    else
      return std_logic_vector(to_unsigned(16#41# + v - 10, 8)); -- 'A'..'F'
    end if;
  end function;

  function msg_byte(i  : integer;
                    id : std_logic_vector(31 downto 0);
                    st : std_logic_vector(7 downto 0))
    return std_logic_vector is
  begin
    case i is
      when 0      => return x"49";                 -- 'I'
      when 1      => return x"44";                 -- 'D'
      when 2      => return x"3D";                 -- '='
      when 3      => return nib(id(31 downto 28));
      when 4      => return nib(id(27 downto 24));
      when 5      => return nib(id(23 downto 20));
      when 6      => return nib(id(19 downto 16));
      when 7      => return nib(id(15 downto 12));
      when 8      => return nib(id(11 downto 8));
      when 9      => return nib(id(7 downto 4));
      when 10     => return nib(id(3 downto 0));
      when 11     => return x"20";                 -- ' '
      when 12     => return x"53";                 -- 'S'
      when 13     => return x"3D";                 -- '='
      when 14     => return nib(st(7 downto 4));
      when 15     => return nib(st(3 downto 0));
      when 16     => return x"0D";                 -- CR
      when others => return x"0A";                 -- LF
    end case;
  end function;

begin

  -- --------------------------------------------------------------------------
  -- Reset generation (clk_27mhz domain). reset_n low also holds the PHY in
  -- reset (ulpi_rst = reset_n), so no ULPI clock is produced until released.
  -- --------------------------------------------------------------------------
  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      if por_cnt /= x"FFFF" then
        por_cnt <= por_cnt + 1;
        reset_n <= '0';
      else
        reset_n <= '1';                   -- released after power-on interval
      end if;
    end if;
  end process;

  -- --------------------------------------------------------------------------
  -- ULPI data bus tristate (DIR from PHY selects direction; the diag sampler
  -- asserts d_data_oe only while it is allowed to drive)
  -- --------------------------------------------------------------------------
  ulpi_data <= d_data_o when d_data_oe = '1' else (others => 'Z');
  d_data_i  <= ulpi_data;

  diag_i : entity work.usb_ulpi_diag
    generic map (
      DO_SCRATCH_TEST => false           -- just read the 4 ID regs and report
    )
    port map (
      clk          => clk_27mhz,
      reset_n      => reset_n,
      ulpi_clk     => ulpi_clk,
      ulpi_dir     => ulpi_dir,
      ulpi_nxt     => ulpi_nxt,
      ulpi_data_i  => d_data_i,
      ulpi_data_o  => d_data_o,
      ulpi_data_oe => d_data_oe,
      ulpi_stp     => ulpi_stp,
      ulpi_rst     => ulpi_rst,
      status       => d_status,
      phy_id       => d_id
    );

  -- LEDs (active-low): [0]=clk seen [1]=running [2]=DIR seen [3]=test done
  led <= not (d_status(7) & d_status(6) & d_status(5) & d_status(0));

  -- --------------------------------------------------------------------------
  -- Periodic UART line: "ID=xxxxxxxx S=xx\r\n"
  -- --------------------------------------------------------------------------
  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      tx_valid <= '0';                    -- default single-cycle pulse
      if reset_n = '0' then
        sending  <= '0';
        idx      <= 0;
        tick_cnt <= (others => '0');
      elsif sending = '0' then
        if tick_cnt = to_unsigned(LINE_PERIOD-1, tick_cnt'length) then
          tick_cnt <= (others => '0');
          line_id  <= d_id;               -- snapshot for the whole line
          line_st  <= d_status;
          idx      <= 0;
          sending  <= '1';
        else
          tick_cnt <= tick_cnt + 1;
        end if;
      else
        if tx_busy = '0' and tx_valid = '0' then
          tx_data  <= msg_byte(idx, line_id, line_st);
          tx_valid <= '1';
          if idx = MSG_LEN-1 then
            sending <= '0';
          else
            idx <= idx + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  uart_i : entity work.uart_tx_ser
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (
      clk     => clk_27mhz,
      reset_n => reset_n,
      data    => tx_data,
      valid   => tx_valid,
      tx      => uart_tx,
      busy    => tx_busy
    );

end architecture;
