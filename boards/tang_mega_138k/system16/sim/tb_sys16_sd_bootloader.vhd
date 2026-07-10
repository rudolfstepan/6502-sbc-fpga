library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sys16_sd_bootloader is
end entity;

architecture sim of tb_sys16_sd_bootloader is
  signal clk       : std_logic := '0';
  signal reset_n   : std_logic := '0';
  signal init_done : std_logic := '0';
  signal sd_read   : std_logic;
  signal sd_lba    : std_logic_vector(31 downto 0);
  signal sd_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_valid  : std_logic := '0';
  signal sd_end    : std_logic := '0';
  signal mem_req   : std_logic;
  signal mem_addr  : std_logic_vector(23 downto 1);
  signal mem_be    : std_logic_vector(1 downto 0);
  signal mem_wdata : std_logic_vector(15 downto 0);
  signal mem_ready : std_logic := '0';
  signal boot_done : std_logic;
  signal boot_error: std_logic;
  signal boot_entry: std_logic_vector(23 downto 0);
  signal debug     : std_logic_vector(3 downto 0);
  signal writes    : natural := 0;

  function header_byte(index : natural) return std_logic_vector is
  begin
    case index is
      when 0 => return x"53"; when 1 => return x"59";
      when 2 => return x"53"; when 3 => return x"31";
      when 4 => return x"36"; when 5 => return x"53";
      when 6 => return x"44"; when 7 => return x"31";
      when 8 => return x"00"; when 9 => return x"10"; when 10 => return x"00";
      when 11 => return x"00"; when 12 => return x"10"; when 13 => return x"00";
      when 14 => return x"00"; when 15 => return x"00";
      when 16 => return x"00"; when 17 => return x"04";
      when 18 => return x"00"; when 19 => return x"00";
      when 20 => return x"01"; when 21 => return x"46";
      when others => return x"00";
    end case;
  end function;
begin
  clk <= not clk after 10 ns;

  dut : entity work.sys16_sd_bootloader
    generic map (WATCHDOG_CYCLES => 10000)
    port map (
      clk => clk, reset_n => reset_n,
      sd_init_done => init_done,
      sd_sec_read => sd_read, sd_sec_read_addr => sd_lba,
      sd_sec_read_data => sd_data,
      sd_sec_read_data_valid => sd_valid, sd_sec_read_end => sd_end,
      mem_req => mem_req, mem_addr => mem_addr, mem_be => mem_be,
      mem_wdata => mem_wdata, mem_ready => mem_ready,
      boot_done => boot_done, boot_error => boot_error,
      boot_entry => boot_entry, debug => debug
    );

  stimulus : process
    procedure send_byte(value : std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      sd_data  <= value;
      sd_valid <= '1';
      wait until rising_edge(clk);
      sd_valid <= '0';
      for gap in 1 to 8 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;
  begin
    wait for 100 ns;
    wait until rising_edge(clk);
    reset_n <= '1';
    wait until rising_edge(clk);
    init_done <= '1';
    wait until sd_read = '1';
    assert unsigned(sd_lba) = 0 report "header LBA mismatch" severity failure;
    for index in 0 to 511 loop
      send_byte(header_byte(index));
    end loop;
    wait until rising_edge(clk);
    sd_end <= '1';
    wait until rising_edge(clk);
    sd_end <= '0';

    wait until sd_read = '1';
    assert unsigned(sd_lba) = 1 report "payload LBA mismatch" severity failure;
    send_byte(x"12");
    send_byte(x"34");
    send_byte(x"56");
    send_byte(x"AA");

    if boot_done = '0' and boot_error = '0' then
      wait until boot_done = '1' or boot_error = '1';
    end if;
    assert boot_error = '0' report "loader reported boot error" severity failure;
    assert boot_entry = x"001000" report "entry mismatch" severity failure;
    assert writes = 2 report "write count mismatch" severity failure;
    report "tb_sys16_sd_bootloader PASS" severity note;
    wait;
  end process;

  timeout_guard : process
  begin
    wait for 200 us;
    assert boot_done = '1'
      report "loader timeout, state=" & integer'image(to_integer(unsigned(debug)))
      severity failure;
    wait;
  end process;

  memory_model : process(clk)
    variable delay_count : natural range 0 to 2 := 0;
    variable wait_release : boolean := false;
  begin
    if rising_edge(clk) then
      mem_ready <= '0';
      if wait_release then
        if mem_req = '0' then
          wait_release := false;
        end if;
      elsif mem_req = '1' and delay_count = 0 then
        delay_count := 2;
      elsif delay_count > 1 then
        delay_count := delay_count - 1;
      elsif delay_count = 1 then
        delay_count := 0;
        wait_release := true;
        mem_ready <= '1';
        if writes = 0 then
          assert mem_addr = std_logic_vector(to_unsigned(16#001000# / 2, 23))
            report "first write address mismatch" severity failure;
          assert mem_wdata = x"1234" report "first write data mismatch" severity failure;
        elsif writes = 1 then
          assert mem_addr = std_logic_vector(to_unsigned(16#001002# / 2, 23))
            report "second write address mismatch: got word address " &
                   integer'image(to_integer(unsigned(mem_addr))) severity failure;
          assert mem_wdata = x"56AA" report "second write data mismatch" severity failure;
        end if;
        assert mem_be = "11" report "byte enables mismatch" severity failure;
        writes <= writes + 1;
      end if;
    end if;
  end process;
end architecture;
