library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Tiny UART monitor subset for tools/c64_uart_prg_loader.py.
-- Supports only:
--   L aaaa  enter hex load mode at address aaaa
--   .       finish load mode and return to command prompt
--   G       release the paused C64 core
entity c64_prg_upload_monitor is
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
    mem_ready : in  std_logic
  );
end entity;

architecture rtl of c64_prg_upload_monitor is
  type state_t is (
    S_OFF, S_BANNER, S_PROMPT, S_CMD,
    S_LOAD_PROMPT, S_LOAD,
    S_WRITE_REQ, S_WRITE_WAIT,
    S_ERROR, S_RELEASE
  );
  type msg_t is (MSG_BANNER, MSG_PROMPT, MSG_LOAD, MSG_ERR);

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
  signal addr : unsigned(15 downto 0) := (others => '0');
  signal addr_nibs : integer range 0 to 4 := 0;
  signal hi_nib : std_logic_vector(3 downto 0) := (others => '0');
  signal have_hi : std_logic := '0';
  signal write_byte : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_req_r : std_logic := '0';

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
    end case;
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
    end case;
  end function;
begin
  tx_data <= tx_data_r;
  tx_valid <= tx_valid_r;
  active <= active_r;
  mem_req <= mem_req_r;
  mem_we <= '1';
  mem_addr <= std_logic_vector(addr);
  mem_wdata <= write_byte;

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
      else
        tx_valid_r <= '0';
        mem_req_r <= '0';
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

            when S_BANNER | S_PROMPT | S_LOAD_PROMPT | S_ERROR =>
              if tx_busy = '0' then
                tx_data_r <= msg_char(msg, msg_idx);
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
                elsif is_space(rx_data) then
                  null;
                elsif upper(rx_data) = asc('G') then
                  state <= S_RELEASE;
                elsif upper(rx_data) = asc('L') then
                  cmd <= asc('L');
                  addr <= (others => '0');
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
