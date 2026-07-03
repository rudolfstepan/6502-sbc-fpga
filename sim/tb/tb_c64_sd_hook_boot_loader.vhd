library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench for the standalone SD hook boot loader.
--
-- Phase 1: valid "C64HOOK1" image, SD ready immediately.  Expects every
--          payload byte at load_addr+i, the signature byte at load_addr
--          written last, and a clean release with success status.
-- Phase 2: corrupted magic.  Expects release without a single RAM write
--          and the gave-up status bit.
-- Phase 3: SD becomes ready only after the hold window.  Expects the C64
--          to be released first (active -> 0 while done = 0), then a late
--          re-pause copy with a phase-specific payload.
-- Phase 4: SD never serves the read request.  Expects RETRY_MAX attempts,
--          then a release with the gave-up status bit.
entity tb_c64_sd_hook_boot_loader is
end entity;

architecture sim of tb_c64_sd_hook_boot_loader is
  constant CLK_PERIOD : time := 1 us;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';

  signal sd_init_done : std_logic := '0';
  signal sd_read      : std_logic;
  signal sd_addr      : std_logic_vector(31 downto 0);
  signal sd_data      : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_valid     : std_logic := '0';
  signal sd_end       : std_logic := '0';

  signal mem_we    : std_logic;
  signal mem_addr  : std_logic_vector(15 downto 0);
  signal mem_wdata : std_logic_vector(7 downto 0);
  signal active    : std_logic;
  signal done      : std_logic;
  signal status    : std_logic_vector(7 downto 0);

  constant HOOK_LBA  : integer := 8;
  constant LOAD_ADDR : integer := 16#C000#;
  constant PAY_LEN   : integer := 600;

  signal phase : integer := 1;

  type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  signal write_count : integer := 0;
  signal last_write_addr : integer := -1;
  signal sim_done : boolean := false;

  function payload_byte(i : integer; ph : integer) return std_logic_vector is
  begin
    if ph = 3 then
      return std_logic_vector(to_unsigned((i * 5 + 7) mod 256, 8));
    end if;
    return std_logic_vector(to_unsigned((i * 7 + 3) mod 256, 8));
  end function;

  -- Byte k (0-511) of on-card block b (relative to HOOK_LBA).
  function card_byte(b : integer; k : integer; ph : integer) return std_logic_vector is
    constant magic : string := "C64HOOK1";
    variable pay : integer;
  begin
    if b = 0 and k <= 7 then
      if ph = 2 and k = 3 then
        return x"FF";                 -- corrupt one magic byte
      end if;
      return std_logic_vector(to_unsigned(character'pos(magic(k + 1)), 8));
    elsif b = 0 and k = 8 then
      return std_logic_vector(to_unsigned(LOAD_ADDR mod 256, 8));
    elsif b = 0 and k = 9 then
      return std_logic_vector(to_unsigned(LOAD_ADDR / 256, 8));
    elsif b = 0 and k = 10 then
      return std_logic_vector(to_unsigned(PAY_LEN mod 256, 8));
    elsif b = 0 and k = 11 then
      return std_logic_vector(to_unsigned(PAY_LEN / 256, 8));
    elsif b = 0 and k <= 15 then
      return x"00";
    end if;
    if b = 0 then
      pay := k - 16;
    else
      pay := 496 + (b - 1) * 512 + k;
    end if;
    if pay < PAY_LEN then
      return payload_byte(pay, ph);
    end if;
    return x"AA";                     -- filler past the image
  end function;
begin
  clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

  dut : entity work.c64_sd_hook_boot_loader
    generic map (
      HOOK_LBA     => std_logic_vector(to_unsigned(HOOK_LBA, 32)),
      MAX_LEN      => 4096,
      CLK_HZ       => 1000000,
      HOLD_MS      => 3,
      COPY_MS      => 20,
      RETRY_GAP_MS => 1,
      RETRY_MAX    => 2
    )
    port map (
      clk     => clk,
      reset_n => reset_n,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_read,
      sd_sec_read_addr       => sd_addr,
      sd_sec_read_data       => sd_data,
      sd_sec_read_data_valid => sd_valid,
      sd_sec_read_end        => sd_end,
      mem_we    => mem_we,
      mem_addr  => mem_addr,
      mem_wdata => mem_wdata,
      active    => active,
      done      => done,
      status    => status
    );

  -- RAM write capture
  process(clk)
  begin
    if rising_edge(clk) then
      if mem_we = '1' then
        ram(to_integer(unsigned(mem_addr))) <= mem_wdata;
        write_count <= write_count + 1;
        last_write_addr <= to_integer(unsigned(mem_addr));
      end if;
    end if;
  end process;

  -- SD block server: reacts to read pulses, streams 512 bytes + end.
  -- In phase 4 it plays dead and never answers.
  process
    variable blk : integer;
  begin
    while not sim_done loop
      wait until rising_edge(clk);
      if sd_read = '1' and phase /= 4 then
        blk := to_integer(unsigned(sd_addr)) - HOOK_LBA;
        for k in 0 to 511 loop
          wait until rising_edge(clk);
          wait until rising_edge(clk);
          sd_data <= card_byte(blk, k, phase);
          sd_valid <= '1';
          wait until rising_edge(clk);
          sd_valid <= '0';
        end loop;
        wait until rising_edge(clk);
        sd_end <= '1';
        wait until rising_edge(clk);
        sd_end <= '0';
      end if;
    end loop;
    wait;
  end process;

  stimulus : process
    variable errors : integer := 0;
    variable base_writes : integer;
  begin
    -- Phase 1: valid image, SD ready from the start
    phase <= 1;
    reset_n <= '0';
    sd_init_done <= '0';
    wait for 10 * CLK_PERIOD;
    reset_n <= '1';
    wait for 5 * CLK_PERIOD;
    assert active = '1' report "phase1: not active after reset" severity error;
    sd_init_done <= '1';
    wait until done = '1' for 50 ms;
    assert done = '1' report "phase1: no done" severity error;
    wait for 5 * CLK_PERIOD;
    assert active = '0' report "phase1: still active" severity error;
    for i in 0 to PAY_LEN - 1 loop
      if ram(LOAD_ADDR + i) /= payload_byte(i, 1) then
        errors := errors + 1;
      end if;
    end loop;
    assert errors = 0
      report "phase1: payload mismatches: " & integer'image(errors)
      severity error;
    assert write_count = PAY_LEN
      report "phase1: write count " & integer'image(write_count)
      severity error;
    assert last_write_addr = LOAD_ADDR
      report "phase1: signature byte was not written last"
      severity error;
    assert status(1) = '1' and status(3) = '0'
      report "phase1: status not success" severity error;

    -- Phase 2: bad magic -> release without writes
    phase <= 2;
    base_writes := write_count;
    reset_n <= '0';
    sd_init_done <= '0';
    wait for 10 * CLK_PERIOD;
    reset_n <= '1';
    sd_init_done <= '1';
    wait until done = '1' for 50 ms;
    assert done = '1' report "phase2: no done" severity error;
    wait for 5 * CLK_PERIOD;
    assert active = '0' report "phase2: still active" severity error;
    assert write_count = base_writes
      report "phase2: wrote RAM despite bad magic"
      severity error;
    assert status(3) = '1' and status(1) = '0'
      report "phase2: status not gave-up" severity error;

    -- Phase 3: SD ready only after the hold window -> late re-pause copy
    phase <= 3;
    reset_n <= '0';
    sd_init_done <= '0';
    wait for 10 * CLK_PERIOD;
    reset_n <= '1';
    wait for 6 ms;                    -- HOLD_MS is 3 ms
    assert active = '0' and done = '0'
      report "phase3: C64 not released while waiting for the card"
      severity error;
    sd_init_done <= '1';
    wait for 5 * CLK_PERIOD;
    assert active = '1'
      report "phase3: no re-pause for the late copy" severity error;
    wait until done = '1' for 50 ms;
    assert done = '1' report "phase3: no done" severity error;
    wait for 5 * CLK_PERIOD;
    assert active = '0' report "phase3: still active" severity error;
    errors := 0;
    for i in 0 to PAY_LEN - 1 loop
      if ram(LOAD_ADDR + i) /= payload_byte(i, 3) then
        errors := errors + 1;
      end if;
    end loop;
    assert errors = 0
      report "phase3: payload mismatches: " & integer'image(errors)
      severity error;
    assert last_write_addr = LOAD_ADDR
      report "phase3: signature byte was not written last"
      severity error;
    assert status(1) = '1' report "phase3: status not success" severity error;

    -- Phase 4: SD never answers the read -> retries, then give up
    phase <= 4;
    base_writes := write_count;
    reset_n <= '0';
    sd_init_done <= '0';
    wait for 10 * CLK_PERIOD;
    reset_n <= '1';
    sd_init_done <= '1';
    wait until done = '1' for 100 ms;
    assert done = '1' report "phase4: never gave up" severity error;
    wait for 5 * CLK_PERIOD;
    assert active = '0' report "phase4: still active" severity error;
    assert write_count = base_writes
      report "phase4: wrote RAM despite dead SD" severity error;
    assert status(3) = '1' and status(1) = '0'
      report "phase4: status not gave-up" severity error;

    report "tb_c64_sd_hook_boot_loader: all phases passed" severity note;
    sim_done <= true;
    wait;
  end process;
end architecture;
