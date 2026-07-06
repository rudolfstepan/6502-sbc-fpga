-- ============================================================================
-- ulpi_vbus_init -- one-shot USB3317 OTG-Control register write to enable VBUS.
--
-- The ulpi_wrapper / usbh_host stack only touches the UTMI *functional*
-- registers (Function Control etc.); it never writes the PHY's OTG Control
-- register, so it cannot turn on VBUS. For host operation the port must supply
-- 5 V to the keyboard, which on the USB3317 means asserting DRV_VBUS (and, for
-- an externally-switched supply via CPEN, DRV_VBUS_EXTERNAL) in OTG Control
-- (register 0x0A).
--
-- This module owns the ULPI bus *before* the wrapper does: it performs a single
-- ULPI register write (per the ULPI reg-write timing: TX CMD -> wait NXT ->
-- data -> STP), then raises `done`. The top level then muxes the ULPI drive over
-- to the wrapper and releases it from reset.
--
-- Runs in the 60 MHz ULPI clock domain (ulpi_clk from the PHY).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ulpi_vbus_init is
  generic (
    -- OTG Control (0x0A). 0x66 = Dp/DmPulldown (reset default 0x06) + DrvVbus
    -- (0x20) + DrvVbusExternal (0x40 -> CPEN). If VBUS misbehaves try 0x60/0x20.
    OTG_CTRL_ADDR : std_logic_vector(5 downto 0) := "001010";  -- 0x0A
    OTG_CTRL_VAL  : std_logic_vector(7 downto 0) := x"66"
  );
  port (
    clk        : in  std_logic;                      -- ulpi_clk (60 MHz)
    reset_n    : in  std_logic;

    ulpi_dir   : in  std_logic;
    ulpi_nxt   : in  std_logic;
    ulpi_data_i: in  std_logic_vector(7 downto 0);   -- pins (unused, for symmetry)

    ulpi_data_o : out std_logic_vector(7 downto 0);  -- drive value (dir=0)
    ulpi_data_oe: out std_logic;
    ulpi_stp    : out std_logic;

    done       : out std_logic
  );
end entity;

architecture rtl of ulpi_vbus_init is
  type st_t is (S_SETTLE, S_CMD, S_DATA, S_STP, S_DONE);
  signal st       : st_t := S_SETTLE;
  signal settle   : unsigned(11 downto 0) := (others => '0');  -- ~68 us @60MHz
  signal timeout  : unsigned(11 downto 0) := (others => '0');
  signal data_o_r : std_logic_vector(7 downto 0) := (others => '0');
  signal oe_r     : std_logic := '0';
  signal stp_r    : std_logic := '0';
  signal done_r   : std_logic := '0';
begin
  ulpi_data_o  <= data_o_r;
  ulpi_data_oe <= oe_r;
  ulpi_stp     <= stp_r;
  done         <= done_r;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        st       <= S_SETTLE;
        settle   <= (others => '0');
        timeout  <= (others => '0');
        data_o_r <= (others => '0');
        oe_r     <= '0';
        stp_r    <= '0';
        done_r   <= '0';
      else
        -- defaults
        oe_r  <= '0';
        stp_r <= '0';

        case st is
          when S_SETTLE =>
            -- let the ULPI clock / bus settle, then start when idle (dir=0)
            if settle = x"FFF" then
              if ulpi_dir = '0' then
                st      <= S_CMD;
                timeout <= (others => '0');
              end if;
            else
              settle <= settle + 1;
            end if;

          when S_CMD =>
            -- Drive TX CMD: 10b (reg write) & 6-bit address. Hold until NXT.
            data_o_r <= "10" & OTG_CTRL_ADDR;
            oe_r     <= '1';
            if ulpi_dir = '1' then
              st <= S_DONE;                 -- PHY grabbed the bus: abort cleanly
            elsif ulpi_nxt = '1' then
              st <= S_DATA;
            elsif timeout = x"FFF" then
              st <= S_DONE;                 -- no NXT: give up, don't hang
            else
              timeout <= timeout + 1;
            end if;

          when S_DATA =>
            -- Drive the write data one cycle (PHY latches it).
            data_o_r <= OTG_CTRL_VAL;
            oe_r     <= '1';
            st       <= S_STP;

          when S_STP =>
            -- Assert STP to complete the register write.
            data_o_r <= (others => '0');
            oe_r     <= '1';
            stp_r    <= '1';
            st       <= S_DONE;

          when S_DONE =>
            done_r <= '1';                  -- bus released (oe/stp back to 0)
        end case;
      end if;
    end if;
  end process;
end architecture;
