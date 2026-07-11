library ieee;
use ieee.std_logic_1164.all;

-- Converts one little-endian 32-bit request into one or two 16-bit requests.
-- The master must hold req and its payload until ready is asserted.
entity sys16_bus32_to_sdram16 is
  port (
    clk, reset_n : in std_logic;
    req, we      : in std_logic;
    addr         : in std_logic_vector(31 downto 0);
    be           : in std_logic_vector(3 downto 0);
    wdata        : in std_logic_vector(31 downto 0);
    rdata        : out std_logic_vector(31 downto 0);
    ready        : out std_logic;
    mem_req      : out std_logic;
    mem_we       : out std_logic;
    mem_addr     : out std_logic_vector(23 downto 1);
    mem_be       : out std_logic_vector(1 downto 0);
    mem_wdata    : out std_logic_vector(15 downto 0);
    mem_rdata    : in std_logic_vector(15 downto 0);
    mem_ready    : in std_logic
  );
end entity;

architecture rtl of sys16_bus32_to_sdram16 is
  type state_t is (IDLE, LOW_WAIT, LOW_DROP, HIGH_WAIT, HIGH_DROP, RESPONSE);
  signal state : state_t := IDLE;
  signal a : std_logic_vector(31 downto 0) := (others => '0');
  signal d, q : std_logic_vector(31 downto 0) := (others => '0');
  signal lanes : std_logic_vector(3 downto 0) := (others => '0');
  signal write_l : std_logic := '0';
  signal need_low, need_high : std_logic;
begin
  need_low  <= '1' when write_l = '0' or lanes(1 downto 0) /= "00" else '0';
  need_high <= '1' when write_l = '0' or lanes(3 downto 2) /= "00" else '0';
  rdata <= q;
  ready <= '1' when state = RESPONSE else '0';
  mem_req <= '1' when state = LOW_WAIT or state = HIGH_WAIT else '0';
  mem_we <= write_l;
  mem_addr <= a(23 downto 2) & '0' when state = LOW_WAIT else
              a(23 downto 2) & '1';
  mem_be <= lanes(1 downto 0) when state = LOW_WAIT else lanes(3 downto 2);
  mem_wdata <= d(15 downto 0) when state = LOW_WAIT else d(31 downto 16);

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state <= IDLE; q <= (others => '0');
      else
        case state is
          when IDLE =>
            if req = '1' then
              a <= addr; d <= wdata; lanes <= be; write_l <= we;
              if we = '0' or be(1 downto 0) /= "00" then state <= LOW_WAIT;
              elsif be(3 downto 2) /= "00" then state <= HIGH_WAIT;
              else state <= RESPONSE;
              end if;
            end if;
          when LOW_WAIT =>
            if mem_ready = '1' then
              if write_l = '0' then q(15 downto 0) <= mem_rdata; end if;
              state <= LOW_DROP;
            end if;
          when LOW_DROP =>
            if mem_ready = '0' then
              if need_high = '1' then state <= HIGH_WAIT; else state <= RESPONSE; end if;
            end if;
          when HIGH_WAIT =>
            if mem_ready = '1' then
              if write_l = '0' then q(31 downto 16) <= mem_rdata; end if;
              state <= HIGH_DROP;
            end if;
          when HIGH_DROP =>
            if mem_ready = '0' then state <= RESPONSE; end if;
          when RESPONSE =>
            if req = '0' then state <= IDLE; end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
