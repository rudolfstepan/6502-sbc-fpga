library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang138k_system16_top is
  port (
    clk_50mhz  : in  std_logic;
    key        : in  std_logic_vector(1 downto 0);
    led        : out std_logic_vector(3 downto 0);
    uart_rx    : in  std_logic;
    uart_tx    : out std_logic;
    sd_ncs     : out std_logic;
    sd_dclk    : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;
    dvi_a_psv  : out std_logic;
    dvi_a_hpd  : in  std_logic;
    dvi_ddc_clk : inout std_logic;
    dvi_ddc_dat : inout std_logic;
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0);
    sdram0_clk   : out   std_logic;
    sdram0_cs_n  : out   std_logic;
    sdram0_ras_n : out   std_logic;
    sdram0_cas_n : out   std_logic;
    sdram0_we_n  : out   std_logic;
    sdram0_ba    : out   std_logic_vector(1 downto 0);
    sdram0_addr  : out   std_logic_vector(12 downto 0);
    sdram0_dqm   : out   std_logic_vector(1 downto 0);
    sdram0_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of tang138k_system16_top is
  component sd_card_top is
    generic (
      SPI_LOW_SPEED_DIV  : integer := 248;
      SPI_HIGH_SPEED_DIV : integer := 0
    );
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      SD_nCS                 : out std_logic;
      SD_DCLK                : out std_logic;
      SD_MOSI                : out std_logic;
      SD_MISO                : in  std_logic;
      sd_init_done           : out std_logic;
      sd_sec_read            : in  std_logic;
      sd_sec_read_addr       : in  std_logic_vector(31 downto 0);
      sd_sec_read_data       : out std_logic_vector(7 downto 0);
      sd_sec_read_data_valid : out std_logic;
      sd_sec_read_end        : out std_logic;
      sd_sec_write           : in  std_logic;
      sd_sec_write_addr      : in  std_logic_vector(31 downto 0);
      sd_sec_write_data      : in  std_logic_vector(7 downto 0);
      sd_sec_write_data_req  : out std_logic;
      sd_sec_write_end       : out std_logic;
      debug_sec_state        : out std_logic_vector(4 downto 0);
      debug_cmd_state        : out std_logic_vector(3 downto 0);
      debug_cmd_error        : out std_logic
    );
  end component;

  signal reset_n      : std_logic;
  signal cpu_reset_n  : std_logic;
  signal sd_reset     : std_logic;
  signal por_count    : unsigned(7 downto 0) := (others => '0');
  signal video_status : std_logic_vector(15 downto 0);
  signal led_i        : std_logic_vector(3 downto 0);
  signal mem_req      : std_logic;
  signal mem_we       : std_logic;
  signal mem_addr     : std_logic_vector(23 downto 1);
  signal mem_be       : std_logic_vector(1 downto 0);
  signal mem_wdata    : std_logic_vector(15 downto 0);
  signal mem_rdata    : std_logic_vector(15 downto 0);
  signal mem_ready    : std_logic;
  signal boot_active  : std_logic;
  signal boot_done    : std_logic;
  signal boot_error   : std_logic;
  signal boot_entry   : std_logic_vector(23 downto 0);
  signal boot_mem_req   : std_logic;
  signal boot_mem_addr  : std_logic_vector(23 downto 1);
  signal boot_mem_be    : std_logic_vector(1 downto 0);
  signal boot_mem_wdata : std_logic_vector(15 downto 0);
  signal sdram_req      : std_logic;
  signal sdram_we       : std_logic;
  signal sdram_addr_i   : std_logic_vector(23 downto 1);
  signal sdram_be_i     : std_logic_vector(1 downto 0);
  signal sdram_wdata_i  : std_logic_vector(15 downto 0);
  signal sd_init_done   : std_logic;
  signal sd_sec_read    : std_logic;
  signal sd_sec_addr    : std_logic_vector(31 downto 0);
  signal sd_sec_data    : std_logic_vector(7 downto 0);
  signal sd_sec_valid   : std_logic;
  signal sd_sec_end     : std_logic;
begin
  process(clk_50mhz)
  begin
    if rising_edge(clk_50mhz) then
      if key(0) = '0' then
        por_count <= (others => '0');
      elsif por_count /= x"FF" then
        por_count <= por_count + 1;
      end if;
    end if;
  end process;

  reset_n <= '1' when key(0) = '1' and por_count = x"FF" else '0';
  led     <= led_i;

  boot_active <= not (boot_done or boot_error);
  cpu_reset_n <= reset_n and not boot_active;
  sd_reset    <= not reset_n;

  sdram_req     <= boot_mem_req   when boot_active = '1' else mem_req;
  sdram_we      <= '1'            when boot_active = '1' else mem_we;
  sdram_addr_i  <= boot_mem_addr  when boot_active = '1' else mem_addr;
  sdram_be_i    <= boot_mem_be    when boot_active = '1' else mem_be;
  sdram_wdata_i <= boot_mem_wdata when boot_active = '1' else mem_wdata;

  -- Match the established Tang Console 138K SDRAM0 implementation.
  sdram0_clk <= clk_50mhz;

  soc_i : entity work.sys16_soc
    port map (
      clk          => clk_50mhz,
      reset_n      => cpu_reset_n,
      boot_loaded  => boot_done,
      boot_entry   => boot_entry,
      uart_rx      => uart_rx,
      uart_tx      => uart_tx,
      mem_req      => mem_req,
      mem_we       => mem_we,
      mem_addr     => mem_addr,
      mem_be       => mem_be,
      mem_wdata    => mem_wdata,
      mem_rdata    => mem_rdata,
      mem_ready    => mem_ready,
      video_status => video_status,
      debug        => open,
      led          => led_i
    );

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 2
    )
    port map (
      clk                    => clk_50mhz,
      rst                    => sd_reset,
      SD_nCS                 => sd_ncs,
      SD_DCLK                => sd_dclk,
      SD_MOSI                => sd_mosi,
      SD_MISO                => sd_miso,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_addr,
      sd_sec_read_data       => sd_sec_data,
      sd_sec_read_data_valid => sd_sec_valid,
      sd_sec_read_end        => sd_sec_end,
      sd_sec_write           => '0',
      sd_sec_write_addr      => (others => '0'),
      sd_sec_write_data      => (others => '0'),
      sd_sec_write_data_req  => open,
      sd_sec_write_end       => open,
      debug_sec_state        => open,
      debug_cmd_state        => open,
      debug_cmd_error        => open
    );

  sd_boot_i : entity work.sys16_sd_bootloader
    port map (
      clk                    => clk_50mhz,
      reset_n                => reset_n,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_addr,
      sd_sec_read_data       => sd_sec_data,
      sd_sec_read_data_valid => sd_sec_valid,
      sd_sec_read_end        => sd_sec_end,
      mem_req                => boot_mem_req,
      mem_addr               => boot_mem_addr,
      mem_be                 => boot_mem_be,
      mem_wdata              => boot_mem_wdata,
      mem_ready              => mem_ready,
      boot_done              => boot_done,
      boot_error             => boot_error,
      boot_entry             => boot_entry,
      debug                  => open
    );

  sdram_i : entity work.sys16_sdram_bridge
    port map (
      clk         => clk_50mhz,
      reset_n     => reset_n,
      req         => sdram_req,
      we          => sdram_we,
      addr        => sdram_addr_i,
      be          => sdram_be_i,
      wdata       => sdram_wdata_i,
      rdata       => mem_rdata,
      ready       => mem_ready,
      init_done   => open,
      sdram_cs_n  => sdram0_cs_n,
      sdram_ras_n => sdram0_ras_n,
      sdram_cas_n => sdram0_cas_n,
      sdram_we_n  => sdram0_we_n,
      sdram_ba    => sdram0_ba,
      sdram_addr  => sdram0_addr,
      sdram_dqm   => sdram0_dqm,
      sdram_dq    => sdram0_dq
    );

  hdmi_i : entity work.sys16_hdmi_720p
    port map (
      clk_in     => clk_50mhz,
      reset_n    => reset_n,
      status_word => video_status,
      pll_lock   => open,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  dvi_a_psv   <= '0';
  dvi_ddc_clk <= 'Z';
  dvi_ddc_dat <= 'Z';
end architecture;
