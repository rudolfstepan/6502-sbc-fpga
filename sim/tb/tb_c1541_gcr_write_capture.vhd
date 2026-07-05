library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_c1541_gcr_write_capture is
  generic (
    LSB_FIRST : boolean := false;
    CHECKSUM_INCLUDES_MARKER : boolean := false
  );
end entity;

architecture sim of tb_c1541_gcr_write_capture is
  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';
  signal done  : boolean := false;

  signal din       : std_logic_vector(7 downto 0) := x"FF";
  signal dout      : std_logic_vector(7 downto 0);
  signal sync_n    : std_logic;
  signal byte_n    : std_logic;
  signal wr_en     : std_logic;
  signal wr_data   : std_logic_vector(7 downto 0);
  signal wr_offset : std_logic_vector(7 downto 0);
  signal wr_commit : std_logic;

  signal img_track  : std_logic_vector(7 downto 0);
  signal img_sector : std_logic_vector(4 downto 0);
  signal img_offset : std_logic_vector(7 downto 0);

  signal captured_count : integer := 0;
  signal commit_seen    : boolean := false;

  function pattern(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 37 + 16#5A#) mod 256, 8));
  end function;

  function gcr_encode(value : std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    case value is
      when x"0" => return "01010";
      when x"1" => return "11010";
      when x"2" => return "01001";
      when x"3" => return "11001";
      when x"4" => return "01110";
      when x"5" => return "11110";
      when x"6" => return "01101";
      when x"7" => return "11101";
      when x"8" => return "10010";
      when x"9" => return "10011";
      when x"A" => return "01011";
      when x"B" => return "11011";
      when x"C" => return "10110";
      when x"D" => return "10111";
      when x"E" => return "01111";
      when others => return "10101";
    end case;
  end function;
begin
  clk <= not clk after 18 ns when not done else '0';

  dut : entity work.c1541_static_dir_gcr
    generic map (
      GCR_TURBO => 8
    )
    port map (
      clk    => clk,
      ce     => '1',
      reset  => reset,
      dout   => dout,
      din    => din,
      mode   => '0',
      mtr    => '1',
      freq   => "00",
      sync_n => sync_n,
      byte_n => byte_n,
      track  => std_logic_vector(to_unsigned(34, 7)),
      we        => wr_en,
      wr_data   => wr_data,
      wr_offset => wr_offset,
      wr_commit => wr_commit,
      wr_block_done => open,
      wr_checksum_error => open,
      wr_checksum_calc => open,
      wr_checksum_recv => open,
      wr_prev_data => open,
      wr_last_data => open,
      wr_debug => open,
      wr_trace_addr => (others => '0'),
      wr_trace_data => open,
      wr_trace_count => open,
      wr_trace_clear => '0',
      wr_stall  => '0',
      img_track  => img_track,
      img_sector => img_sector,
      img_offset => img_offset,
      img_dout   => x"00",
      img_valid  => '1'
    );

  monitor : process(clk)
    variable off : integer;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        captured_count <= 0;
        commit_seen <= false;
      else
        if wr_en = '1' then
          off := to_integer(unsigned(wr_offset));
          assert off = captured_count
            report "wrong write offset: " & integer'image(off) &
                   " expected " & integer'image(captured_count)
            severity failure;
          assert wr_data = pattern(off)
            report "wrong write data at offset " & integer'image(off)
                   & ": got " & integer'image(to_integer(unsigned(wr_data)))
                   & " expected " & integer'image(to_integer(unsigned(pattern(off))))
            severity failure;
          captured_count <= captured_count + 1;
        end if;

        if wr_commit = '1' then
          assert captured_count = 256
            report "commit before full sector: " & integer'image(captured_count)
            severity failure;
          commit_seen <= true;
        end if;
      end if;
    end if;
  end process;

  stim : process
    variable out_byte  : std_logic_vector(7 downto 0) := (others => '0');
    variable out_count : integer range 0 to 7 := 0;
    variable cks       : std_logic_vector(7 downto 0) := (others => '0');

    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;

    procedure send_raw_byte(b : std_logic_vector(7 downto 0)) is
      variable timeout : integer := 0;
    begin
      loop
        tick;
        exit when byte_n = '0';
        timeout := timeout + 1;
        assert timeout < 2000 report "timeout waiting for byte_n" severity failure;
      end loop;
      din <= b;
      loop
        tick;
        exit when byte_n = '1';
      end loop;
    end procedure;

    procedure emit_bit(b : std_logic) is
    begin
      if LSB_FIRST then
        out_byte(out_count) := b;
      else
        out_byte(7 - out_count) := b;
      end if;

      if out_count = 7 then
        send_raw_byte(out_byte);
        out_byte := (others => '0');
        out_count := 0;
      else
        out_count := out_count + 1;
      end if;
    end procedure;

    procedure emit_gcr_byte(b : std_logic_vector(7 downto 0)) is
      variable g : std_logic_vector(4 downto 0);
    begin
      -- The local gcr_encode table stores the codes bit-reversed (same as
      -- the DUT's); emitting index 0 first puts the STANDARD GCR bit order
      -- on the wire, exactly like the 1541 DOS packs its table values
      -- MSB-first into $1C01 (and like the DUT's own read path emits).
      g := gcr_encode(b(7 downto 4));
      for i in 0 to 4 loop
        emit_bit(g(i));
      end loop;

      g := gcr_encode(b(3 downto 0));
      for i in 0 to 4 loop
        emit_bit(g(i));
      end loop;
    end procedure;
  begin
    for i in 1 to 20 loop
      tick;
    end loop;
    reset <= '0';
    din <= x"FF";

    for i in 1 to 10 loop
      send_raw_byte(x"FF");
    end loop;

    emit_gcr_byte(x"07");
    for i in 0 to 255 loop
      emit_gcr_byte(pattern(i));
      if i = 0 then
        cks := pattern(i);
      else
        cks := cks xor pattern(i);
      end if;
    end loop;
    if CHECKSUM_INCLUDES_MARKER then
      cks := cks xor x"07";
    end if;
    emit_gcr_byte(cks);
    emit_gcr_byte(x"00");
    emit_gcr_byte(x"00");

    for i in 1 to 50000 loop
      tick;
      if commit_seen then
        report "tb_c1541_gcr_write_capture passed";
        done <= true;
        finish;
      end if;
    end loop;

    assert false
      report "timeout waiting for wr_commit, captured_count=" & integer'image(captured_count)
      severity failure;
  end process;
end architecture;
