-- Minimal IEC drive-side attachment point for the native C64 core.
--
-- The C64 controls ATN, CLK and DATA through CIA2 port A.  Real IEC devices
-- are open-collector participants: they never drive a high level, they only
-- pull CLK/DATA low or release them.  This module is intentionally conservative
-- for the first bring-up step.  It synchronizes the observed bus and provides
-- drive-side pull-down outputs, but leaves the bus released until a responder
-- FSM is added.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_iec_drive is
  generic (
    ENABLE_ATN_ACK : boolean := false
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    -- Combined IEC line state as seen on the bus, active low.
    atn_n   : in  std_logic;
    clk_n   : in  std_logic;
    data_n  : in  std_logic;

    -- Drive-side open-collector pulls, active low.
    drive_clk_pull_n  : out std_logic;
    drive_data_pull_n : out std_logic;

    -- Debug: [31:24] ATN edges, [23:16] CLK edges, [15:8] DATA edges,
    -- [7:5] synchronized ATN/CLK/DATA, [4:0] state.
    dbg_state : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of c64_iec_drive is
  signal atn_sync  : std_logic_vector(2 downto 0) := (others => '1');
  signal clk_sync  : std_logic_vector(2 downto 0) := (others => '1');
  signal data_sync : std_logic_vector(2 downto 0) := (others => '1');

  signal atn_s  : std_logic := '1';
  signal clk_s  : std_logic := '1';
  signal data_s : std_logic := '1';
  signal atn_d  : std_logic := '1';
  signal clk_d  : std_logic := '1';
  signal data_d : std_logic := '1';

  signal atn_edges  : unsigned(7 downto 0) := (others => '0');
  signal clk_edges  : unsigned(7 downto 0) := (others => '0');
  signal data_edges : unsigned(7 downto 0) := (others => '0');
  signal state      : std_logic_vector(4 downto 0) := (others => '0');
  signal data_pull  : std_logic := '1';
  signal atn_ack_active : std_logic := '0';
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        atn_sync    <= (others => '1');
        clk_sync    <= (others => '1');
        data_sync   <= (others => '1');
        atn_s       <= '1';
        clk_s       <= '1';
        data_s      <= '1';
        atn_d       <= '1';
        clk_d       <= '1';
        data_d      <= '1';
        atn_edges   <= (others => '0');
        clk_edges   <= (others => '0');
        data_edges  <= (others => '0');
        state       <= (others => '0');
        data_pull   <= '1';
        atn_ack_active <= '0';
      else
        atn_sync  <= atn_sync(1 downto 0) & atn_n;
        clk_sync  <= clk_sync(1 downto 0) & clk_n;
        data_sync <= data_sync(1 downto 0) & data_n;

        atn_d  <= atn_s;
        clk_d  <= clk_s;
        data_d <= data_s;
        atn_s  <= atn_sync(2);
        clk_s  <= clk_sync(2);
        data_s <= data_sync(2);

        -- Count observable bus edges so we can tell whether a loader is still
        -- clocking or waiting in the first handshake.
        if atn_d /= atn_s then
          atn_edges <= atn_edges + 1;
        end if;
        if clk_d /= clk_s then
          clk_edges <= clk_edges + 1;
        end if;
        if data_d /= data_s then
          data_edges <= data_edges + 1;
        end if;

        -- Optional IEC presence responder.  A listener acknowledges ATN by
        -- pulling DATA low, then releases DATA when the controller starts
        -- clocking the command byte.  This is still only the first handshake;
        -- the byte-level listener response is added after the sniffer confirms
        -- the command stream.
        if ENABLE_ATN_ACK and atn_d = '1' and atn_s = '0' then
          atn_ack_active <= '1';
        elsif atn_s = '1' then
          atn_ack_active <= '0';
        elsif clk_d = '1' and clk_s = '0' then
          atn_ack_active <= '0';
        end if;

        if atn_ack_active = '1' then
          data_pull <= '0';
          state <= "00001";
        else
          data_pull <= '1';
          state <= "00000";
        end if;
      end if;
    end if;
  end process;

  -- CLK stays passive for now; DATA only pulses low for the ATN acknowledge.
  drive_clk_pull_n  <= '1';
  drive_data_pull_n <= data_pull;

  dbg_state <= std_logic_vector(atn_edges) & std_logic_vector(clk_edges) &
               std_logic_vector(data_edges) & atn_s & clk_s & data_s & state;
end architecture;
