library ieee;
use ieee.std_logic_1164.all;

entity mister_c1541_iec is
  generic (
    CLK_HZ       : integer := 27000000;
    DRIVE_CPU_HZ : integer := 1000000;
    BAUD         : integer := 230400;
    GCR_TURBO    : integer := 1;
    D64_BACKEND  : integer := 0;
    SD_D64_LBA : std_logic_vector(31 downto 0) := x"00000000";
    SD_PACKED_D64_FILE : boolean := false
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    iec_atn_n  : in  std_logic;
    iec_clk_n  : in  std_logic;
    iec_data_n : in  std_logic;
    drive_clk_pull_n  : out std_logic;
    drive_data_pull_n : out std_logic;
    sdram_addr  : out std_logic_vector(22 downto 0);
    sdram_rd    : out std_logic;
    sdram_q     : in  std_logic_vector(7 downto 0) := (others => '0');
    sdram_valid : in  std_logic := '0';
    sdram_ready : in  std_logic := '0';
    uart_rx : in  std_logic := '1';
    uart_tx : out std_logic;
    sd_init_done           : in  std_logic := '0';
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0) := (others => '0');
    sd_sec_read_data_valid : in  std_logic := '0';
    sd_sec_read_end        : in  std_logic := '0';
    sd_mount_lba    : in std_logic_vector(31 downto 0) := (others => '0');
    sd_mount_strobe : in std_logic := '0';
    led : out std_logic
  );
end entity;

architecture stub of mister_c1541_iec is
begin
  drive_clk_pull_n <= '1';
  drive_data_pull_n <= '1';
  sdram_addr <= (others => '0');
  sdram_rd <= '0';
  uart_tx <= '1';
  sd_sec_read <= '0';
  sd_sec_read_addr <= (others => '0');
  led <= '0';
end architecture;
