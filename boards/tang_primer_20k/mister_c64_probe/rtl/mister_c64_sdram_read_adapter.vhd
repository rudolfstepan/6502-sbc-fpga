-- Read adapter: c1541_d64_sector_source byte-read port  <->  sdram_ctrl read burst.
--
-- The D64 sector source issues a simple decoupled byte read
--   (req_addr, req_rd) -> (req_ready, then req_valid + req_data)
-- while the native rtl/core/mem/sdram_ctrl.vhd speaks a 16-bit burst protocol
--   pulse rd_burst_req with rd_burst_addr/len -> rd_burst_data + rd_burst_data_valid.
--
-- Byte<->word mapping: follows the repo's low-byte-only external-memory
-- convention (see rtl/core/mem/sdram_if.vhd): one .d64 byte per 16-bit SDRAM
-- word, stored in the low byte (DQ[7:0]); the high byte is masked (DQM="10") by
-- the writer/loader and ignored here.  So word_addr = D64_WORD_BASE + byte_addr
-- with no packing.  Any physical SDRAM placement is folded into D64_WORD_BASE.
--
-- One 1-word read per byte request (BL=1 in sdram_ctrl).  The refill window in
-- c1541_static_dir_gcr is far larger than the per-sector read time.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mister_c64_sdram_read_adapter is
  generic (
    D64_WORD_BASE : natural := 0   -- 16-bit word address of the .d64 in SDRAM
  );
  port (
    clk   : in  std_logic;
    reset : in  std_logic;   -- synchronous, active-high

    -- c1541_d64_sector_source SDRAM port (byte oriented).
    req_addr  : in  std_logic_vector(22 downto 0);
    req_rd    : in  std_logic;
    req_ready : out std_logic;
    req_valid : out std_logic;
    req_data  : out std_logic_vector(7 downto 0);

    -- sdram_ctrl read-burst port.
    rd_burst_req        : out std_logic;
    rd_burst_addr       : out std_logic_vector(23 downto 0);
    rd_burst_len        : out std_logic_vector(9 downto 0);
    rd_burst_data       : in  std_logic_vector(15 downto 0);
    rd_burst_data_valid : in  std_logic;
    ctrl_idle           : in  std_logic
  );
end entity;

architecture rtl of mister_c64_sdram_read_adapter is
  type state_t is (IDLE, RX);
  signal state     : state_t := IDLE;
  signal word_addr : unsigned(23 downto 0);
  signal accept    : std_logic;
begin
  -- Word address of the requested byte (low-byte-only: 1 byte per word).
  word_addr <= to_unsigned(D64_WORD_BASE, 24)
               + resize(unsigned(req_addr), 24);

  -- Accept a new request only when idle and the controller can take it.
  accept    <= '1' when state = IDLE and req_rd = '1' and ctrl_idle = '1' else '0';
  req_ready <= accept;

  -- One-cycle burst request coincident with the accept; addr/len are stable
  -- because the source holds req_addr until the read is accepted.
  rd_burst_req  <= accept;
  rd_burst_addr <= std_logic_vector(word_addr);
  rd_burst_len  <= std_logic_vector(to_unsigned(1, 10));

  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state     <= IDLE;
        req_valid <= '0';
        req_data  <= (others => '0');
      else
        req_valid <= '0';
        case state is
          when IDLE =>
            if accept = '1' then
              state <= RX;
            end if;

          when RX =>
            if rd_burst_data_valid = '1' then
              req_data  <= rd_burst_data(7 downto 0);  -- low byte only
              req_valid <= '1';
              state     <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
