-- D64 subsystem: the 6502-facing D64 GoDrive controller.
--
-- Wraps d64_drive (read-only D64 sector engine) and a raw sector read window
-- used by the 6502 kernel to parse a FAT16 SD card in software.  The kernel
-- computes a .d64 start LBA, then mounts it with CMD_MOUNT_LBA.
--
-- Register interface (offsets from the module's base; the bus decoder selects
-- the module and passes a small offset):
--   +0  STATUS   R  bit0 BUSY, bit1 DONE, bit2 ERROR, bit3 MOUNTED,
--                    bit4 WRITE_PROTECT, bit6 IMAGE_READY (LBA mounted)
--   +1  COMMAND  W  $00 NOP, $01 READ_SECTOR, $03 MOUNT, $04 UNMOUNT,
--                    $0A RESET
--   +2  TRACK    RW input track for READ_SECTOR (1-based)
--   +3  SECTOR   RW input sector for READ_SECTOR (0-based)
--   +4  RESULT   R  DISK_RESULT code of the last command
--   +5  DATA     RW sector-buffer data port; reading auto-increments the pointer
--   +6  PTR_LO   RW buffer pointer low 8 bits (0..255)
--   +7  PTR_HI   R  reserved (buffer is 256 bytes, high byte always 0)
--
-- Legacy CMD_MOUNT is intentionally not implemented here: removing the old
-- FAT32 hardware scanner saves enough logic for the Tang 20K build.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity d64_subsystem is
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    -- 6502 register bus (offset within the module)
    cs       : in  std_logic;
    we       : in  std_logic;
    offset   : in  std_logic_vector(3 downto 0);  -- register offset within window
    din      : in  std_logic_vector(7 downto 0);
    dout     : out std_logic_vector(7 downto 0);

    -- Raw sd2 read channel (to sd_card_top)
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic
  );
end entity;

architecture rtl of d64_subsystem is
  -- Commands
  constant CMD_NOP    : std_logic_vector(7 downto 0) := x"00";
  constant CMD_READ   : std_logic_vector(7 downto 0) := x"01";
  constant CMD_MOUNT  : std_logic_vector(7 downto 0) := x"03";
  constant CMD_UNMOUNT: std_logic_vector(7 downto 0) := x"04";
  constant CMD_RAW_READ : std_logic_vector(7 downto 0) := x"05";  -- debug: read raw LBA
  constant CMD_MOUNT_LBA: std_logic_vector(7 downto 0) := x"07";  -- mount the LBA in $882C-$882F
  constant CMD_RESET  : std_logic_vector(7 downto 0) := x"0A";

  constant RES_OK         : std_logic_vector(7 downto 0) := x"00";
  constant RES_INVALID_CMD: std_logic_vector(7 downto 0) := x"0A";

  -- Which engine currently owns the SD read channel.
  type owner_t is (OWN_NONE, OWN_DRIVE, OWN_RAW);
  signal owner : owner_t := OWN_NONE;

  -- Raw-LBA debug read: captures the lower 256 bytes of any card block into a
  -- dedicated buffer, exposed through the DATA port when raw_active is set.
  type rawbuf_t is array (0 to 255) of std_logic_vector(7 downto 0);
  signal raw_buf      : rawbuf_t := (others => (others => '0'));
  signal raw_lba      : std_logic_vector(31 downto 0) := (others => '0');
  signal raw_sd_read  : std_logic := '0';
  signal raw_active   : std_logic := '0';     -- DATA port reads raw_buf
  signal raw_byte_cnt : unsigned(9 downto 0) := (others => '0');
  signal raw_wr_idx   : unsigned(7 downto 0) := (others => '0');
  signal raw_buf_data : std_logic_vector(7 downto 0) := (others => '0');
  type raw_state_t is (RAW_IDLE, RAW_REQ, RAW_STREAM, RAW_DONE);
  signal raw_state    : raw_state_t := RAW_IDLE;

  -- CPU-visible state
  signal reg_track  : std_logic_vector(7 downto 0) := (others => '0');
  signal reg_sector : std_logic_vector(7 downto 0) := (others => '0');
  signal reg_result : std_logic_vector(7 downto 0) := RES_OK;
  signal busy_r     : std_logic := '0';
  signal done_r     : std_logic := '0';
  signal error_r    : std_logic := '0';
  signal img_ready  : std_logic := '0';     -- an image LBA was mounted
  signal buf_ptr    : unsigned(7 downto 0) := (others => '0');

  -- d64_drive interface
  signal drv_mount    : std_logic := '0';
  signal drv_unmount  : std_logic := '0';
  signal drv_rd_req   : std_logic := '0';
  signal drv_busy     : std_logic;
  signal drv_done     : std_logic;
  signal drv_error    : std_logic;
  signal drv_mounted  : std_logic;
  signal drv_wp       : std_logic;
  signal drv_result   : std_logic_vector(7 downto 0);
  signal drv_buf_data : std_logic_vector(7 downto 0);
  signal drv_sd_read  : std_logic;
  signal drv_sd_addr  : std_logic_vector(31 downto 0);

  -- Pending MOUNT_LBA: the 6502 supplied a raw LBA to mount directly.  The
  -- actual drv_mount pulse is deferred to the main FSM so it
  -- is issued cleanly when the drive engine is idle (a same-cycle pulse from the
  -- command decode could be missed on hardware if the drive had just finished a
  -- read and was not yet back in its idle state -- a race GHDL does not show).
  signal mount_lba_pending : std_logic := '0';

  -- "Engine has acknowledged the request": set when a command is issued,
  -- cleared once the owned engine's busy is observed high.  Completion
  -- (done/error) is only honoured after the engine has started, so a stale
  -- done/error from a previous command is never mistaken for this one.
  signal eng_started : std_logic := '0';

  -- Registered previous state of a DATA-port access, for falling-edge detect.
  signal data_acc_prev : std_logic := '0';

begin
  drv_i : entity work.d64_drive
    port map (
      clk            => clk,
      reset_n        => reset_n,
      mount          => drv_mount,
      unmount        => drv_unmount,
      file_start_lba => raw_lba,
      write_protect_in => '1',
      rd_req         => drv_rd_req,
      rd_track       => reg_track,
      rd_sector      => reg_sector,
      busy           => drv_busy,
      done           => drv_done,
      error          => drv_error,
      mounted        => drv_mounted,
      write_protect  => drv_wp,
      result         => drv_result,
      buf_addr       => std_logic_vector(buf_ptr),
      buf_data       => drv_buf_data,
      sd_sec_read            => drv_sd_read,
      sd_sec_read_addr       => drv_sd_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_data_valid,
      sd_sec_read_end        => sd_sec_read_end
    );

  -- Arbiter: the active owner drives the shared SD read request lines.  Read
  -- *data* fans out to all engines (only the active one consumes it).
  sd_sec_read <= drv_sd_read when owner = OWN_DRIVE else
                 raw_sd_read when owner = OWN_RAW else
                 '0';
  sd_sec_read_addr <= raw_lba     when owner = OWN_RAW else
                      drv_sd_addr;

  -- Synchronous raw-buffer read port (1-cycle latency), mirrors the drive port.
  process(clk)
  begin
    if rising_edge(clk) then
      raw_buf_data <= raw_buf(to_integer(buf_ptr));
    end if;
  end process;

  -- Status read mux.  In raw debug mode the DATA port returns the raw buffer.
  -- Offsets 8..11 read back the selected debug word (LSB..MSB).
  process(offset, busy_r, done_r, error_r, drv_mounted, drv_wp, img_ready,
          reg_track, reg_sector, reg_result, drv_buf_data, raw_buf_data,
          raw_active, buf_ptr, raw_lba)
  begin
    case to_integer(unsigned(offset)) is
      when 0 => dout <= '0' & img_ready & '0' & drv_wp & drv_mounted
                          & error_r & done_r & busy_r;
      when 2 => dout <= reg_track;
      when 3 => dout <= reg_sector;
      when 4 => dout <= reg_result;
      when 5 =>
        if raw_active = '1' then
          dout <= raw_buf_data;
        else
          dout <= drv_buf_data;
        end if;
      when 6  => dout <= std_logic_vector(buf_ptr);
      when 8  => dout <= raw_lba(7 downto 0);
      when 9  => dout <= raw_lba(15 downto 8);
      when 10 => dout <= raw_lba(23 downto 16);
      when 11 => dout <= raw_lba(31 downto 24);
      when others => dout <= x"00";
    end case;
  end process;

  -- Command + control FSM
  process(clk)
    variable data_acc : std_logic;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        owner        <= OWN_NONE;
        reg_track    <= (others => '0');
        reg_sector   <= (others => '0');
        reg_result   <= RES_OK;
        busy_r       <= '0';
        done_r       <= '0';
        error_r      <= '0';
        img_ready    <= '0';
        buf_ptr      <= (others => '0');
        drv_mount    <= '0';
        drv_unmount  <= '0';
        drv_rd_req   <= '0';
        mount_lba_pending <= '0';
        raw_lba      <= (others => '0');
        raw_sd_read  <= '0';
        raw_active   <= '0';
        raw_state    <= RAW_IDLE;
        raw_byte_cnt <= (others => '0');
        raw_wr_idx   <= (others => '0');
        data_acc_prev <= '0';
      else
        -- default pulses low
        drv_mount   <= '0';
        drv_unmount <= '0';
        drv_rd_req  <= '0';
        raw_sd_read <= '0';

        -- ── CPU register writes ────────────────────────────────────────────
        if cs = '1' and we = '1' then
          case to_integer(unsigned(offset)) is
            when 1 =>  -- COMMAND
              if busy_r = '0' then
                done_r  <= '0';
                error_r <= '0';
                if din = CMD_READ then
                  busy_r      <= '1';
                  owner       <= OWN_DRIVE;
                  drv_rd_req  <= '1';
                  eng_started <= '0';
                  raw_active  <= '0';   -- DATA port now follows the drive buffer
                elsif din = CMD_MOUNT then
                  reg_result <= RES_INVALID_CMD;
                  error_r    <= '1';
                  done_r     <= '1';
                elsif din = CMD_RAW_READ then
                  busy_r     <= '1';
                  owner      <= OWN_RAW;
                  raw_active <= '1';
                  raw_state  <= RAW_REQ;
                elsif din = CMD_MOUNT_LBA then
                  -- Mount the LBA the 6502 placed in $882C-$882F.  Defer the drv_mount
                  -- pulse to the main FSM (mount_lba_pending), so it is issued
                  -- when the drive engine is guaranteed idle.
                  mount_lba_pending <= '1';
                  busy_r            <= '1';
                  owner             <= OWN_NONE;  -- not a drive/raw op
                  raw_active        <= '0';       -- DATA port follows drive buf
                  eng_started       <= '0';
                elsif din = CMD_UNMOUNT then
                  drv_unmount <= '1';
                  reg_result  <= RES_OK;
                  done_r      <= '1';
                elsif din = CMD_RESET then
                  owner      <= OWN_NONE;
                  busy_r     <= '0';
                  reg_result <= RES_OK;
                elsif din = CMD_NOP then
                  null;
                else
                  reg_result <= RES_INVALID_CMD;
                  error_r    <= '1';
                end if;
              end if;
            when 2 => reg_track  <= din;
            when 3 => reg_sector <= din;
            when 6 => buf_ptr    <= unsigned(din);
            when 7 => null;
            -- raw debug LBA (little-endian) at offsets 8..11
            when 8  => raw_lba(7 downto 0)   <= din;
            when 9  => raw_lba(15 downto 8)  <= din;
            when 10 => raw_lba(23 downto 16) <= din;
            when 11 => raw_lba(31 downto 24) <= din;
            when others => null;
          end case;
        end if;

        -- ── Auto-increment buffer pointer on a DATA read access ─────────────
        -- A CPU read holds cs high for a whole CPU cycle, which is *two* system
        -- clocks here (cpu_enable toggles every clk).  Incrementing on the level
        -- would advance buf_ptr twice per read and skip every other byte, so the
        -- pointer is post-incremented once on the FALLING edge of the access --
        -- after the byte has been presented.  (Same scheme as sd_disk_ctrl.)
        if cs = '1' and we = '0' and to_integer(unsigned(offset)) = 5 then
          data_acc := '1';
        else
          data_acc := '0';
        end if;
        data_acc_prev <= data_acc;
        if data_acc_prev = '1' and data_acc = '0' then
          buf_ptr <= buf_ptr + 1;
        end if;

        -- Observe the owned engine starting (busy high) before honouring its
        -- terminal status.
        if owner = OWN_DRIVE and drv_busy = '1' then
          eng_started <= '1';
        end if;

        -- ── MOUNT_LBA: pulse drive mount once the engine is idle ───────────
        -- Wait until the drive is not busy, then pulse drv_mount for exactly one
        -- cycle so the engine latches raw_lba, and complete the command.
        if mount_lba_pending = '1' and drv_busy = '0' then
          mount_lba_pending <= '0';
          drv_mount         <= '1';   -- latch raw_lba into the drive (S_IDLE)
          img_ready         <= '1';
          busy_r            <= '0';
          done_r            <= '1';
          error_r           <= '0';
          reg_result        <= RES_OK;
        end if;

        -- ── READ completion: drive done/error ──────────────────────────────
        if owner = OWN_DRIVE and eng_started = '1' then
          if drv_error = '1' then
            owner      <= OWN_NONE;
            busy_r     <= '0';
            error_r    <= '1';
            reg_result <= drv_result;
          elsif drv_done = '1' then
            owner      <= OWN_NONE;
            busy_r     <= '0';
            done_r     <= '1';
            error_r    <= '0';
            reg_result <= drv_result;
            buf_ptr    <= (others => '0');  -- reset pointer for fresh sector
          end if;
        end if;

        -- ── Raw debug read FSM: capture lower 256 bytes of raw_lba ──────────
        case raw_state is
          when RAW_IDLE =>
            null;
          when RAW_REQ =>
            raw_sd_read  <= '1';      -- one-cycle strobe with raw_lba
            raw_byte_cnt <= (others => '0');
            raw_wr_idx   <= (others => '0');
            raw_state    <= RAW_STREAM;
          when RAW_STREAM =>
            -- Capture the selected 256-byte half of the 512-byte block.
            -- reg_track(0) = 0 -> lower half (bytes 0..255), 1 -> upper (256..511).
            if sd_sec_read_data_valid = '1' then
              if reg_track(0) = '0' then
                if raw_byte_cnt < 256 then
                  raw_buf(to_integer(raw_wr_idx)) <= sd_sec_read_data;
                  raw_wr_idx <= raw_wr_idx + 1;
                end if;
              else
                if raw_byte_cnt >= 256 then
                  raw_buf(to_integer(raw_wr_idx)) <= sd_sec_read_data;
                  raw_wr_idx <= raw_wr_idx + 1;
                end if;
              end if;
              raw_byte_cnt <= raw_byte_cnt + 1;
            end if;
            if sd_sec_read_end = '1' then
              raw_state <= RAW_DONE;
            end if;
          when RAW_DONE =>
            owner      <= OWN_NONE;
            busy_r     <= '0';
            done_r     <= '1';
            error_r    <= '0';
            reg_result <= RES_OK;
            buf_ptr    <= (others => '0');
            raw_state  <= RAW_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
