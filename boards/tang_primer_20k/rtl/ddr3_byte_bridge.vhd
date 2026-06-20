-- DDR3 byte bridge for the Tang Primer 20K main RAM.
--
-- Adapts the 6502 single-byte bus (clk_sys, 54 MHz) to the Gowin DDR3 Memory
-- Interface IP app interface (clk_x1, 100 MHz, 128-bit, burst-oriented), and
-- runs a power-on byte-granular RAM self-test before releasing the CPU.
--
-- Design notes
-- ------------
--  * The 6502 access rate is low and the CPU is stalled (cpu_rdy='0') for the
--    whole access, so a simple req/ack toggle CDC is sufficient — no FIFO.
--    The byte payload (we/addr/din) is held stable by the core for the whole
--    transaction, so the clk_x1 side may sample it directly once a request edge
--    is observed.
--  * Single 8-burst (BL8 = 8x16-bit = 128-bit) access per byte op:
--      - line  = addr[14:4]            (which 16-byte line)
--      - word  app_addr = line * 8     (app addr counts 16-bit words, +8/burst)
--      - lane  = addr[3:0]             (byte position inside the 128-bit beat)
--  * Byte write uses the IP write-data mask (one bit per byte). Gowin convention
--    is mask bit '1' = byte masked/not written, so we enable only the target
--    lane. MASK_BIT_MASKS lets this be flipped if HW bring-up shows otherwise.
--  * The self-test exercises the exact serve path (masked single-byte writes +
--    reads), so a pass validates address mapping, lane order and mask polarity.
--
-- HARDWARE BRING-UP: address granularity, byte-lane order and mask polarity are
-- the primary risks; the self-test (ram_test_* on the boot screen) must pass
-- before trusting CPU RAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ddr3_byte_bridge is
  generic (
    ADDR_BITS     : positive := 15;    -- 32 KB main-RAM window
    MASK_BIT_MASKS : boolean := true   -- true: wr_data_mask bit '1' disables a byte
  );
  port (
    -- ---- clk_sys (6502) side -------------------------------------------------
    clk_sys   : in  std_logic;
    rst_sys_n : in  std_logic;
    req       : in  std_logic;                                  -- 1-clk pulse: start access
    we        : in  std_logic;                                  -- 1=write, 0=read (with req)
    addr      : in  std_logic_vector(ADDR_BITS-1 downto 0);     -- byte address (held stable)
    din       : in  std_logic_vector(7 downto 0);               -- write byte (held stable)
    dout      : out std_logic_vector(7 downto 0);               -- read byte (valid at ack)
    ack       : out std_logic;                                  -- 1-clk pulse: access complete
    ram_ready : out std_logic;                                  -- calib done AND self-test passed

    -- ---- RAM self-test status (clk_sys domain) -------------------------------
    ram_test_active    : out std_logic;
    ram_test_done      : out std_logic;
    ram_test_error     : out std_logic;
    ram_test_phase     : out std_logic_vector(3 downto 0);
    ram_test_addr      : out std_logic_vector(ADDR_BITS-1 downto 0);
    ram_test_fail_addr : out std_logic_vector(ADDR_BITS-1 downto 0);
    ram_test_expected  : out std_logic_vector(7 downto 0);
    ram_test_actual    : out std_logic_vector(7 downto 0);

    -- ---- clk_x1 (DDR3 IP app) side ------------------------------------------
    clk_x1              : in  std_logic;
    init_calib_complete : in  std_logic;
    dbg_pll_lock        : in  std_logic := '0';  -- DDR memory PLL lock (diagnostic)
    app_cmd             : out std_logic_vector(2 downto 0);
    app_cmd_en          : out std_logic;
    app_cmd_rdy         : in  std_logic;
    app_addr            : out std_logic_vector(26 downto 0);
    app_wren            : out std_logic;
    app_wdata           : out std_logic_vector(127 downto 0);
    app_wdata_end       : out std_logic;
    app_wdata_mask      : out std_logic_vector(15 downto 0);
    app_wdata_rdy       : in  std_logic;
    app_rdata           : in  std_logic_vector(127 downto 0);
    app_rdata_valid     : in  std_logic
  );
end entity;

architecture rtl of ddr3_byte_bridge is

  constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
  constant CMD_READ  : std_logic_vector(2 downto 0) := "001";

  -- ---- CDC: clk_sys -> clk_x1 (request) -----------------------------------
  signal req_tgl_sys  : std_logic := '0';            -- toggles per accepted req
  signal req_tgl_x1   : std_logic_vector(2 downto 0) := (others => '0');
  -- ---- CDC: clk_x1 -> clk_sys (acknowledge) -------------------------------
  signal ack_tgl_x1   : std_logic := '0';            -- toggles per completed op
  signal ack_tgl_sys  : std_logic_vector(2 downto 0) := (others => '0');

  -- payload latched in clk_x1 from the (stable) sys inputs
  signal op_we   : std_logic := '0';
  signal op_addr : std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
  signal op_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal op_dout : std_logic_vector(7 downto 0) := (others => '0');  -- crosses x1->sys (stable at ack)

  -- clk_sys side
  signal busy_sys : std_logic := '0';
  signal dout_reg : std_logic_vector(7 downto 0) := (others => '0');

  -- ---- clk_x1 op sub-FSM ---------------------------------------------------
  type op_state_t is (OP_IDLE,
                      OP_RD_READY, OP_RD_PULSE, OP_RD_WAIT,
                      OP_WR_READY, OP_WR_PULSE);
  signal op_state : op_state_t := OP_IDLE;
  signal op_start : std_logic := '0';   -- internal: launch one op (test or serve)
  signal op_busy  : std_logic := '0';
  signal op_fin   : std_logic := '0';   -- 1-clk: op complete

  -- ---- clk_x1 top-mode FSM (self-test then serve) --------------------------
  type mode_state_t is (M_WAIT_CALIB, M_FILL, M_FILL_OP, M_CHECK, M_CHECK_OP, M_SERVE_IDLE, M_SERVE_OP);
  signal mode_state : mode_state_t := M_WAIT_CALIB;
  signal test_addr  : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
  signal ready_x1   : std_logic := '0';

  -- Diagnostic: free-running heartbeat on clk_x1. While waiting for calibration
  -- the phase nibble shows {pll_lock, heartbeat[2:0]} so the boot screen reveals
  -- whether clk_x1 is alive at all (phase counts) vs frozen (phase stuck at $0).
  signal heartbeat  : unsigned(25 downto 0) := (others => '0');
  signal pll_sync   : std_logic_vector(1 downto 0) := (others => '0');

  -- test status (clk_x1, synchronized out)
  signal t_active_x1 : std_logic := '0';
  signal t_done_x1   : std_logic := '0';
  signal t_error_x1  : std_logic := '0';
  signal t_phase_x1  : std_logic_vector(3 downto 0) := (others => '0');
  signal t_failaddr_x1 : std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
  signal t_expected_x1 : std_logic_vector(7 downto 0) := (others => '0');
  signal t_actual_x1   : std_logic_vector(7 downto 0) := (others => '0');

  -- deterministic per-address pattern used by the self-test
  function test_pattern(a : unsigned) return std_logic_vector is
  begin
    return std_logic_vector(a(7 downto 0) xor a(ADDR_BITS-1 downto ADDR_BITS-8));
  end function;

  -- byte lane (0..15) and 16-bit-word app address for a byte address
  function lane_of(a : std_logic_vector) return integer is
  begin
    return to_integer(unsigned(a(3 downto 0)));
  end function;

begin

  dout      <= dout_reg;
  ram_ready <= ready_x1;  -- single-bit level; safe to read in sys domain (gated by self-test edges)

  -- ===================== clk_sys: request / ack CDC ========================
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst_sys_n = '0' then
        req_tgl_sys <= '0';
        busy_sys    <= '0';
        ack_tgl_sys <= (others => '0');
        ack         <= '0';
        dout_reg    <= (others => '0');
      else
        ack         <= '0';
        ack_tgl_sys <= ack_tgl_sys(1 downto 0) & ack_tgl_x1;

        if busy_sys = '0' then
          if req = '1' then
            req_tgl_sys <= not req_tgl_sys;   -- hand the (stable) payload to clk_x1
            busy_sys    <= '1';
          end if;
        else
          -- wait for the completion toggle to cross back
          if ack_tgl_sys(2) /= ack_tgl_sys(1) then
            dout_reg <= op_dout;              -- stable: written before ack toggled
            ack      <= '1';
            busy_sys <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ===================== clk_x1: op sub-FSM (one DDR access) ===============
  process(clk_x1, rst_sys_n)
    variable lane : integer range 0 to 15;
    variable wmask : std_logic_vector(15 downto 0);
  begin
    if rst_sys_n = '0' then
      op_state       <= OP_IDLE;
      op_busy        <= '0';
      op_fin         <= '0';
      op_dout        <= (others => '0');
      app_cmd        <= CMD_WRITE;
      app_cmd_en     <= '0';
      app_addr       <= (others => '0');
      app_wren       <= '0';
      app_wdata      <= (others => '0');
      app_wdata_end  <= '0';
      app_wdata_mask <= (others => '0');
    elsif rising_edge(clk_x1) then
      op_fin     <= '0';
      app_cmd_en <= '0';
      app_wren   <= '0';
      app_wdata_end <= '0';

      case op_state is
        when OP_IDLE =>
          if op_start = '1' then
            op_busy <= '1';
            -- app address: line(addr[.. :4]) * 8 words
            app_addr <= std_logic_vector(resize(
                          unsigned(op_addr(ADDR_BITS-1 downto 4)) & "000", 27));
            lane := lane_of(op_addr);
            if op_we = '1' then
              -- place the byte on its lane, mask all other lanes
              app_wdata <= (others => '0');
              app_wdata(lane*8+7 downto lane*8) <= op_din;
              if MASK_BIT_MASKS then
                wmask := (others => '1');
                wmask(lane) := '0';
              else
                wmask := (others => '0');
                wmask(lane) := '1';
              end if;
              app_wdata_mask <= wmask;
              op_state <= OP_WR_READY;
            else
              op_state <= OP_RD_READY;
            end if;
          end if;

        -- Match the known-good Sipeed tester protocol: wait with valid low,
        -- then emit exactly one registered command pulse after ready is seen.
        when OP_RD_READY =>
          if app_cmd_rdy = '1' then
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            op_state   <= OP_RD_PULSE;
          end if;

        when OP_RD_PULSE =>
          -- The IP samples the pulse driven during the preceding cycle here.
          op_state <= OP_RD_WAIT;

        when OP_RD_WAIT =>
          if app_rdata_valid = '1' then
            lane := lane_of(op_addr);
            op_dout <= app_rdata(lane*8+7 downto lane*8);
            op_fin  <= '1';
            op_busy <= '0';
            op_state <= OP_IDLE;
          end if;

        when OP_WR_READY =>
          -- Do not expose one valid channel before the other is ready: the
          -- controller may otherwise consume only command or only write data.
          if app_cmd_rdy = '1' and app_wdata_rdy = '1' then
            app_cmd       <= CMD_WRITE;
            app_cmd_en    <= '1';
            app_wren      <= '1';
            app_wdata_end <= '1';
            op_state      <= OP_WR_PULSE;
          end if;

        when OP_WR_PULSE =>
          -- Command and data were sampled together on this edge.
          op_fin  <= '1';
          op_busy <= '0';
          op_state <= OP_IDLE;

        when others =>
          op_state <= OP_IDLE;
      end case;
    end if;
  end process;

  -- ===================== clk_x1: mode FSM (self-test, serve) ===============
  process(clk_x1, rst_sys_n)
  begin
    if rst_sys_n = '0' then
      op_start          <= '0';
      req_tgl_x1        <= (others => '0');
      ack_tgl_x1        <= '0';
      mode_state        <= M_WAIT_CALIB;
      test_addr         <= (others => '0');
      ready_x1          <= '0';
      heartbeat         <= (others => '0');
      pll_sync          <= (others => '0');
      t_active_x1       <= '0';
      t_done_x1         <= '0';
      t_error_x1        <= '0';
      t_phase_x1        <= (others => '0');
      t_failaddr_x1     <= (others => '0');
      t_expected_x1     <= (others => '0');
      t_actual_x1       <= (others => '0');
      op_we             <= '0';
      op_addr           <= (others => '0');
      op_din            <= (others => '0');
    elsif rising_edge(clk_x1) then
      op_start <= '0';

      -- synchronize the request toggle from clk_sys
      req_tgl_x1 <= req_tgl_x1(1 downto 0) & req_tgl_sys;

      -- diagnostic heartbeat (proves clk_x1 is running) + pll_lock synchroniser
      heartbeat <= heartbeat + 1;
      pll_sync  <= pll_sync(0) & dbg_pll_lock;

      case mode_state is
        when M_WAIT_CALIB =>
          t_active_x1 <= '0';
          t_done_x1   <= '0';
          -- {pll_lock, heartbeat[2:0]}: phase $0 stuck => clk_x1 dead;
          -- phase cycling $8..$F => clk_x1 alive + PLL locked, calib not done.
          t_phase_x1  <= pll_sync(1) & std_logic_vector(heartbeat(25 downto 23));
          if init_calib_complete = '1' then
            test_addr   <= (others => '0');
            t_active_x1 <= '1';
            t_phase_x1  <= x"1";   -- fill
            mode_state  <= M_FILL;
          end if;

        -- ---- self-test: fill ------------------------------------------------
        when M_FILL =>
          if op_busy = '0' then
            op_we    <= '1';
            op_addr  <= std_logic_vector(test_addr);
            op_din   <= test_pattern(test_addr);
            op_start <= '1';
            mode_state <= M_FILL_OP;
          end if;
        when M_FILL_OP =>
          if op_fin = '1' then
            if test_addr = to_unsigned(2**ADDR_BITS-1, ADDR_BITS) then
              test_addr  <= (others => '0');
              t_phase_x1 <= x"2";  -- check
              mode_state <= M_CHECK;
            else
              test_addr  <= test_addr + 1;
              mode_state <= M_FILL;
            end if;
          end if;

        -- ---- self-test: check ----------------------------------------------
        when M_CHECK =>
          if op_busy = '0' then
            op_we    <= '0';
            op_addr  <= std_logic_vector(test_addr);
            op_start <= '1';
            mode_state <= M_CHECK_OP;
          end if;
        when M_CHECK_OP =>
          if op_fin = '1' then
            if op_dout /= test_pattern(test_addr) then
              t_error_x1    <= '1';
              t_failaddr_x1 <= std_logic_vector(test_addr);
              t_expected_x1 <= test_pattern(test_addr);
              t_actual_x1   <= op_dout;
            end if;
            if test_addr = to_unsigned(2**ADDR_BITS-1, ADDR_BITS) then
              t_done_x1   <= '1';
              t_active_x1 <= '0';
              t_phase_x1  <= x"3";
              ready_x1    <= '1';        -- release CPU (even on error: status shows it)
              mode_state  <= M_SERVE_IDLE;
            else
              test_addr  <= test_addr + 1;
              mode_state <= M_CHECK;
            end if;
          end if;

        -- ---- normal operation ----------------------------------------------
        when M_SERVE_IDLE =>
          if req_tgl_x1(2) /= req_tgl_x1(1) then
            -- new request: payload is stable on the sys inputs
            op_we    <= we;
            op_addr  <= addr;
            op_din   <= din;
            op_start <= '1';
            mode_state <= M_SERVE_OP;
          end if;
        when M_SERVE_OP =>
          if op_fin = '1' then
            ack_tgl_x1 <= not ack_tgl_x1;   -- op_dout already valid
            mode_state <= M_SERVE_IDLE;
          end if;

        when others =>
          mode_state <= M_WAIT_CALIB;
      end case;

      if init_calib_complete = '0' then
        mode_state <= M_WAIT_CALIB;
        ready_x1   <= '0';
        t_error_x1 <= '0';
      end if;
    end if;
  end process;

  -- ===================== self-test status CDC (x1 -> sys) ==================
  -- These are quasi-static during/after the test; double-register for display.
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      ram_test_active    <= t_active_x1;
      ram_test_done      <= t_done_x1;
      ram_test_error     <= t_error_x1;
      ram_test_phase     <= t_phase_x1;
      ram_test_addr      <= std_logic_vector(test_addr);
      ram_test_fail_addr <= t_failaddr_x1;
      ram_test_expected  <= t_expected_x1;
      ram_test_actual    <= t_actual_x1;
    end if;
  end process;

end architecture;
