library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sys16_pkg.all;

entity sys16_soc is
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;
    boot_loaded  : in  std_logic;
    boot_entry   : in  std_logic_vector(23 downto 0);
    uart_rx      : in  std_logic;
    uart_tx      : out std_logic;
    mem_req      : out std_logic;
    mem_we       : out std_logic;
    mem_addr     : out std_logic_vector(23 downto 1);
    mem_be       : out std_logic_vector(1 downto 0);
    mem_wdata    : out word16_t;
    mem_rdata    : in  word16_t;
    mem_ready    : in  std_logic;
    video_status : out word16_t;
    debug        : out word16_t;
    led          : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of sys16_soc is
  component fx68k is
    port (
      clk       : in  std_logic;
      HALTn     : in  std_logic;
      extReset  : in  std_logic;
      pwrUp     : in  std_logic;
      enPhi1    : in  std_logic;
      enPhi2    : in  std_logic;
      eRWn      : out std_logic;
      ASn       : out std_logic;
      LDSn      : out std_logic;
      UDSn      : out std_logic;
      E         : out std_logic;
      VMAn      : out std_logic;
      FC0       : out std_logic;
      FC1       : out std_logic;
      FC2       : out std_logic;
      BGn       : out std_logic;
      oRESETn   : out std_logic;
      oHALTEDn  : out std_logic;
      DTACKn    : in  std_logic;
      VPAn      : in  std_logic;
      BERRn     : in  std_logic;
      BRn       : in  std_logic;
      BGACKn    : in  std_logic;
      IPL0n     : in  std_logic;
      IPL1n     : in  std_logic;
      IPL2n     : in  std_logic;
      iEdb      : in  std_logic_vector(15 downto 0);
      oEdb      : out std_logic_vector(15 downto 0);
      eab       : out std_logic_vector(23 downto 1)
    );
  end component;

  signal phi_div     : unsigned(1 downto 0) := (others => '0');
  signal en_phi1     : std_logic;
  signal en_phi2     : std_logic;
  signal reset_s     : std_logic;
  signal pwr_up      : std_logic;
  signal pwr_cnt     : unsigned(7 downto 0) := (others => '0');
  signal cpu_addr    : std_logic_vector(23 downto 1);
  signal cpu_data_in : word16_t := (others => '0');
  signal cpu_data_out : word16_t;
  signal cpu_rwn     : std_logic;
  signal cpu_asn     : std_logic;
  signal cpu_ldsn    : std_logic;
  signal cpu_udsn    : std_logic;
  signal cpu_e       : std_logic;
  signal cpu_vman    : std_logic;
  signal cpu_fc      : std_logic_vector(2 downto 0);
  signal cpu_bgn     : std_logic;
  signal cpu_resetn  : std_logic;
  signal cpu_haltedn : std_logic;
  signal cpu_dtackn  : std_logic;
  signal m68k_be     : std_logic_vector(1 downto 0);
  signal m68k_read   : std_logic;
  signal m68k_write  : std_logic;
  signal rom_sel     : std_logic;
  signal ram_sel     : std_logic;
  signal sdram_sel   : std_logic;
  signal io_sel      : std_logic;
  signal io_offset   : std_logic_vector(7 downto 0);
  signal uart_sel    : std_logic;
  signal uart_req    : std_logic;
  signal uart_we     : std_logic;
  signal rom_q       : word16_t;
  signal rom_bus_q   : word16_t;
  signal ram_q       : word16_t;
  signal uart_q      : word16_t;
  signal io_reg_q    : word16_t;
  signal io_q        : word16_t;
  signal ram_we      : std_logic;
  signal led_status  : word16_t := x"0001";
  signal video_ctrl  : word16_t := x"1234";
begin
  reset_s <= not reset_n;
  en_phi1 <= '1' when phi_div = "11" else '0';
  en_phi2 <= '1' when phi_div = "01" else '0';

  process(clk, reset_n)
  begin
    if reset_n = '0' then
      phi_div <= (others => '0');
      pwr_cnt <= (others => '0');
    elsif rising_edge(clk) then
      phi_div <= phi_div + 1;
      if pwr_cnt /= x"FF" then
        pwr_cnt <= pwr_cnt + 1;
      end if;
    end if;
  end process;

  pwr_up <= '1' when pwr_cnt /= x"FF" else '0';

  m68k_be(1) <= not cpu_udsn;
  m68k_be(0) <= not cpu_ldsn;
  io_offset <= cpu_addr(7 downto 1) & '0';
  m68k_read  <= '1' when cpu_asn = '0' and cpu_rwn = '1' else '0';
  m68k_write <= '1' when cpu_asn = '0' and cpu_rwn = '0' else '0';
  rom_sel <= '1' when cpu_addr(23 downto 10) = "00000000000000" else '0';
  ram_sel <= '1' when cpu_addr(23 downto 12) = x"000" and cpu_addr(11) = '1' else '0';
  sdram_sel <= '1' when cpu_addr(23 downto 12) /= x"000" and
                        cpu_addr(23 downto 20) /= x"F" else '0';
  io_sel  <= '1' when cpu_addr(23 downto 16) = SYS16_IO_BASE else '0';
  uart_sel <= '1' when io_offset = SYS16_REG_UART_DATA or
                            io_offset = SYS16_REG_UART_STAT or
                            io_offset = SYS16_REG_UART_RX else '0';
  uart_req <= '1' when cpu_asn = '0' and io_sel = '1' and uart_sel = '1' else '0';
  uart_we  <= not cpu_rwn;
  ram_we  <= '1' when m68k_write = '1' and ram_sel = '1' else '0';

  -- ASn precedes UDSn/LDSn on fx68k writes.  Start the external-memory
  -- transaction only once the selected byte lanes and write data are valid.
  mem_req   <= '1' when cpu_asn = '0' and sdram_sel = '1' and
                        (cpu_udsn = '0' or cpu_ldsn = '0') else '0';
  mem_we    <= not cpu_rwn;
  mem_addr  <= cpu_addr;
  mem_be    <= m68k_be;
  mem_wdata <= cpu_data_out;

  cpu_dtackn <= '0' when cpu_asn = '0' and
                        (sdram_sel = '0' or mem_ready = '1') else '1';

  cpu_i : fx68k
    port map (
      clk      => clk,
      HALTn    => '1',
      extReset => reset_s,
      pwrUp    => pwr_up,
      enPhi1   => en_phi1,
      enPhi2   => en_phi2,
      eRWn     => cpu_rwn,
      ASn      => cpu_asn,
      LDSn     => cpu_ldsn,
      UDSn     => cpu_udsn,
      E        => cpu_e,
      VMAn     => cpu_vman,
      FC0      => cpu_fc(0),
      FC1      => cpu_fc(1),
      FC2      => cpu_fc(2),
      BGn      => cpu_bgn,
      oRESETn  => cpu_resetn,
      oHALTEDn => cpu_haltedn,
      DTACKn   => cpu_dtackn,
      VPAn     => '1',
      BERRn    => '1',
      BRn      => '1',
      BGACKn   => '1',
      IPL0n    => '1',
      IPL1n    => '1',
      IPL2n    => '1',
      iEdb     => cpu_data_in,
      oEdb     => cpu_data_out,
      eab      => cpu_addr
    );

  ram_i : entity work.sys16_bram
    generic map (
      ADDR_BITS => SYS16_RAM_ADDR_BITS
    )
    port map (
      clk  => clk,
      we   => ram_we,
      be   => m68k_be,
      addr => cpu_addr(SYS16_RAM_ADDR_BITS downto 1),
      din  => cpu_data_out,
      dout => ram_q
    );

  rom_i : entity work.sys16_boot_rom
    port map (
      addr => cpu_addr(9 downto 1),
      dout => rom_q
    );

  process(rom_q, boot_loaded, boot_entry, cpu_addr)
  begin
    rom_bus_q <= rom_q;
    if boot_loaded = '1' then
      if cpu_addr(9 downto 1) = std_logic_vector(to_unsigned(2, 9)) then
        rom_bus_q <= x"00" & boot_entry(23 downto 16);
      elsif cpu_addr(9 downto 1) = std_logic_vector(to_unsigned(3, 9)) then
        rom_bus_q <= boot_entry(15 downto 0);
      end if;
    end if;
  end process;

  uart_i : entity work.sys16_uart
    generic map (
      CLK_HZ => 50_000_000,
      BAUD   => 115_200
    )
    port map (
      clk        => clk,
      reset_n    => reset_n,
      req        => uart_req,
      we         => uart_we,
      be         => m68k_be,
      reg_offset => io_offset,
      wdata      => cpu_data_out,
      rdata      => uart_q,
      uart_rx    => uart_rx,
      uart_tx    => uart_tx
    );

  process(clk, reset_n)
  begin
    if reset_n = '0' then
      led_status <= x"0001";
      video_ctrl <= x"1234";
    elsif rising_edge(clk) then
      if m68k_write = '1' and io_sel = '1' then
        case io_offset is
          when SYS16_REG_LED_STATUS =>
            led_status <= cpu_data_out;
          when SYS16_REG_VIDEO_CTRL =>
            video_ctrl <= cpu_data_out;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  with io_offset select
    io_reg_q <= led_status when SYS16_REG_LED_STATUS,
                video_ctrl when SYS16_REG_VIDEO_CTRL,
                x"DEAD"    when others;

  io_q <= uart_q when uart_sel = '1' else io_reg_q;

  cpu_data_in <= rom_bus_q when rom_sel = '1' else
                 ram_q when ram_sel = '1' else
                 io_q when io_sel = '1' else
                 mem_rdata when sdram_sel = '1' else
                 x"DEAD";

  video_status <= video_ctrl;
  debug <= cpu_addr(15 downto 4) & cpu_rwn & (not cpu_asn) & cpu_resetn & cpu_haltedn;
  led <= led_status(3 downto 0);
end architecture;
