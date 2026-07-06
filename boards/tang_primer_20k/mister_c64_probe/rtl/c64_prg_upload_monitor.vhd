library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Tiny UART monitor subset for tools/c64_uart_prg_loader.py.
-- Supports only:
--   L aaaa       enter hex load mode at address aaaa
--   .            finish load mode and return to command prompt
--   G            release the paused C64 core
-- With ENABLE_DUMP additionally:
--   M aaaa bbbb  hex dump aaaa..bbbb inclusive, 8 bytes per line followed by
--                an ASCII column (non-printable bytes as '.'); reads go
--                through the same memory port (RAM under ROM/I/O)
entity c64_prg_upload_monitor is
  generic (
    ENABLE_DUMP : boolean := false;
    -- When true, "G aaaa" parses a hex address and pulses jump_req/jump_addr to
    -- run an uploaded program there; a bare "G" still just releases the CPU. The
    -- C64 boards leave this false, so their "G" behaves exactly as before.
    ENABLE_JUMP : boolean := false
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    enter_btn : in  std_logic;

    rx_data  : in  std_logic_vector(7 downto 0);
    rx_valid : in  std_logic;

    tx_busy  : in  std_logic;
    tx_data  : out std_logic_vector(7 downto 0);
    tx_valid : out std_logic;
    active   : out std_logic;

    mem_req   : out std_logic;
    mem_we    : out std_logic;
    mem_addr  : out std_logic_vector(15 downto 0);
    mem_wdata : out std_logic_vector(7 downto 0);
    mem_rdata : in  std_logic_vector(7 downto 0) := (others => '0');
    mem_ready : in  std_logic;

    -- Optional "run at address" (only with ENABLE_JUMP): 1-clk pulse + target.
    jump_req  : out std_logic := '0';
    jump_addr : out std_logic_vector(15 downto 0) := (others => '0')
  );
end entity;

architecture rtl of c64_prg_upload_monitor is
  type state_t is (
    S_OFF, S_BANNER, S_PROMPT, S_CMD,
    S_LOAD_PROMPT, S_LOAD,
    S_WRITE_REQ, S_WRITE_WAIT,
    S_EMIT, S_DUMP_STEP, S_DUMP_READ, S_DUMP_RWAIT,
    S_ERROR, S_RELEASE
  );
  type msg_t is (MSG_BANNER, MSG_PROMPT, MSG_LOAD, MSG_ERR, MSG_DYN);
  type dump_phase_t is (DP_HDR, DP_BYTE, DP_PAD, DP_ASC, DP_EOL);

  signal state : state_t := S_OFF;
  signal ret_state : state_t := S_CMD;
  signal msg : msg_t := MSG_BANNER;
  signal msg_idx : integer range 0 to 15 := 0;
  signal active_r : std_logic := '0';
  signal enter_d : std_logic := '0';

  signal tx_data_r : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid_r : std_logic := '0';
  signal wait_uart : std_logic := '0';
  signal seen_busy : std_logic := '0';

  signal cmd : std_logic_vector(7 downto 0) := (others => '0');
  signal jump_req_r : std_logic := '0';
  signal addr : unsigned(15 downto 0) := (others => '0');
  signal addr_nibs : integer range 0 to 8 := 0;
  signal hi_nib : std_logic_vector(3 downto 0) := (others => '0');
  signal have_hi : std_logic := '0';
  signal write_byte : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_req_r : std_logic := '0';
  signal mem_we_r  : std_logic := '1';

  -- M dump engine (only reachable when ENABLE_DUMP; pruned otherwise)
  type dump_line_t is array (0 to 7) of std_logic_vector(7 downto 0);
  signal addr2     : unsigned(15 downto 0) := (others => '0');
  signal rbyte     : std_logic_vector(7 downto 0) := (others => '0');
  signal lbuf      : dump_line_t := (others => (others => '0'));
  signal lend      : integer range 0 to 7 := 0;
  signal pad_left  : integer range 0 to 22 := 0;
  signal dyn_char  : std_logic_vector(7 downto 0) := (others => '0');
  signal dphase    : dump_phase_t := DP_HDR;
  signal didx      : integer range 0 to 7 := 0;
  signal dcol      : integer range 0 to 7 := 0;
  signal dump_done : std_logic := '0';

  function asc(c : character) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(character'pos(c), 8));
  end function;

  function upper(c : std_logic_vector(7 downto 0)) return std_logic_vector is
  begin
    if c >= x"61" and c <= x"7A" then
      return std_logic_vector(unsigned(c) - 32);
    end if;
    return c;
  end function;

  function is_space(c : std_logic_vector(7 downto 0)) return boolean is
  begin
    return c = x"20" or c = x"09" or c = x"0D" or c = x"0A";
  end function;

  -- End-of-line only (CR/LF), used to tell a bare "G<CR>" (release) from
  -- "G <addr>" (jump): a plain space after G is a leading separator, not the end.
  function is_eol(c : std_logic_vector(7 downto 0)) return boolean is
  begin
    return c = x"0D" or c = x"0A";
  end function;

  function is_hex(c : std_logic_vector(7 downto 0)) return boolean is
    variable u : std_logic_vector(7 downto 0);
  begin
    u := upper(c);
    return (u >= x"30" and u <= x"39") or (u >= x"41" and u <= x"46");
  end function;

  function hex_nib(c : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable u : std_logic_vector(7 downto 0);
  begin
    u := upper(c);
    if u <= x"39" then
      return u(3 downto 0);
    end if;
    return std_logic_vector(to_unsigned(to_integer(unsigned(u)) - 55, 4));
  end function;

  function msg_len(m : msg_t) return integer is
  begin
    case m is
      when MSG_BANNER => return 16; -- "FPGA MONITOR\r\n. "
      when MSG_PROMPT => return 2;  -- ". "
      when MSG_LOAD   => return 2;  -- "> "
      when MSG_ERR    => return 5;  -- "?\r\n. "
      when MSG_DYN    => return 1;  -- one dump character from dyn_char
    end case;
  end function;

  function nib_asc(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u : unsigned(3 downto 0);
  begin
    u := unsigned(n);
    if u < 10 then
      return std_logic_vector(to_unsigned(48 + to_integer(u), 8));   -- '0'..'9'
    end if;
    return std_logic_vector(to_unsigned(55 + to_integer(u), 8));     -- 'A'..'F'
  end function;

  function msg_char(m : msg_t; i : integer) return std_logic_vector is
  begin
    case m is
      when MSG_BANNER =>
        case i is
          when 0 => return asc('F');
          when 1 => return asc('P');
          when 2 => return asc('G');
          when 3 => return asc('A');
          when 4 => return asc(' ');
          when 5 => return asc('M');
          when 6 => return asc('O');
          when 7 => return asc('N');
          when 8 => return asc('I');
          when 9 => return asc('T');
          when 10 => return asc('O');
          when 11 => return asc('R');
          when 12 => return x"0D";
          when 13 => return x"0A";
          when 14 => return asc('.');
          when others => return asc(' ');
        end case;
      when MSG_PROMPT =>
        if i = 0 then return asc('.'); end if;
        return asc(' ');
      when MSG_LOAD =>
        if i = 0 then return asc('>'); end if;
        return asc(' ');
      when MSG_ERR =>
        case i is
          when 0 => return asc('?');
          when 1 => return x"0D";
          when 2 => return x"0A";
          when 3 => return asc('.');
          when others => return asc(' ');
        end case;
      when MSG_DYN =>
        return x"00";   -- replaced by dyn_char in the emitter
    end case;
  end function;
begin
  tx_data <= tx_data_r;
  tx_valid <= tx_valid_r;
  active <= active_r;
  mem_req <= mem_req_r;
  mem_we <= mem_we_r;
  mem_addr <= std_logic_vector(addr);
  mem_wdata <= write_byte;
  jump_req <= jump_req_r;
  jump_addr <= std_logic_vector(addr);

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state <= S_OFF;
        active_r <= '0';
        enter_d <= '0';
        tx_valid_r <= '0';
        wait_uart <= '0';
        seen_busy <= '0';
        mem_req_r <= '0';
        mem_we_r <= '1';
        jump_req_r <= '0';
      else
        tx_valid_r <= '0';
        mem_req_r <= '0';
        jump_req_r <= '0';
        enter_d <= enter_btn;

        if wait_uart = '1' then
          if tx_busy = '1' then
            seen_busy <= '1';
          elsif seen_busy = '1' then
            wait_uart <= '0';
            seen_busy <= '0';
            if msg_idx + 1 >= msg_len(msg) then
              state <= ret_state;
              msg_idx <= 0;
            else
              msg_idx <= msg_idx + 1;
            end if;
          end if;
        else
          case state is
            when S_OFF =>
              if active_r = '0' and enter_btn = '1' and enter_d = '0' then
                active_r <= '1';
                msg <= MSG_BANNER;
                msg_idx <= 0;
                ret_state <= S_CMD;
                state <= S_BANNER;
              end if;

            when S_BANNER | S_PROMPT | S_LOAD_PROMPT | S_ERROR | S_EMIT =>
              if tx_busy = '0' then
                if msg = MSG_DYN then
                  tx_data_r <= dyn_char;
                else
                  tx_data_r <= msg_char(msg, msg_idx);
                end if;
                tx_valid_r <= '1';
                wait_uart <= '1';
              end if;

            when S_CMD =>
              if rx_valid = '1' then
                if cmd = asc('L') then
                  if is_hex(rx_data) and addr_nibs < 4 then
                    addr <= addr(11 downto 0) & unsigned(hex_nib(rx_data));
                    addr_nibs <= addr_nibs + 1;
                  elsif is_space(rx_data) and addr_nibs = 0 then
                    null;
                  elsif is_space(rx_data) and addr_nibs = 4 then
                    cmd <= (others => '0');
                    have_hi <= '0';
                    msg <= MSG_LOAD;
                    msg_idx <= 0;
                    ret_state <= S_LOAD;
                    state <= S_LOAD_PROMPT;
                  else
                    cmd <= (others => '0');
                    msg <= MSG_ERR;
                    msg_idx <= 0;
                    ret_state <= S_CMD;
                    state <= S_ERROR;
                  end if;
                elsif cmd = asc('M') then
                  -- M aaaa bbbb: nibbles 0-3 -> start, 4-7 -> end address
                  if is_hex(rx_data) and addr_nibs < 4 then
                    addr <= addr(11 downto 0) & unsigned(hex_nib(rx_data));
                    addr_nibs <= addr_nibs + 1;
                  elsif is_hex(rx_data) and addr_nibs < 8 then
                    addr2 <= addr2(11 downto 0) & unsigned(hex_nib(rx_data));
                    addr_nibs <= addr_nibs + 1;
                  elsif is_space(rx_data) and (addr_nibs = 0 or addr_nibs = 4) then
                    null;
                  elsif is_space(rx_data) and addr_nibs = 8 then
                    cmd <= (others => '0');
                    dump_done <= '0';
                    dphase <= DP_HDR;
                    didx <= 0;
                    dcol <= 0;
                    state <= S_DUMP_STEP;
                  else
                    cmd <= (others => '0');
                    msg <= MSG_ERR;
                    msg_idx <= 0;
                    ret_state <= S_CMD;
                    state <= S_ERROR;
                  end if;
                elsif ENABLE_JUMP and cmd = asc('G') then
                  -- G aaaa: collect up to 4 hex nibbles, then jump; a bare
                  -- "G<CR>" (no nibbles) just releases the CPU like before.
                  if is_hex(rx_data) and addr_nibs < 4 then
                    addr <= addr(11 downto 0) & unsigned(hex_nib(rx_data));
                    addr_nibs <= addr_nibs + 1;
                  elsif is_eol(rx_data) and addr_nibs = 0 then
                    cmd <= (others => '0');
                    state <= S_RELEASE;
                  elsif is_space(rx_data) and addr_nibs = 0 then
                    null;   -- leading separator between 'G' and the address
                  elsif is_space(rx_data) and addr_nibs = 4 then
                    cmd <= (others => '0');
                    jump_req_r <= '1';      -- run at addr (mem_addr already = addr)
                    state <= S_RELEASE;
                  else
                    cmd <= (others => '0');
                    msg <= MSG_ERR;
                    msg_idx <= 0;
                    ret_state <= S_CMD;
                    state <= S_ERROR;
                  end if;
                elsif is_space(rx_data) then
                  null;
                elsif upper(rx_data) = asc('G') then
                  if ENABLE_JUMP then
                    cmd <= asc('G');
                    addr <= (others => '0');
                    addr_nibs <= 0;
                  else
                    state <= S_RELEASE;
                  end if;
                elsif upper(rx_data) = asc('L') then
                  cmd <= asc('L');
                  addr <= (others => '0');
                  addr_nibs <= 0;
                elsif ENABLE_DUMP and upper(rx_data) = asc('M') then
                  cmd <= asc('M');
                  addr <= (others => '0');
                  addr2 <= (others => '0');
                  addr_nibs <= 0;
                else
                  msg <= MSG_ERR;
                  msg_idx <= 0;
                  ret_state <= S_CMD;
                  state <= S_ERROR;
                end if;
              end if;

            when S_LOAD =>
              if rx_valid = '1' then
                if rx_data = asc('.') then
                  have_hi <= '0';
                  msg <= MSG_PROMPT;
                  msg_idx <= 0;
                  ret_state <= S_CMD;
                  state <= S_PROMPT;
                elsif is_space(rx_data) then
                  null;
                elsif is_hex(rx_data) then
                  if have_hi = '0' then
                    hi_nib <= hex_nib(rx_data);
                    have_hi <= '1';
                  else
                    write_byte <= hi_nib & hex_nib(rx_data);
                    have_hi <= '0';
                    state <= S_WRITE_REQ;
                  end if;
                else
                  have_hi <= '0';
                  msg <= MSG_ERR;
                  msg_idx <= 0;
                  ret_state <= S_LOAD;
                  state <= S_ERROR;
                end if;
              end if;

            when S_WRITE_REQ =>
              mem_req_r <= '1';
              state <= S_WRITE_WAIT;

            when S_WRITE_WAIT =>
              mem_req_r <= '1';
              if mem_ready = '1' then
                addr <= addr + 1;
                state <= S_LOAD;
              end if;

            -- ---- M dump engine: emits "AAAA: xx xx ... \r\n" lines ----
            when S_DUMP_STEP =>
              case dphase is
                when DP_HDR =>
                  case didx is
                    when 0 => dyn_char <= nib_asc(std_logic_vector(addr(15 downto 12)));
                    when 1 => dyn_char <= nib_asc(std_logic_vector(addr(11 downto 8)));
                    when 2 => dyn_char <= nib_asc(std_logic_vector(addr(7 downto 4)));
                    when 3 => dyn_char <= nib_asc(std_logic_vector(addr(3 downto 0)));
                    when 4 => dyn_char <= asc(':');
                    when others => dyn_char <= asc(' ');
                  end case;
                  if didx = 5 then
                    didx <= 0;
                    -- last header char still goes out, then the first read
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_READ;
                    state <= S_EMIT;
                  else
                    didx <= didx + 1;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP;
                    state <= S_EMIT;
                  end if;

                when DP_BYTE =>
                  if didx = 0 then
                    dyn_char <= nib_asc(rbyte(7 downto 4));
                    didx <= 1;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  elsif didx = 1 then
                    dyn_char <= nib_asc(rbyte(3 downto 0));
                    didx <= 2;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  elsif didx = 2 then
                    dyn_char <= asc(' ');
                    didx <= 3;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  else
                    -- byte printed: advance, or pad + ASCII column at the
                    -- end of the line / the dump
                    if addr = addr2 then
                      dump_done <= '1';
                      lend <= dcol;
                      pad_left <= (7 - dcol) * 3 + 1;
                      dphase <= DP_PAD;
                      didx <= 0;
                    else
                      addr <= addr + 1;
                      if dcol = 7 then
                        lend <= 7;
                        pad_left <= 1;
                        dcol <= 0;
                        dphase <= DP_PAD;
                        didx <= 0;
                      else
                        dcol <= dcol + 1;
                        state <= S_DUMP_READ;
                      end if;
                    end if;
                  end if;

                when DP_PAD =>
                  -- fill the hex area to constant width + 1 separator space
                  if pad_left = 0 then
                    dphase <= DP_ASC;
                    didx <= 0;
                  else
                    dyn_char <= asc(' ');
                    pad_left <= pad_left - 1;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  end if;

                when DP_ASC =>
                  if lbuf(didx) >= x"20" and lbuf(didx) <= x"7E" then
                    dyn_char <= lbuf(didx);
                  else
                    dyn_char <= asc('.');
                  end if;
                  if didx = lend then
                    didx <= 0;
                    dphase <= DP_EOL;
                  else
                    didx <= didx + 1;
                  end if;
                  msg <= MSG_DYN; msg_idx <= 0;
                  ret_state <= S_DUMP_STEP; state <= S_EMIT;

                when DP_EOL =>
                  if didx = 0 then
                    dyn_char <= x"0D";
                    didx <= 1;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  elsif didx = 1 then
                    dyn_char <= x"0A";
                    didx <= 2;
                    msg <= MSG_DYN; msg_idx <= 0;
                    ret_state <= S_DUMP_STEP; state <= S_EMIT;
                  elsif dump_done = '1' then
                    msg <= MSG_PROMPT;
                    msg_idx <= 0;
                    ret_state <= S_CMD;
                    state <= S_PROMPT;
                  else
                    dphase <= DP_HDR;
                    didx <= 0;
                    state <= S_DUMP_STEP;
                  end if;
              end case;

            when S_DUMP_READ =>
              mem_we_r <= '0';
              mem_req_r <= '1';
              state <= S_DUMP_RWAIT;

            when S_DUMP_RWAIT =>
              mem_we_r <= '0';
              mem_req_r <= '1';
              if mem_ready = '1' then
                rbyte <= mem_rdata;
                lbuf(dcol) <= mem_rdata;   -- for the ASCII column
                mem_we_r <= '1';
                mem_req_r <= '0';
                dphase <= DP_BYTE;
                didx <= 0;
                state <= S_DUMP_STEP;
              end if;

            when S_RELEASE =>
              active_r <= '0';
              cmd <= (others => '0');
              state <= S_OFF;

            when others =>
              state <= S_OFF;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
