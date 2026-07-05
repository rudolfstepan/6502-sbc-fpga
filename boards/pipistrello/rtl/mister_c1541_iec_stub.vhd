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
    SD_PACKED_D64_FILE : boolean := false;
    SD_WRITE_ENABLE : boolean := false
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
    sd_sec_write           : out std_logic;
    sd_sec_write_addr      : out std_logic_vector(31 downto 0);
    sd_sec_write_data      : out std_logic_vector(7 downto 0);
    sd_sec_write_data_req  : in  std_logic := '0';
    sd_sec_write_end       : in  std_logic := '0';
    sd_mount_lba    : in std_logic_vector(31 downto 0) := (others => '0');
    sd_mount_strobe : in std_logic := '0';
    led : out std_logic;
    read_active  : out std_logic;
    write_active : out std_logic;
    write_byte_pulse   : out std_logic;
    write_commit_pulse : out std_logic;
    write_block_done_pulse : out std_logic;
    write_checksum_error_pulse : out std_logic;
    write_checksum_calc : out std_logic_vector(7 downto 0);
    write_checksum_recv : out std_logic_vector(7 downto 0);
    write_prev_data : out std_logic_vector(7 downto 0);
    write_last_data : out std_logic_vector(7 downto 0);
    write_debug : out std_logic_vector(7 downto 0);
    write_trace_addr : in  std_logic_vector(4 downto 0) := (others => '0');
    write_trace_data : out std_logic_vector(31 downto 0);
    write_trace_count : out std_logic_vector(5 downto 0);
    write_trace_clear : in  std_logic := '0'
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
  sd_sec_write <= '0';
  sd_sec_write_addr <= (others => '0');
  sd_sec_write_data <= (others => '0');
  led <= '0';
  read_active <= '0';
  write_active <= '0';
  write_byte_pulse <= '0';
  write_commit_pulse <= '0';
  write_block_done_pulse <= '0';
  write_checksum_error_pulse <= '0';
  write_checksum_calc <= (others => '0');
  write_checksum_recv <= (others => '0');
  write_prev_data <= (others => '0');
  write_last_data <= (others => '0');
  write_debug <= (others => '0');
  write_trace_data <= (others => '0');
  write_trace_count <= (others => '0');
end architecture;
