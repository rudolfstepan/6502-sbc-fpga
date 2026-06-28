-- Tang Primer 20K board top -- native C64 over HDMI.
--
-- Reuses the SBC board's proven clock/HDMI plumbing (tang20k_hdmi_tx: 27 MHz ->
-- 135 MHz TMDS + 27 MHz pixel) and the PT8211 audio DAC. The machine itself is
-- c64_core (rtl/c64). No SD boot loader / boot screen here -- the original KERNAL
-- paints its own banner, which saves block RAM and LUTs.
--
-- KEY[0] = T10 (active-low reset button) -> C64 reset.
-- PS/2 keyboard on PMOD0 (T7 clk / T8 data).
-- HDMI TMDS on the on-board connector. Audio on the dock PT8211.
library ieee;
use ieee.std_logic_1164.all;
-- use ieee.numeric_std.all;   -- (only needed by the disabled DIAG heartbeat)

entity tang20k_c64_top is
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(0 downto 0);  -- KEY[0] = reset button (T10)

    ps2_clk    : in  std_logic;
    ps2_data   : in  std_logic;

    dac_bck    : out std_logic;
    dac_ws     : out std_logic;
    dac_din    : out std_logic;
    pa_en      : out std_logic;

    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0);

    -- DIAG heartbeat LEDs -- disabled (placement experiment); re-enable with the
    -- block below, the led pins in the .cst, and dbg_cia1_irq in c64_core.
    -- led     : out std_logic_vector(1 downto 0);

    -- CH340 USB-UART. In this diagnostic build it streams c64_dbg_uart output;
    -- the host-disk UART inside c64_core is temporarily disconnected.
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic
  );
end entity;

architecture rtl of tang20k_c64_top is
  signal clk_pix  : std_logic;
  signal clk_sys  : std_logic;
  signal pll_lock : std_logic;

  signal reset_n   : std_logic;
  signal rst_sync  : std_logic_vector(2 downto 0) := (others => '0');
  signal key0_sync : std_logic_vector(2 downto 0) := (others => '1');

  signal vga_hs, vga_vs, vga_de : std_logic;
  signal vga_r, vga_b : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal audio        : std_logic_vector(15 downto 0);

  signal dbg_addr   : std_logic_vector(15 downto 0);
  signal dbg_we     : std_logic;
  signal dbg_do     : std_logic_vector(7 downto 0);
  signal dbg_di     : std_logic_vector(7 downto 0);
  signal dbg_sync   : std_logic;
  signal dbg_phi    : std_logic;
  signal dbg_status : std_logic_vector(15 downto 0);
  signal dbg_cia1   : std_logic_vector(31 downto 0);
  signal dbg_regs   : std_logic_vector(63 downto 0);

  -- DIAG heartbeat taps -- DISABLED (placement experiment). Re-enable the led port,
  -- the .cst led pins, dbg_cia1_irq in c64_core, and this whole block together.
  -- signal dbg_sync     : std_logic;
  -- signal dbg_cia1_irq : std_logic;
  -- signal sync_d       : std_logic := '0';
  -- signal cpu_cnt      : unsigned(19 downto 0) := (others => '0');
  -- signal irq_low_cnt  : unsigned(21 downto 0) := (others => '0');
  -- signal irq_stuck    : std_logic := '0';
begin
  pa_en <= '1';   -- enable dock audio power amplifier

  -- process(clk_pix)
  -- begin
  --   if rising_edge(clk_pix) then
  --     sync_d <= dbg_sync;
  --     if dbg_sync = '1' and sync_d = '0' then
  --       cpu_cnt <= cpu_cnt + 1;
  --     end if;
  --     if dbg_cia1_irq = '1' then
  --       irq_low_cnt <= (others => '0');
  --     elsif irq_low_cnt(21) = '1' then
  --       irq_stuck <= '1';
  --     else
  --       irq_low_cnt <= irq_low_cnt + 1;
  --     end if;
  --   end if;
  -- end process;
  -- led(0) <= not irq_stuck;
  -- led(1) <= cpu_cnt(19);

  -- Reset: hold until the PLL locks and the button is released, in the pixel domain.
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      key0_sync <= key0_sync(1 downto 0) & key(0);
      rst_sync  <= rst_sync(1 downto 0) & (pll_lock and key0_sync(2));
    end if;
  end process;
  reset_n <= rst_sync(2);

  -- HDMI TX also generates the system/pixel clocks from the 27 MHz oscillator.
  hdmi_i : entity work.tang20k_hdmi_tx
    port map (
      clk_in   => clk_27mhz,
      reset_n  => '1',
      vga_de   => vga_de,
      vga_hs   => vga_hs,
      vga_vs   => vga_vs,
      vga_r    => vga_r,
      vga_g    => vga_g,
      vga_b    => vga_b,
      clk_sys  => clk_sys,
      clk_pix  => clk_pix,
      pll_lock => pll_lock,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  -- The C64 itself, clocked by the 27 MHz pixel clock (PHI2_DIV=27 -> ~1 MHz CPU,
  -- authentic C64 speed; the half-speed test (54) proved the hang is NOT a setup-
  -- margin path, so back to the correct rate).
  c64_i : entity work.c64_core
    port map (
      clk      => clk_pix,
      reset_n  => reset_n,
      dbg_addr => dbg_addr,
      dbg_we   => dbg_we,
      dbg_do   => dbg_do,
      dbg_di   => dbg_di,
      dbg_sync => dbg_sync,
      dbg_phi  => dbg_phi,
      dbg_status => dbg_status,
      dbg_cia1 => dbg_cia1,
      dbg_regs => dbg_regs,
      -- dbg_cia1_irq => open,   -- (DIAG heartbeat tap -- disabled)
      vga_hs   => vga_hs,
      vga_vs   => vga_vs,
      vga_de   => vga_de,
      vga_r    => vga_r,
      vga_g    => vga_g,
      vga_b    => vga_b,
      ps2_clk  => ps2_clk,
      ps2_data => ps2_data,
      audio    => audio,
      uart_tx  => open,
      uart_rx  => '1'
    );

  dbg_uart_i : entity work.c64_dbg_uart
    generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
    port map (
      clk        => clk_pix,
      reset_n    => reset_n,
      snp_addr   => dbg_addr,
      snp_we     => dbg_we,
      snp_do     => dbg_do,
      snp_di     => dbg_di,
      snp_sync   => dbg_sync,
      snp_phi    => dbg_phi,
      snp_status => dbg_status,
      snp_cia1   => dbg_cia1,
      snp_regs   => dbg_regs,
      uart_tx    => uart_tx
    );

  -- Audio DAC (PT8211), pixel-clock domain (BCK_HALF=4 -> ~27/8 MHz BCK).
  dac_i : entity work.pt8211_dac
    generic map (BCK_HALF => 4)
    port map (
      clk     => clk_pix,
      reset_n => reset_n,
      sample  => audio,
      dac_bck => dac_bck,
      dac_ws  => dac_ws,
      dac_din => dac_din
    );
end architecture;
