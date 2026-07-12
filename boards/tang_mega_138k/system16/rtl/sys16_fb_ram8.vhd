-- One 8-bit byte lane of the framebuffer: true-dual-port BSRAM with
-- independent clocks. Port A is the CPU side (read/write, bus clock),
-- port B the scanout side (read only, pixel clock). Four instances make
-- a 32-bit word with per-byte write enables, which GowinSynthesis infers
-- far more reliably than one wide RAM with byte enables. The exact DEPTH
-- avoids power-of-two rounding (same trick as the SBC framebuffers).
--
-- Both ports register their inputs inside the bank: the 115200-deep
-- array spans a 57-block cascade, and one global address/data register
-- driving all of them failed timing on fanout/routing alone. With the
-- registers in here the placer can duplicate them next to each cascade.
-- Read latency is therefore two clocks per port (input reg + BSRAM reg).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_fb_ram8 is
  generic (
    DEPTH : natural := 115200;
    AW    : natural := 17
  );
  port (
    clka  : in  std_logic;
    wea   : in  std_logic;
    addra : in  std_logic_vector(AW-1 downto 0);
    dina  : in  std_logic_vector(7 downto 0);
    qa    : out std_logic_vector(7 downto 0);
    clkb  : in  std_logic;
    addrb : in  std_logic_vector(AW-1 downto 0);
    qb    : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of sys16_fb_ram8 is
  type ram_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  -- Power-up zero like real BSRAM, so an unwritten cell reads a defined 0
  -- (matches hardware and keeps simulation free of metavalue noise).
  shared variable ram : ram_t := (others => (others => '0'));
  signal addra_r : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal dina_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal wea_r   : std_logic := '0';
  signal addrb_q : std_logic_vector(AW-1 downto 0) := (others => '0');
begin
  port_a : process(clka)
    variable ia : integer;
  begin
    if rising_edge(clka) then
      addra_r <= addra;
      dina_r  <= dina;
      wea_r   <= wea;
      ia := to_integer(unsigned(addra_r));
      if ia < DEPTH then
        if wea_r = '1' then
          ram(ia) := dina_r;
        end if;
        qa <= ram(ia);
      end if;
    end if;
  end process;

  port_b : process(clkb)
    variable ib : integer;
  begin
    if rising_edge(clkb) then
      addrb_q <= addrb;
      ib := to_integer(unsigned(addrb_q));
      if ib < DEPTH then
        qb <= ram(ib);
      end if;
    end if;
  end process;
end architecture;
