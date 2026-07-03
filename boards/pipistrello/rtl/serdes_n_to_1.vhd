library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.Vcomponents.all;

entity serdes_n_to_1 is
  generic (
    SF : integer := 8
  );
  port (
    ioclk        : in  std_logic;
    serdesstrobe : in  std_logic;
    reset        : in  std_logic;
    gclk         : in  std_logic;
    datain       : in  std_logic_vector((SF - 1) downto 0);
    iob_data_out : out std_logic
  );
end entity;

architecture rtl of serdes_n_to_1 is
  signal cascade_di : std_logic;
  signal cascade_do : std_logic;
  signal cascade_ti : std_logic;
  signal cascade_to : std_logic;
  signal mdatain    : std_logic_vector(8 downto 0);
begin
  loop0 : for i in 0 to (SF - 1) generate
  begin
    mdatain(i) <= datain(i);
  end generate;

  loop1 : for i in SF to 8 generate
  begin
    mdatain(i) <= '0';
  end generate;

  oserdes_m : OSERDES2
    generic map (
      DATA_WIDTH   => SF,
      DATA_RATE_OQ => "SDR",
      DATA_RATE_OT => "SDR",
      SERDES_MODE  => "MASTER",
      OUTPUT_MODE  => "DIFFERENTIAL"
    )
    port map (
      CLK0      => ioclk,
      CLK1      => '0',
      CLKDIV    => gclk,
      D1        => mdatain(4),
      D2        => mdatain(5),
      D3        => mdatain(6),
      D4        => mdatain(7),
      IOCE      => serdesstrobe,
      OCE       => '1',
      OQ        => iob_data_out,
      RST       => reset,
      SHIFTIN1  => '1',
      SHIFTIN2  => '1',
      SHIFTIN3  => cascade_do,
      SHIFTIN4  => cascade_to,
      SHIFTOUT1 => cascade_di,
      SHIFTOUT2 => cascade_ti,
      SHIFTOUT3 => open,
      SHIFTOUT4 => open,
      T1        => '0',
      T2        => '0',
      T3        => '0',
      T4        => '0',
      TCE       => '1',
      TQ        => open,
      TRAIN     => '0'
    );

  oserdes_s : OSERDES2
    generic map (
      DATA_WIDTH   => SF,
      DATA_RATE_OQ => "SDR",
      DATA_RATE_OT => "SDR",
      SERDES_MODE  => "SLAVE",
      OUTPUT_MODE  => "DIFFERENTIAL"
    )
    port map (
      CLK0      => ioclk,
      CLK1      => '0',
      CLKDIV    => gclk,
      D1        => mdatain(0),
      D2        => mdatain(1),
      D3        => mdatain(2),
      D4        => mdatain(3),
      IOCE      => serdesstrobe,
      OCE       => '1',
      OQ        => open,
      RST       => reset,
      SHIFTIN1  => cascade_di,
      SHIFTIN2  => cascade_ti,
      SHIFTIN3  => '1',
      SHIFTIN4  => '1',
      SHIFTOUT1 => open,
      SHIFTOUT2 => open,
      SHIFTOUT3 => cascade_do,
      SHIFTOUT4 => cascade_to,
      T1        => '0',
      T2        => '0',
      T3        => '0',
      T4        => '0',
      TCE       => '1',
      TQ        => open,
      TRAIN     => '0'
    );
end architecture;
