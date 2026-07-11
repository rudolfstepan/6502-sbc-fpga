library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang138k_system16_rv32_top is
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

architecture rtl of tang138k_system16_rv32_top is
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
  signal cpu_release_count : unsigned(7 downto 0) := (others=>'0');
  signal sd_reset     : std_logic;
  signal boot_reset_n : std_logic;
  signal sd_retry_reset : std_logic := '0';
  signal sd_retry_count : natural range 0 to 1_000_000 := 0;
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
  signal rv_req, rv_we, rv_ready : std_logic;
  signal rv_addr, rv_wdata, rv_rdata : std_logic_vector(31 downto 0);
  signal rv_be : std_logic_vector(3 downto 0);
  signal cpu_seen, uart_seen : std_logic;
  signal bridge_alive, fetch_seen : std_logic;
  signal fetch_rsp_seen : std_logic;
  signal sbi_fetch_seen, data_req_seen, data_rsp_seen, kernel_fetch_seen : std_logic;
  signal sbi_progress : std_logic_vector(3 downto 0);
  signal last_fetch_addr : std_logic_vector(31 downto 0);
  signal ram_probe_req, ram_probe_done, ram_probe_failed : std_logic;
  signal ram_probe_addr : std_logic_vector(23 downto 1);
  signal cpu_uart_tx, probe_tx, probe_active, probe_done : std_logic;
  signal pc_tx,pc_active,pc_done,pc_start:std_logic;
  signal pc_timer:unsigned(27 downto 0):=(others=>'0');
  signal boot_active  : std_logic;
  signal boot_done    : std_logic;
  signal boot_error   : std_logic;
  signal boot_entry   : std_logic_vector(23 downto 0);
  signal boot_debug   : std_logic_vector(3 downto 0);
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
  -- Assert immediately, deassert synchronously only after SDRAM ownership has
  -- been back with the CPU side for 256 clocks. This also gives the 32->16
  -- bridge and VexRiscv cache logic a clean common reset release.
  process(clk_50mhz)
  begin
    if rising_edge(clk_50mhz) then
      if reset_n='0' or boot_active='1' then
        cpu_release_count <= (others=>'0');
      elsif cpu_release_count/=x"FF" then
        cpu_release_count <= cpu_release_count+1;
      end if;
    end if;
  end process;
  cpu_reset_n <= '1' when reset_n='1' and ram_probe_done='1' and
                         ram_probe_failed='0' and probe_done='1' and
                         cpu_release_count=x"FF" else '0';
  -- Some cards occasionally fail their SPI power-up negotiation. A watchdog
  -- timeout resets both the card controller and bootloader for 20 ms and then
  -- retries from sector zero instead of remaining permanently in ERROR.
  boot_reset_n <= reset_n and not sd_retry_reset;
  sd_reset    <= not boot_reset_n;
  process(clk_50mhz)
  begin
    if rising_edge(clk_50mhz) then
      if reset_n='0' then
        sd_retry_reset<='0';sd_retry_count<=0;
      elsif sd_retry_reset='1' then
        if sd_retry_count=999_999 then
          sd_retry_reset<='0';sd_retry_count<=0;
        else
          sd_retry_count<=sd_retry_count+1;
        end if;
      elsif boot_error='1' and boot_debug=x"1" then
        sd_retry_reset<='1';sd_retry_count<=0;
      end if;
    end if;
  end process;

  sdram_req     <= boot_mem_req when boot_active='1' else ram_probe_req when ram_probe_done='0' else mem_req;
  sdram_we      <= '1' when boot_active='1' else '0' when ram_probe_done='0' else mem_we;
  sdram_addr_i  <= boot_mem_addr when boot_active='1' else ram_probe_addr when ram_probe_done='0' else mem_addr;
  sdram_be_i    <= boot_mem_be when boot_active='1' else "11" when ram_probe_done='0' else mem_be;
  sdram_wdata_i <= boot_mem_wdata when boot_active='1' else (others=>'0') when ram_probe_done='0' else mem_wdata;

  ram_probe_i:entity work.sys16_sdram_probe
    port map(clk=>clk_50mhz,reset_n=>reset_n,start=>boot_done,mem_req=>ram_probe_req,
             mem_addr=>ram_probe_addr,mem_rdata=>mem_rdata,mem_ready=>mem_ready,
             done=>ram_probe_done,failed=>ram_probe_failed);

  -- Match the established Tang Console 138K SDRAM0 implementation.
  sdram0_clk <= clk_50mhz;

  soc_i : entity work.sys16_rv32_soc
    port map (
      clk          => clk_50mhz, reset_n => cpu_reset_n,
      bus_req      => rv_req, bus_we => rv_we, bus_addr => rv_addr,
      bus_wdata    => rv_wdata, bus_be => rv_be, bus_rdata => rv_rdata,
      bus_ready    => rv_ready, external_irq => '0',
      uart_rx      => uart_rx, uart_tx => cpu_uart_tx,
      cpu_seen=>cpu_seen,uart_seen=>uart_seen,
      bridge_alive=>bridge_alive,fetch_seen=>fetch_seen,fetch_rsp_seen=>fetch_rsp_seen,
      sbi_fetch_seen=>sbi_fetch_seen,data_req_seen=>data_req_seen,
      data_rsp_seen=>data_rsp_seen,kernel_fetch_seen=>kernel_fetch_seen,
      sbi_progress=>sbi_progress,last_fetch_addr=>last_fetch_addr
    );

  uart_probe_i:entity work.sys16_uart_probe
    port map(clk=>clk_50mhz,reset_n=>reset_n,start=>boot_done,
             tx=>probe_tx,active=>probe_active,done=>probe_done);
  process(clk_50mhz)begin if rising_edge(clk_50mhz)then pc_start<='0';
    if cpu_reset_n='0'then pc_timer<=(others=>'0');
    elsif pc_done='0'then
      if pc_timer=to_unsigned(249_999_999,pc_timer'length)then pc_start<='1';
      else pc_timer<=pc_timer+1;end if;
    end if;end if;end process;
  pc_report_i:entity work.sys16_uart_pc_reporter
    port map(clk=>clk_50mhz,reset_n=>reset_n,start=>pc_start,pc=>last_fetch_addr,
             tx=>pc_tx,active=>pc_active,done=>pc_done);
  uart_tx <= probe_tx when probe_active='1' else pc_tx when pc_active='1' else cpu_uart_tx;

  rv_mem_i : entity work.sys16_bus32_to_sdram16
    port map (
      clk=>clk_50mhz, reset_n=>cpu_reset_n, req=>rv_req, we=>rv_we,
      addr=>rv_addr, be=>rv_be, wdata=>rv_wdata, rdata=>rv_rdata,
      ready=>rv_ready, mem_req=>mem_req, mem_we=>mem_we, mem_addr=>mem_addr,
      mem_be=>mem_be, mem_wdata=>mem_wdata, mem_rdata=>mem_rdata,
      mem_ready=>mem_ready
    );

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      -- The bootloader currently commits each 16-bit word directly to SDRAM
      -- and cannot back-pressure the sector byte stream. Leave enough clocks
      -- between bytes for the SDRAM request/ready/drop handshake; DIV=2 can
      -- overrun it and silently corrupt large Linux/OpenSBI images.
      SPI_HIGH_SPEED_DIV => 8
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
    generic map (LITTLE_ENDIAN => true)
    port map (
      clk                    => clk_50mhz,
      reset_n                => boot_reset_n,
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
      debug                  => boot_debug
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
  -- HDMI boot diagnostics: yellow=loading, red=SD/header/checksum error,
  -- green=payload loaded and RV32 CPU released.
  video_status <= x"F800" when ram_probe_failed='1' else               -- red: SDRAM readback
                  x"F81F" when boot_error='1' and boot_debug=x"1" else -- magenta: timeout
                  x"F800" when boot_error='1' and boot_debug=x"2" else -- red: header
                  x"001F" when boot_error='1' and boot_debug=x"3" else -- blue: checksum
                  x"FFFF" when boot_error='1' else
                  x"07E0" when boot_done='1' and kernel_fetch_seen='1' else -- green: Linux fetch
                  x"801F" when boot_done='1' and sbi_progress=x"4" else -- violet: >= 0x3000
                  x"07FF" when boot_done='1' and sbi_progress=x"3" else -- cyan: >= 0x2100
                  x"FD20" when boot_done='1' and sbi_progress=x"2" else -- orange: relocation done
                  x"FFE0" when boot_done='1' and sbi_progress=x"1" else -- yellow: atomic passed
                  x"001F" when boot_done='1' and data_rsp_seen='1' else -- blue: data response
                  x"F800" when boot_done='1' and data_req_seen='1' else -- red: data request
                  x"FFE0" when boot_done='1' and sbi_fetch_seen='1' else -- yellow: OpenSBI fetch
                  x"FFFF" when boot_done='1' and uart_seen='1' else -- white: shim UART only
                  x"801F" when boot_done='1' and fetch_rsp_seen='1' else -- violet: fetch response
                  x"07FF" when boot_done='1' and fetch_seen='1' else -- cyan: raw Vex fetch
                  x"FD20" when boot_done='1' and bridge_alive='1' else -- orange: core out of reset
                  x"07E0" when boot_done='1' else                  -- green: released, no bus
                  x"FFE0";
  led_i <= boot_debug when boot_error='1' else sbi_progress;
  dvi_ddc_clk <= 'Z';
  dvi_ddc_dat <= 'Z';
end architecture;
