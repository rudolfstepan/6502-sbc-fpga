-- MOS 6510 = T65 6502 core + on-chip 6-bit processor port at $0000/$0001.
--
-- The 6510's I/O port is what the C64 uses to bank ROMs in and out:
--   $0000 DDR  : direction (1 = output) for each port bit, reset = $00 (all in)
--   $0001 DATA : port data; pins read DATA when output, else the pull-up level
--     bit0 LORAM   (1 = BASIC ROM in)
--     bit1 HIRAM   (1 = KERNAL ROM in)
--     bit2 CHAREN  (1 = I/O visible at $D000, 0 = char ROM)
--     bit3 cassette write line
--     bit4 cassette switch sense (input, pulled high)
--     bit5 cassette motor control
--
-- At reset DDR = $00, so bits 0-2 read their pull-ups ('1') and all ROMs are
-- banked in -- which is exactly why the reset vector is fetched from the KERNAL.
-- The KERNAL then writes DDR=$2F / DATA=$37 early in its init.
--
-- Reads of $0000/$0001 return the port (not the underlying RAM); the core must
-- route those two addresses here, not to DRAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.T65_Pack.all;

entity cpu6510 is
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;
    enable   : in  std_logic;                       -- clock enable (PHI2 rate)
    rdy      : in  std_logic := '1';                -- '0' stalls CPU (VIC BA)
    irq_n    : in  std_logic;
    nmi_n    : in  std_logic;

    addr     : out std_logic_vector(15 downto 0);
    data_in  : in  std_logic_vector(7 downto 0);    -- from memory / I/O
    data_out : out std_logic_vector(7 downto 0);
    we       : out std_logic;                       -- 1 = CPU writing
    sync     : out std_logic;
    regs     : out std_logic_vector(63 downto 0);

    -- Processor port pins (external levels for the input bits).
    pa_in    : in  std_logic_vector(7 downto 0) := x"FF";
    pa_out   : out std_logic_vector(7 downto 0);    -- current pin levels

    -- Banking control, decoded from the port pins.
    loram    : out std_logic;
    hiram    : out std_logic;
    charen   : out std_logic
  );
end entity;

architecture rtl of cpu6510 is
  signal t65_addr  : std_logic_vector(23 downto 0);
  signal t65_din   : std_logic_vector(7 downto 0);
  signal t65_dout  : std_logic_vector(7 downto 0);
  signal t65_r_w_n : std_logic;
  signal t65_vda   : std_logic;
  signal cpu_we    : std_logic;

  -- Processor port registers.
  signal port_ddr  : std_logic_vector(7 downto 0) := (others => '0');
  signal port_data : std_logic_vector(7 downto 0) := (others => '0');
  signal port_pin  : std_logic_vector(7 downto 0);

  -- Unused T65 outputs.
  signal u_dbg : T_t65_dbg;
  signal u_regs : std_logic_vector(63 downto 0);
  signal u_ef, u_mf, u_xf, u_ml_n, u_vp_n, u_vpa, u_nmiack : std_logic;

  -- True when the CPU is addressing the on-chip port.
  signal sel_port : std_logic;
begin
  -- Pin level: output bits drive DATA, input bits read the external pull-up.
  pin_gen : for i in 0 to 7 generate
    port_pin(i) <= port_data(i) when port_ddr(i) = '1' else pa_in(i);
  end generate;

  pa_out <= port_pin;
  loram  <= port_pin(0);
  hiram  <= port_pin(1);
  charen <= port_pin(2);

  addr     <= t65_addr(15 downto 0);
  data_out <= t65_dout;
  cpu_we   <= (not t65_r_w_n) and t65_vda;
  we       <= cpu_we;
  regs     <= u_regs;

  sel_port <= '1' when t65_addr(15 downto 1) = (14 downto 0 => '0') else '0';

  -- The T65 core expects its write data fed back on DI during write cycles
  -- (matches the upstream 6510 wrapper and keeps RMW/undocumented paths sane).
  t65_din <= t65_dout when cpu_we = '1' else
             port_ddr  when (sel_port = '1' and t65_addr(0) = '0') else
             port_pin  when (sel_port = '1' and t65_addr(0) = '1') else
             data_in;

  -- Capture writes to the port registers.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        port_ddr  <= (others => '0');
        port_data <= (others => '0');
      elsif enable = '1' and cpu_we = '1' and sel_port = '1' then
        if t65_addr(0) = '0' then
          port_ddr  <= t65_dout;
        else
          port_data <= t65_dout;
        end if;
      end if;
    end if;
  end process;

  core_i : entity work.T65
    port map (
      Mode    => "00",
      BCD_en  => '1',
      Res_n   => reset_n,
      Enable  => enable,
      Clk     => clk,
      Rdy     => rdy,
      Abort_n => '1',
      IRQ_n   => irq_n,
      NMI_n   => nmi_n,
      SO_n    => '1',
      R_W_n   => t65_r_w_n,
      Sync    => sync,
      EF      => u_ef,
      MF      => u_mf,
      XF      => u_xf,
      ML_n    => u_ml_n,
      VP_n    => u_vp_n,
      VDA     => t65_vda,
      VPA     => u_vpa,
      A       => t65_addr,
      DI      => t65_din,
      DO      => t65_dout,
      Regs    => u_regs,
      DEBUG   => u_dbg,
      NMI_ack => u_nmiack
    );
end architecture;
