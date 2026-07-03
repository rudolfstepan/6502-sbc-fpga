library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity pipistrello_sbc_minimal_top is
  generic (
    ROM_INIT_FILE : string := "../../../sim/hex/rom_welcome.hex"
  );
  port (
    clk_50mhz  : in  std_logic;
    reset_btn  : in  std_logic;
    vga_out_r  : out std_logic_vector(2 downto 0);
    vga_out_g  : out std_logic_vector(2 downto 0);
    vga_out_b  : out std_logic_vector(2 downto 0);
    vga_hsync_n : out std_logic;
    vga_vsync_n : out std_logic;
    led        : out std_logic_vector(1 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic
  );
end entity;

architecture rtl of pipistrello_sbc_minimal_top is
  signal reset_n       : std_logic;
  signal via_portb     : data_t;
  signal uart_tx_data  : data_t;
  signal uart_tx_valid : std_logic;
  signal uart_tx_busy  : std_logic;
  signal vga_r_full    : std_logic_vector(4 downto 0);
  signal vga_g_full    : std_logic_vector(5 downto 0);
  signal vga_b_full    : std_logic_vector(4 downto 0);
begin

  reset_n <= not reset_btn;
  led <= via_portb(1 downto 0);
  vga_out_r <= vga_r_full(4 downto 2);
  vga_out_g <= vga_g_full(5 downto 3);
  vga_out_b <= vga_b_full(4 downto 2);

  sbc_i : entity work.sbc_minimal_top
    generic map (
      ROM_INIT_FILE => ROM_INIT_FILE,
      CLK_DIV       => 2
    )
    port map (
      clk           => clk_50mhz,
      reset_n       => reset_n,
      vga_r         => vga_r_full,
      vga_g         => vga_g_full,
      vga_b         => vga_b_full,
      vga_hs        => vga_hsync_n,
      vga_vs        => vga_vsync_n,
      vga_de        => open,
      via_portb     => via_portb,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  uart_ser : entity work.uart_tx_ser
    port map (
      clk     => clk_50mhz,
      reset_n => reset_n,
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

end architecture;
