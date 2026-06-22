-- SD Disk Controller: bridges 6502 memory-mapped registers to sd_card_top
-- sector read/write interface with an internal 512-byte transfer buffer.
--
-- Register map (offset from ADDR_DISK_BASE $8824, accent on 12-byte window):
--   +0  CMD      W: command (01=read, 02=write)  R: last command
--   +1  STATUS   R: bit7=init_done bit2=data_ready bit1=error bit0=busy
--   +2  SECT_0   Sector LBA byte 0 (LSB)
--   +3  SECT_1   Sector LBA byte 1
--   +4  SECT_2   Sector LBA byte 2
--   +5  SECT_3   Sector LBA byte 3 (MSB)
--   +6  DATA     R/W data port — accesses buffer[ptr], ptr auto-increments
--   +7  DPTR_L   Buffer pointer bits [7:0]  (R/W)
--   +8  DPTR_H   Buffer pointer bit  [8]    (R/W, bit 0 only)
--
-- Usage from 6502:
--   SAVE: fill buffer via DATA port, set SECT, write CMD=$02, poll STATUS.
--   LOAD: set SECT, write CMD=$01, poll STATUS until not busy, read DATA.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity sd_disk_ctrl is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    cs        : in  std_logic;
    we        : in  std_logic;
    addr      : in  addr_t;
    din       : in  data_t;
    dout      : out data_t;
    irq       : out std_logic;
    -- sd_card_top sector interface
    sd_init_done           : in  std_logic;
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  data_t;
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic;
    sd_sec_write           : out std_logic;
    sd_sec_write_addr      : out std_logic_vector(31 downto 0);
    sd_sec_write_data      : out data_t;
    sd_sec_write_data_req  : in  std_logic;
    sd_sec_write_end       : in  std_logic
  );
end entity;

architecture rtl of sd_disk_ctrl is
  -- 512-byte sector buffer — single read address, all accesses synchronous
  -- to avoid Gowin DPB unsupported write-mode inference.
  type buf_t is array (0 to 511) of data_t;
  signal buf : buf_t := (others => (others => '0'));

  -- CPU-facing registers
  signal reg_cmd    : data_t := (others => '0');
  signal reg_sect   : std_logic_vector(31 downto 0) := (others => '0');
  signal buf_ptr    : unsigned(8 downto 0) := (others => '0');  -- 0..511

  -- Status flags
  signal busy       : std_logic := '0';
  signal error      : std_logic := '0';
  signal data_ready : std_logic := '0';

  -- Controller FSM
  type state_t is (
    S_IDLE,
    S_READ_START,  S_READ_DATA,  S_READ_DONE,
    S_WRITE_START, S_WRITE_DATA, S_WRITE_DONE
  );
  signal state : state_t := S_IDLE;

  -- SD-side buffer pointer for streaming transfers
  signal sd_ptr : unsigned(8 downto 0) := (others => '0');

  -- Register offset from base address
  signal reg_offset : unsigned(3 downto 0);

  -- Single synchronous read port: muxed between CPU (buf_ptr) and SD (sd_ptr).
  -- CPU accesses only when idle; SD accesses only when busy.
  signal buf_rd_addr : unsigned(8 downto 0);
  signal buf_rd_data : data_t := (others => '0');

  -- A CPU access to the DATA register ($882A) holds cs high for the whole CPU
  -- cycle (2 system clocks, cpu_enable toggling), while the write strobe `we`
  -- pulses for only one of them.  To advance buf_ptr exactly once per access --
  -- and to do it AFTER the data has been written/read so buf_rd_data stays
  -- stable during the access -- the pointer is post-incremented on the falling
  -- edge of the DATA access, regardless of read or write.
  signal data_acc      : std_logic;            -- access to DATA reg (comb)
  signal data_acc_prev : std_logic := '0';     -- registered, for edge detect

begin
  reg_offset <= resize(unsigned(addr) - ADDR_DISK_BASE, 4);
  irq <= '0';

  sd_sec_read_addr  <= reg_sect;
  sd_sec_write_addr <= reg_sect;

  buf_rd_addr <= sd_ptr when busy = '1' else buf_ptr;
  sd_sec_write_data <= buf_rd_data;
  data_acc <= '1' when cs = '1' and busy = '0' and
              resize(unsigned(addr) - ADDR_DISK_BASE, 4) = 6 else '0';

  -- Main process: register access + controller FSM
  process(clk)
    variable off : unsigned(3 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        reg_cmd    <= (others => '0');
        reg_sect   <= (others => '0');
        buf_ptr    <= (others => '0');
        busy       <= '0';
        error      <= '0';
        data_ready <= '0';
        state      <= S_IDLE;
        sd_ptr     <= (others => '0');
        sd_sec_read  <= '0';
        sd_sec_write <= '0';
        buf_rd_data  <= (others => '0');
        data_acc_prev <= '0';
      else
        sd_sec_read  <= '0';
        sd_sec_write <= '0';

        -- Single synchronous read from buffer (1-cycle latency)
        buf_rd_data <= buf(to_integer(buf_rd_addr));

        off := reg_offset;

        -- CPU register writes
        if cs = '1' and we = '1' then
          case to_integer(off) is
            when 0 =>  -- CMD
              if busy = '0' then
                reg_cmd <= din;
                if sd_init_done = '0' then
                  error <= '1';
                elsif din = x"01" then
                  state      <= S_READ_START;
                  busy       <= '1';
                  error      <= '0';
                  data_ready <= '0';
                  sd_ptr     <= (others => '0');
                elsif din = x"02" then
                  state      <= S_WRITE_START;
                  busy       <= '1';
                  error      <= '0';
                  data_ready <= '0';
                  sd_ptr     <= (others => '0');
                end if;
              end if;
            when 2 => reg_sect( 7 downto  0) <= din;
            when 3 => reg_sect(15 downto  8) <= din;
            when 4 => reg_sect(23 downto 16) <= din;
            when 5 => reg_sect(31 downto 24) <= din;
            when 6 =>  -- DATA write (pointer advances at end of access)
              if busy = '0' then
                buf(to_integer(buf_ptr)) <= din;
              end if;
            when 7 => buf_ptr(7 downto 0) <= unsigned(din);
            when 8 => buf_ptr(8) <= din(0);
            when others => null;
          end case;
        end if;

        -- Post-increment buf_ptr once per DATA access, on the falling edge of
        -- the access (after both write phases / the read have completed). This
        -- advances the pointer exactly once whether the CPU read or wrote, and
        -- keeps buf_rd_data stable for the whole access. A simultaneous DPTR
        -- write (offset 7/8) cannot collide: data_acc is only high for offset 6.
        data_acc_prev <= data_acc;
        if data_acc = '0' and data_acc_prev = '1' then
          buf_ptr <= buf_ptr + 1;
        end if;

        -- Controller FSM
        case state is
          when S_IDLE =>
            null;

          when S_READ_START =>
            sd_sec_read <= '1';
            state <= S_READ_DATA;

          when S_READ_DATA =>
            if sd_sec_read_data_valid = '1' then
              buf(to_integer(sd_ptr)) <= sd_sec_read_data;
              sd_ptr <= sd_ptr + 1;
            end if;
            if sd_sec_read_end = '1' then
              state <= S_READ_DONE;
            end if;

          when S_READ_DONE =>
            busy       <= '0';
            data_ready <= '1';
            buf_ptr    <= (others => '0');
            state      <= S_IDLE;

          when S_WRITE_START =>
            sd_sec_write <= '1';
            state <= S_WRITE_DATA;

          when S_WRITE_DATA =>
            if sd_sec_write_data_req = '1' then
              sd_ptr <= sd_ptr + 1;
            end if;
            if sd_sec_write_end = '1' then
              state <= S_WRITE_DONE;
            end if;

          when S_WRITE_DONE =>
            busy       <= '0';
            data_ready <= '0';
            state      <= S_IDLE;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- Combinational read mux
  process(reg_offset, reg_cmd, busy, error, data_ready, sd_init_done,
          reg_sect, buf_rd_data, buf_ptr)
  begin
    case to_integer(reg_offset) is
      when 0 => dout <= reg_cmd;
      when 1 => dout <= sd_init_done & "0000" & data_ready & error & busy;
      when 2 => dout <= reg_sect( 7 downto  0);
      when 3 => dout <= reg_sect(15 downto  8);
      when 4 => dout <= reg_sect(23 downto 16);
      when 5 => dout <= reg_sect(31 downto 24);
      when 6 => dout <= buf_rd_data;
      when 7 => dout <= std_logic_vector(buf_ptr(7 downto 0));
      when 8 => dout <= "0000000" & std_logic_vector(buf_ptr(8 downto 8));
      when others => dout <= x"00";
    end case;
  end process;
end architecture;
