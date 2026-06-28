-- C64 core: board-independent Commodore 64 in one entity.
--
-- Wires the native building blocks into a working machine:
--   cpu6510  -- T65 + processor port ($00/$01) for ROM banking
--   64K DRAM -- single-port BSRAM, time-shared with the VIC steal bus
--   ROMs     -- original BASIC/KERNAL/CHARGEN (rtl/c64/c64_roms.vhd)
--   vic_ii   -- text-mode video + raster IRQ (HDMI-ready RGB565)
--   colour_ram, 2x cia6526_full, sid6581, keyboard matrix
--
-- Banking is the PLA decode from c64_pkg (unexpanded machine: GAME=EXROM=1).
-- "RAM under ROM": writes always reach DRAM unless the address is I/O, so the
-- KERNAL's RAM scribbles beneath BASIC/KERNAL work as on real hardware.
--
-- Deliberately NO boot screen / SD boot loader here (saves BSRAM + LUTs, and
-- the original KERNAL paints its own startup banner). D64 LOAD support hooks in
-- at the IEC stub below and reuses the existing d64_subsystem (Milestone 1b).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.c64_pkg.all;

entity c64_core is
  generic (
    -- System clocks per PHI2 (27 -> ~1 MHz CPU). Simulation overrides this with
    -- a small value to boot faster.
    PHI2_DIV : integer := 27;
    -- Simulation-only RAM preload (ADDR VALUE hex); "" = zeroed (synthesis).
    RAM_INIT : string  := ""
  );
  port (
    clk      : in  std_logic;                       -- 27 MHz pixel + system clock
    reset_n  : in  std_logic;

    -- Debug taps (leave open in synthesis; used by the testbench).
    dbg_addr : out std_logic_vector(15 downto 0);
    dbg_we   : out std_logic;
    dbg_do   : out std_logic_vector(7 downto 0);
    dbg_di   : out std_logic_vector(7 downto 0);
    dbg_sync : out std_logic;
    dbg_phi  : out std_logic;
    dbg_cia1_irq : out std_logic;                   -- CIA1 IRQ line (heartbeat tap)

    -- Video (RGB565 split, to the HDMI encoder).
    vga_hs   : out std_logic;
    vga_vs   : out std_logic;
    vga_de   : out std_logic;
    vga_r    : out std_logic_vector(4 downto 0);
    vga_g    : out std_logic_vector(5 downto 0);
    vga_b    : out std_logic_vector(4 downto 0);

    -- PS/2 keyboard.
    ps2_clk  : in  std_logic;
    ps2_data : in  std_logic;

    -- SID audio sample (signed 16-bit), to the board DAC.
    audio    : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of c64_core is
  -- ---- clocking ----
  signal phi2_cnt   : integer range 0 to PHI2_DIV - 1 := 0;
  signal phi2_en    : std_logic := '0';
  signal tod_tick   : std_logic := '0';

  -- ---- CPU ----
  signal cpu_addr  : std_logic_vector(15 downto 0);
  signal cpu_dout  : std_logic_vector(7 downto 0);
  signal cpu_din   : std_logic_vector(7 downto 0);   -- combinational read mux
  signal cpu_we    : std_logic;
  signal cpu_sync  : std_logic;
  signal cpu_rdy   : std_logic;
  signal cpu_irq_n : std_logic;
  signal cpu_nmi_n : std_logic;
  signal loram, hiram, charen : std_logic;
  signal ctrl      : std_logic_vector(2 downto 0);

  -- ---- banking decode ----
  signal sel : c64_sel_t;
  signal io  : c64_io_t;

  -- ---- DRAM ----
  signal ram_addr  : std_logic_vector(15 downto 0);
  signal dram_dout : std_logic_vector(7 downto 0);
  signal dram_we   : std_logic;
  signal cpu_en    : std_logic;
  signal vic_ba_d  : std_logic := '1';
  signal vic_ba_d2 : std_logic := '1';
  signal vic_ba_d3 : std_logic := '1';
  signal vic_ba_d4 : std_logic := '1';
  -- Deferred CPU writes the 6502 completes after BA drops. RDY only stalls reads,
  -- so the CPU keeps running write cycles until it parks on the next read -- and a
  -- 6502 can emit up to THREE consecutive writes (JSR pushes PCH+PCL, an interrupt
  -- pushes PCH+PCL+P). A 1-deep latch keeps only the last of those and silently
  -- drops the rest -> corrupted stack -> RTS/RTI into the weeds (the marginal hang
  -- that wandered with code timing). So buffer the whole burst in a small FIFO and
  -- drain it (one entry per clk) once the steal returns the bus.
  constant WQ_DEPTH : integer := 4;
  type wq_addr_t is array (0 to WQ_DEPTH-1) of std_logic_vector(15 downto 0);
  type wq_data_t is array (0 to WQ_DEPTH-1) of std_logic_vector(7 downto 0);
  signal wq_addr  : wq_addr_t;
  signal wq_data  : wq_data_t;
  signal wq_cnt   : integer range 0 to WQ_DEPTH := 0;
  signal dram_din : std_logic_vector(7 downto 0);

  type cwq_addr_t is array (0 to WQ_DEPTH-1) of std_logic_vector(9 downto 0);
  type cwq_data_t is array (0 to WQ_DEPTH-1) of std_logic_vector(3 downto 0);
  signal cwq_addr : cwq_addr_t;
  signal cwq_data : cwq_data_t;
  signal cwq_cnt  : integer range 0 to WQ_DEPTH := 0;
  signal col_din  : std_logic_vector(3 downto 0);

  -- ---- ROMs ----
  signal basic_dout   : std_logic_vector(7 downto 0);
  signal kernal_dout  : std_logic_vector(7 downto 0);
  signal cg_cpu_dout  : std_logic_vector(7 downto 0);
  signal cg_vic_dout  : std_logic_vector(7 downto 0);

  -- ---- VIC ----
  signal vic_dout  : std_logic_vector(7 downto 0);
  signal vic_irq_n : std_logic;
  signal vic_addr  : std_logic_vector(15 downto 0);
  signal vic_data  : std_logic_vector(7 downto 0);
  signal vic_ba    : std_logic;
  signal vic_bank  : std_logic_vector(1 downto 0);
  signal vic_col_addr : std_logic_vector(9 downto 0);
  signal vic_col_data : std_logic_vector(3 downto 0);
  signal vic_char_addr: std_logic_vector(11 downto 0);

  -- ---- colour RAM ----
  signal col_a_dout : std_logic_vector(3 downto 0);
  signal col_addr   : std_logic_vector(9 downto 0);
  signal col_dout   : std_logic_vector(3 downto 0);

  -- ---- CIAs ----
  signal cia1_dout, cia2_dout : std_logic_vector(7 downto 0);
  signal cia1_irq_n, cia2_irq_n : std_logic;
  signal cia1_pa_out, cia1_pb_out : std_logic_vector(7 downto 0);
  signal cia2_pa_out : std_logic_vector(7 downto 0);
  signal kb_row : std_logic_vector(7 downto 0);
  signal restore_n : std_logic;

  -- ---- SID ----
  signal sid_dout : std_logic_vector(7 downto 0);

  -- internal video (so the TOD generator can observe vsync)
  signal s_hs, s_vs, s_de : std_logic;
  signal s_r, s_b : std_logic_vector(4 downto 0);
  signal s_g      : std_logic_vector(5 downto 0);

  -- chip selects
  signal cs_vic, cs_sid, cs_cia1, cs_cia2, cs_col : std_logic;
  signal col_we : std_logic;
begin
  vga_hs <= s_hs; vga_vs <= s_vs; vga_de <= s_de;
  vga_r <= s_r; vga_g <= s_g; vga_b <= s_b;

  -- Debug taps for the testbench.
  dbg_addr <= cpu_addr;
  dbg_we   <= cpu_we;
  dbg_do   <= cpu_dout;
  dbg_di   <= cpu_din;
  dbg_sync <= cpu_sync;
  dbg_phi  <= phi2_en;
  dbg_cia1_irq <= cia1_irq_n;
  ctrl <= charen & hiram & loram;
  sel  <= pla_decode(cpu_addr, ctrl, '1', '1');     -- unexpanded: GAME=EXROM=1
  io   <= io_decode(cpu_addr) when sel = SEL_IO else IO_NONE;

  -- ---- PHI2 / TOD ----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        phi2_cnt <= 0; phi2_en <= '0';
      elsif phi2_cnt = PHI2_DIV - 1 then
        phi2_cnt <= 0; phi2_en <= '1';
      else
        phi2_cnt <= phi2_cnt + 1; phi2_en <= '0';
      end if;
    end if;
  end process;
  -- 60 Hz TOD pulse from the VIC vsync edge.
  process(clk)
    variable vs_d : std_logic := '1';
  begin
    if rising_edge(clk) then
      tod_tick <= '0';
      if s_vs = '0' and vs_d = '1' then tod_tick <= '1'; end if;
      vs_d := s_vs;
    end if;
  end process;

  -- ---- CPU ----
  -- Single-port main RAM, time-shared with the VIC: the CPU clock-enable is gated
  -- off during a VIC steal (BA low) so the two never touch RAM at the same cycle
  -- (no dual-port collision -> no .002 display corruption, no lost writes).
  --
  -- After a steal ends, ram_addr switches vic_addr -> cpu_addr and the single-port
  -- BSRAM dout -> read-mux -> T65 DI path needs several clocks before it presents
  -- mem(cpu_addr) instead of the VIC's just-read mem(vic_addr). A 1-clock guard
  -- left it placement-marginal (the "38911 vs 80909" banner lottery, CIA ICR read
  -- $00 -> dead cursor/keyboard); the fix is simply enough SETTLE clocks: hold the
  -- CPU enable off for FOUR clocks after the steal (vic_ba_d/_d2/_d3/_d4). NOTE:
  -- an earlier attempt registered the read (cpu_din_reg) instead -- it fixed the
  -- banner/CIA but DEADLOCKED the CPU under IRQ load (the extra read-latency stage
  -- corrupted the T65's IRQ vector/stack fetch -> wild jump into BASIC ROM). The
  -- combinational read + 4-clock guard fixes RAM AND survives interrupts.
  process(clk) begin
    if rising_edge(clk) then
      vic_ba_d  <= vic_ba;
      vic_ba_d2 <= vic_ba_d;
      vic_ba_d3 <= vic_ba_d2;
      vic_ba_d4 <= vic_ba_d3;
    end if;
  end process;
  -- The CPU advances every PHI2 tick; the VIC steal is signalled via the 6502's
  -- native RDY (stalls reads), NOT by gating the clock enable. Freezing the T65
  -- mid-cycle during the steal made the CPU timeline DRIFT from the CIA (which
  -- keeps ticking) -> a marginal IRQ-vs-steal beat that wandered with code timing
  -- and rarely corrupted control flow. With RDY the CPU timeline keeps advancing
  -- during the steal (halted but counted), in lockstep with the CIA -- as on real
  -- hardware. RDY stays low through 4 settle clocks after the steal and while a
  -- deferred write is draining.
  cpu_en  <= phi2_en;
  cpu_rdy <= '1' when (vic_ba = '1' and vic_ba_d = '1' and vic_ba_d2 = '1'
                       and vic_ba_d3 = '1' and wq_cnt = 0 and cwq_cnt = 0) else '0';

  -- Main-RAM write FIFO: enqueue every write the CPU completes while the steal
  -- holds the bus, then drain one entry per clk once BA returns (CPU stays parked
  -- via RDY until the queue is empty). Depth 4 covers the 6502's longest write
  -- burst (3, an interrupt push) with margin -- no stack push is ever lost.
  process(clk) begin
    if rising_edge(clk) then
      if reset_n = '0' then
        wq_cnt <= 0;
      elsif vic_ba = '1' and wq_cnt > 0 then
        for i in 0 to WQ_DEPTH-2 loop
          wq_addr(i) <= wq_addr(i+1);
          wq_data(i) <= wq_data(i+1);
        end loop;
        wq_cnt <= wq_cnt - 1;
      elsif phi2_en = '1' and cpu_we = '1' and vic_ba = '0' and sel /= SEL_IO
            and wq_cnt < WQ_DEPTH then
        wq_addr(wq_cnt) <= cpu_addr;
        wq_data(wq_cnt) <= cpu_dout;
        wq_cnt <= wq_cnt + 1;
      end if;
    end if;
  end process;

  -- Colour-RAM write FIFO (same scheme; colour RAM lives in the I/O page).
  process(clk) begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cwq_cnt <= 0;
      elsif vic_ba = '1' and cwq_cnt > 0 then
        for i in 0 to WQ_DEPTH-2 loop
          cwq_addr(i) <= cwq_addr(i+1);
          cwq_data(i) <= cwq_data(i+1);
        end loop;
        cwq_cnt <= cwq_cnt - 1;
      elsif phi2_en = '1' and cpu_we = '1' and cs_col = '1' and vic_ba = '0'
            and cwq_cnt < WQ_DEPTH then
        cwq_addr(cwq_cnt) <= cpu_addr(9 downto 0);
        cwq_data(cwq_cnt) <= cpu_dout(3 downto 0);
        cwq_cnt <= cwq_cnt + 1;
      end if;
    end if;
  end process;
  cpu_irq_n <= cia1_irq_n and vic_irq_n;
  cpu_nmi_n <= cia2_irq_n and restore_n;

  cpu_i : entity work.cpu6510
    port map (
      clk => clk, reset_n => reset_n, enable => cpu_en, rdy => cpu_rdy,
      irq_n => cpu_irq_n, nmi_n => cpu_nmi_n,
      addr => cpu_addr, data_in => cpu_din, data_out => cpu_dout, we => cpu_we,
      sync => cpu_sync,
      pa_in => x"FF", pa_out => open,
      loram => loram, hiram => hiram, charen => charen
    );

  -- ---- 64K main RAM: single-port, time-shared CPU <-> VIC (steal) ----
  ram_addr <= vic_addr   when vic_ba = '0' else
              wq_addr(0) when wq_cnt > 0  else
              cpu_addr;
  dram_we  <= '1' when (vic_ba = '1' and wq_cnt > 0) else
              '1' when (vic_ba = '1' and wq_cnt = 0 and cpu_we = '1' and sel /= SEL_IO) else
              '0';
  dram_din <= wq_data(0) when wq_cnt > 0 else cpu_dout;

  ram_i : entity work.c64_ram
    generic map (INIT_FILE => RAM_INIT)
    port map (clk => clk, addr => ram_addr, we => dram_we,
              din => dram_din, dout => dram_dout);
  vic_data <= dram_dout;     -- VIC reads screen codes from RAM during the steal

  -- ---- ROMs ----
  basic_i : entity work.basic_rom
    port map (clk => clk, addr => cpu_addr(12 downto 0), dout => basic_dout);
  kernal_i : entity work.kernal_rom
    port map (clk => clk, addr => cpu_addr(12 downto 0), dout => kernal_dout);
  chargen_i : entity work.chargen_rom
    port map (clk => clk,
              a_addr => cpu_addr(11 downto 0), a_dout => cg_cpu_dout,
              b_addr => vic_char_addr,         b_dout => cg_vic_dout);

  -- ---- colour RAM ----
  -- Colour RAM: single-port, time-shared like main RAM (VIC during the steal, CPU
  -- otherwise) so there is no dual-port collision.
  cs_col   <= '1' when io = IO_COLOR else '0';
  col_we   <= '1' when (vic_ba = '1' and cwq_cnt > 0) else
              '1' when (vic_ba = '1' and cwq_cnt = 0 and cs_col = '1' and cpu_we = '1') else
              '0';
  col_addr <= vic_col_addr when vic_ba = '0' else
              cwq_addr(0)  when cwq_cnt > 0  else
              cpu_addr(9 downto 0);
  col_din  <= cwq_data(0) when cwq_cnt > 0 else cpu_dout(3 downto 0);
  colram_i : entity work.colour_ram
    port map (clk => clk, addr => col_addr, we => col_we,
              din => col_din, dout => col_dout);
  vic_col_data <= col_dout;     -- VIC reads colour during the steal
  col_a_dout   <= col_dout;     -- CPU reads colour otherwise

  -- ---- VIC-II ----
  cs_vic <= '1' when io = IO_VIC else '0';
  vic_i : entity work.vic_ii
    port map (
      clk => clk, reset_n => reset_n,
      cs => cs_vic, we => cpu_we, addr => cpu_addr(5 downto 0),
      din => cpu_dout, dout => vic_dout, irq_n => vic_irq_n,
      vic_addr => vic_addr, vic_data => vic_data, ba => vic_ba,
      vic_bank => vic_bank,
      color_addr => vic_col_addr, color_data => vic_col_data,
      char_addr => vic_char_addr, char_data => cg_vic_dout,
      vga_hs => s_hs, vga_vs => s_vs, vga_de => s_de,
      vga_r => s_r, vga_g => s_g, vga_b => s_b
    );
  vic_bank <= not cia2_pa_out(1 downto 0);

  -- ---- CIA-1 (keyboard + Timer A jiffy IRQ) ----
  cs_cia1 <= '1' when io = IO_CIA1 else '0';
  cia1_i : entity work.cia6526_full
    port map (
      clk => clk, reset_n => reset_n, tick => phi2_en, tod_tick => tod_tick,
      cs => cs_cia1, we => cpu_we, addr => cpu_addr(3 downto 0),
      din => cpu_dout, dout => cia1_dout,
      pa_in => x"FF", pa_out => cia1_pa_out, pa_ddr => open,
      pb_in => kb_row, pb_out => cia1_pb_out, pb_ddr => open,
      flag_n => '1', irq_n => cia1_irq_n
    );

  -- ---- CIA-2 (VIC bank + NMI + IEC; serial bus is a stub for now) ----
  cs_cia2 <= '1' when io = IO_CIA2 else '0';
  cia2_i : entity work.cia6526_full
    port map (
      clk => clk, reset_n => reset_n, tick => phi2_en, tod_tick => tod_tick,
      cs => cs_cia2, we => cpu_we, addr => cpu_addr(3 downto 0),
      din => cpu_dout, dout => cia2_dout,
      pa_in => x"FF", pa_out => cia2_pa_out, pa_ddr => open,
      pb_in => x"FF", pb_out => open, pb_ddr => open,
      flag_n => '1', irq_n => cia2_irq_n
    );

  -- ---- keyboard matrix ----
  -- (Isolation test confirmed the PS/2 module is innocent -- the hang persists with
  -- it removed -- so it stays wired in.)
  kbd_i : entity work.c64_keyboard_matrix
    port map (
      clk => clk, reset_n => reset_n,
      ps2_clk => ps2_clk, ps2_data => ps2_data,
      col_drive => cia1_pa_out, row_read => kb_row, restore_n => restore_n
    );

  -- ---- SID ----
  cs_sid <= '1' when io = IO_SID else '0';
  sid_i : entity work.sid6581
    generic map (CLK_HZ => 27_000_000, SID_HZ => 985_248)
    port map (
      clk => clk, reset_n => reset_n,
      cs => cs_sid, we => cpu_we, addr => cpu_addr(4 downto 0),
      din => cpu_dout, dout => sid_dout, sample_out => audio
    );

  -- ---- CPU read data mux ----
  process(sel, io, dram_dout, basic_dout, kernal_dout, cg_cpu_dout,
          vic_dout, sid_dout, col_a_dout, cia1_dout, cia2_dout)
  begin
    case sel is
      when SEL_RAM     => cpu_din <= dram_dout;
      when SEL_BASIC   => cpu_din <= basic_dout;
      when SEL_KERNAL  => cpu_din <= kernal_dout;
      when SEL_CHARGEN => cpu_din <= cg_cpu_dout;
      when SEL_IO =>
        case io is
          when IO_VIC   => cpu_din <= vic_dout;
          when IO_SID   => cpu_din <= sid_dout;
          when IO_COLOR => cpu_din <= "0000" & col_a_dout;
          when IO_CIA1  => cpu_din <= cia1_dout;
          when IO_CIA2  => cpu_din <= cia2_dout;
          when others   => cpu_din <= x"FF";
        end case;
      when others => cpu_din <= dram_dout;
    end case;
  end process;
end architecture;
