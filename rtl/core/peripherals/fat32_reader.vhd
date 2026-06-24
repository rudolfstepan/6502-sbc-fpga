-- FAT32 reader (Version 1: contiguous + verify).
--
-- Resolves the start LBA of the first *.D64 file in the root directory of a
-- FAT32 card, for the FPGA GoDrive boot menu.  It is a master on the raw
-- 512-byte SD read channel (the sd2 data-disk port).
--
-- Sequence (kicked off by `start`):
--   1. read MBR (LBA 0)            -> partition start LBA
--   2. read BPB (partition start)  -> sectors/cluster, reserved, num FATs,
--                                      sectors/FAT, root cluster
--   3. read root directory cluster -> first 8.3 entry whose extension is "D64";
--                                      capture first cluster + byte size
--   4. file start LBA = data_start + (first_cluster - 2) * spc
--   5. verify the file's FAT chain is strictly contiguous (cluster c -> c+1,
--      last is EOC); otherwise report UNSUPPORTED_IMAGE
--
-- Handles one file, a single root-directory cluster, no LFN, contiguous layout
-- only -- matching a freshly populated FAT card for Version 1.
--
-- DISK_RESULT codes: $00 OK, $06 UNSUPPORTED (fragmented), $0B DIRECTORY_ERROR
-- (no .d64 / unusable FS).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fat32_reader is
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    start    : in  std_logic;                         -- pulse: begin scan
    busy     : out std_logic;
    ready    : out std_logic;                         -- file found + verified
    error    : out std_logic;
    result   : out std_logic_vector(7 downto 0);

    file_start_lba : out std_logic_vector(31 downto 0);
    file_size      : out std_logic_vector(31 downto 0);

    -- Debug observability: the geometry the reader parsed from the BPB and the
    -- LBAs it derived.  Exposed so the 6502 can dump what the hardware actually
    -- computed (vs. what is on the card) when a mount fails.
    dbg_data_start : out std_logic_vector(31 downto 0);
    dbg_fat_start  : out std_logic_vector(31 downto 0);
    dbg_root_lba   : out std_logic_vector(31 downto 0);
    dbg_spf        : out std_logic_vector(31 downto 0);
    dbg_reserved   : out std_logic_vector(15 downto 0);

    -- Raw SD read channel
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic
  );
end entity;

architecture rtl of fat32_reader is
  constant RES_OK          : std_logic_vector(7 downto 0) := x"00";
  constant RES_UNSUPPORTED : std_logic_vector(7 downto 0) := x"06";
  constant RES_DIR_ERROR   : std_logic_vector(7 downto 0) := x"0B";

  constant FAT_EOC_MIN : unsigned(27 downto 0) := x"FFFFFF8";  -- >= -> end of chain

  type state_t is (
    S_IDLE,
    S_MBR_REQ,  S_MBR_RD,
    S_BPB_REQ,  S_BPB_RD,  S_BPB_CALC,
    S_ROOT_REQ, S_ROOT_RD,
    S_FAT_REQ,  S_FAT_RD,
    S_READY,    S_ERROR
  );
  signal state : state_t := S_IDLE;

  signal byte_idx : unsigned(8 downto 0) := (others => '0');  -- 0..511 in sector

  -- Parsed fields
  signal lba0_byte0 : std_logic_vector(7 downto 0) := (others => '0');  -- MBR vs BPB
  signal part_lba   : unsigned(31 downto 0) := (others => '0');
  signal reserved   : unsigned(15 downto 0) := (others => '0');
  signal num_fats   : unsigned(7 downto 0)  := (others => '0');
  signal spf        : unsigned(31 downto 0) := (others => '0');
  signal spc        : unsigned(7 downto 0)  := (others => '0');
  signal root_clus  : unsigned(31 downto 0) := (others => '0');

  signal data_start : unsigned(31 downto 0) := (others => '0');  -- abs LBA of cluster 2
  signal fat_start  : unsigned(31 downto 0) := (others => '0');  -- abs LBA of FAT 0

  -- Directory entry being assembled
  signal found_file    : std_logic := '0';   -- a .D64 entry has been captured
  signal bad_dir       : std_logic := '0';   -- 0x00 end-of-dir hit before match
  signal name0         : std_logic_vector(7 downto 0) := (others => '0');
  signal ext_b0        : std_logic_vector(7 downto 0) := (others => '0'); -- name[8]
  signal ext_b1        : std_logic_vector(7 downto 0) := (others => '0'); -- name[9]
  signal ext_b2        : std_logic_vector(7 downto 0) := (others => '0'); -- name[10]
  signal attr          : std_logic_vector(7 downto 0) := (others => '0'); -- name[11]
  signal ent_first_lo  : unsigned(15 downto 0) := (others => '0');        -- [26..27]
  signal ent_first_hi  : unsigned(15 downto 0) := (others => '0');        -- [20..21]
  signal ent_size      : unsigned(31 downto 0) := (others => '0');        -- [28..31]

  -- Root-directory scan across the whole first root cluster (spc sectors).
  signal root_base_lba : unsigned(31 downto 0) := (others => '0');  -- root cluster sector 0
  signal root_sec_idx  : unsigned(7 downto 0)  := (others => '0');  -- 0..spc-1
  signal dir_end       : std_logic := '0';   -- 0x00 entry seen -> stop scanning

  -- Resolved file
  signal file_first_clus : unsigned(31 downto 0) := (others => '0');
  signal file_lba        : unsigned(31 downto 0) := (others => '0');
  signal file_bytes      : unsigned(31 downto 0) := (others => '0');

  -- FAT contiguity verification
  signal cluster_count : unsigned(31 downto 0) := (others => '0');
  signal verify_idx    : unsigned(31 downto 0) := (others => '0');  -- 0..count-1
  signal cur_clus      : unsigned(31 downto 0) := (others => '0');  -- cluster being checked
  signal want_fat_sec  : unsigned(31 downto 0) := (others => '0');  -- abs FAT sector
  signal want_fat_off  : unsigned(8 downto 0)  := (others => '0');  -- byte in that sector
  signal fat_word      : unsigned(31 downto 0) := (others => '0');

  signal sd_read_r  : std_logic := '0';
  signal sd_addr_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal busy_r     : std_logic := '0';
  signal ready_r    : std_logic := '0';
  signal error_r    : std_logic := '0';
  signal result_r   : std_logic_vector(7 downto 0) := RES_OK;
begin
  busy           <= busy_r;
  ready          <= ready_r;
  error          <= error_r;
  result         <= result_r;
  file_start_lba <= std_logic_vector(file_lba);
  file_size      <= std_logic_vector(file_bytes);
  dbg_data_start <= std_logic_vector(data_start);
  dbg_fat_start  <= std_logic_vector(fat_start);
  dbg_root_lba   <= std_logic_vector(root_base_lba);
  dbg_spf        <= std_logic_vector(spf);
  dbg_reserved   <= std_logic_vector(reserved);
  sd_sec_read      <= sd_read_r;
  sd_sec_read_addr <= sd_addr_r;

  process(clk)
    variable b   : unsigned(7 downto 0);
    variable idx : unsigned(8 downto 0);
    -- offset of the FAT entry for cluster c: c*4 bytes from FAT start.
    -- sector = fat_start + (c*4)/512 ; byteoff = (c*4) mod 512.
    variable byte_addr : unsigned(33 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state    <= S_IDLE;
        byte_idx <= (others => '0');
        busy_r   <= '0';
        ready_r  <= '0';
        error_r  <= '0';
        result_r <= RES_OK;
        sd_read_r <= '0';
        sd_addr_r <= (others => '0');
      else
        sd_read_r <= '0';

        case state is
          when S_IDLE =>
            if start = '1' then
              busy_r  <= '1';
              ready_r <= '0';
              error_r <= '0';
              result_r <= RES_OK;
              state   <= S_MBR_REQ;
            end if;

          -- ── MBR ──────────────────────────────────────────────────────────
          when S_MBR_REQ =>
            sd_addr_r <= (others => '0');     -- LBA 0
            sd_read_r <= '1';
            byte_idx  <= (others => '0');
            part_lba  <= (others => '0');
            state     <= S_MBR_RD;

          when S_MBR_RD =>
            if sd_sec_read_data_valid = '1' then
              idx := byte_idx;
              b   := unsigned(sd_sec_read_data);
              -- byte 0 tells us if LBA 0 is itself a FAT boot sector (BPB) --
              -- "superfloppy" media start with a jump (EB..90 or E9..) -- versus
              -- an MBR with a partition table at offset 446.
              if idx = 0 then
                lba0_byte0 <= std_logic_vector(b);
              end if;
              -- candidate partition-0 start LBA at offset 454..457 (446+8), LE
              case to_integer(idx) is
                when 454 => part_lba(7 downto 0)   <= b;
                when 455 => part_lba(15 downto 8)  <= b;
                when 456 => part_lba(23 downto 16) <= b;
                when 457 => part_lba(31 downto 24) <= b;
                when others => null;
              end case;
              byte_idx <= byte_idx + 1;
            end if;
            if sd_sec_read_end = '1' then
              -- Superfloppy (no MBR): LBA 0 is the BPB, so the volume starts at
              -- LBA 0 -- ignore the "partition entry" (it is boot code).
              if lba0_byte0 = x"EB" or lba0_byte0 = x"E9" then
                part_lba <= (others => '0');
              end if;
              state <= S_BPB_REQ;
            end if;

          -- ── BPB ──────────────────────────────────────────────────────────
          when S_BPB_REQ =>
            sd_addr_r <= std_logic_vector(part_lba);
            sd_read_r <= '1';
            byte_idx  <= (others => '0');
            state     <= S_BPB_RD;

          when S_BPB_RD =>
            if sd_sec_read_data_valid = '1' then
              idx := byte_idx;
              b   := unsigned(sd_sec_read_data);
              case to_integer(idx) is
                when 13 => spc <= b;                       -- sectors per cluster
                when 14 => reserved(7 downto 0)  <= b;     -- reserved sectors
                when 15 => reserved(15 downto 8) <= b;
                when 16 => num_fats <= b;                  -- number of FATs
                when 36 => spf(7 downto 0)   <= b;         -- sectors per FAT (32)
                when 37 => spf(15 downto 8)  <= b;
                when 38 => spf(23 downto 16) <= b;
                when 39 => spf(31 downto 24) <= b;
                when 44 => root_clus(7 downto 0)   <= b;   -- root cluster
                when 45 => root_clus(15 downto 8)  <= b;
                when 46 => root_clus(23 downto 16) <= b;
                when 47 => root_clus(31 downto 24) <= b;
                when others => null;
              end case;
              byte_idx <= byte_idx + 1;
            end if;
            if sd_sec_read_end = '1' then
              -- fat_start = part_lba + reserved
              fat_start  <= part_lba + resize(reserved, 32);
              -- data_start = part_lba + reserved + num_fats*spf
              -- (resize the product back to 32 bits before the sum)
              data_start <= part_lba + resize(reserved, 32)
                          + resize(resize(num_fats, 40) * spf, 32);
              state <= S_BPB_CALC;
            end if;

          -- Derive root_base_lba from the now-registered data_start.  This extra
          -- cycle avoids using data_start in the same cycle it is assigned (a
          -- race that left root_base_lba = 0 on hardware though data_start was
          -- correct).
          when S_BPB_CALC =>
            root_base_lba <= data_start
                           + resize((root_clus - 2) * resize(spc, 32), 32);
            root_sec_idx  <= (others => '0');   -- scan root cluster from sector 0
            dir_end       <= '0';
            state         <= S_ROOT_REQ;

          -- ── Root directory (scan every sector of the first root cluster) ──
          when S_ROOT_REQ =>
            -- read root cluster sector root_base_lba + root_sec_idx
            sd_addr_r <= std_logic_vector(root_base_lba
                                          + resize(root_sec_idx, 32));
            sd_read_r  <= '1';
            byte_idx   <= (others => '0');
            found_file <= '0';
            bad_dir    <= '0';
            state      <= S_ROOT_RD;

          -- Stream the whole root sector to its end, latching the FIRST entry
          -- whose extension is "D64" into the per-entry field registers.  We
          -- decide only at sd_sec_read_end, so the SD stream is fully drained
          -- before the next read is issued.  found_file marks a captured match;
          -- bad_dir marks a 0x00 end-of-directory before any match.
          when S_ROOT_RD =>
            if sd_sec_read_data_valid = '1' then
              idx := byte_idx;
              b   := unsigned(sd_sec_read_data);
              -- Within each 32-byte entry, snapshot key bytes into "cur entry"
              -- holding registers; commit them when the entry's byte 31 arrives
              -- and it is the first D64 match we have seen.
              case to_integer(idx(4 downto 0)) is
                when 0  => name0  <= std_logic_vector(b);
                when 8  => ext_b0 <= std_logic_vector(b);
                when 9  => ext_b1 <= std_logic_vector(b);
                when 10 => ext_b2 <= std_logic_vector(b);
                when 11 => attr   <= std_logic_vector(b);
                when 20 => ent_first_hi(7 downto 0)  <= b;
                when 21 => ent_first_hi(15 downto 8) <= b;
                when 26 => ent_first_lo(7 downto 0)  <= b;
                when 27 => ent_first_lo(15 downto 8) <= b;
                when 28 => ent_size(7 downto 0)   <= b;
                when 29 => ent_size(15 downto 8)  <= b;
                when 30 => ent_size(23 downto 16) <= b;
                when 31 =>
                  ent_size(31 downto 24) <= b;
                  -- evaluate the just-completed entry (its byte 31 is `b`)
                  if found_file = '0' then
                    if name0 = x"00" then
                      bad_dir <= '1';       -- end of directory, no match yet
                    elsif name0 /= x"E5"
                          and (unsigned(attr) and x"0F") /= x"0F"
                          and ext_b0 = x"44" and ext_b1 = x"36" and ext_b2 = x"34"
                    then
                      found_file      <= '1';
                      file_first_clus <= ent_first_hi & ent_first_lo;
                      file_bytes      <= ent_size;
                    end if;
                  end if;
                when others => null;
              end case;
              byte_idx <= byte_idx + 1;
            end if;

            if sd_sec_read_end = '1' then
              if found_file = '1' then
                -- compute derived fields from the captured entry
                file_lba <= data_start
                          + resize((resize(file_first_clus, 32) - 2)
                                   * resize(spc, 32), 32);
                cluster_count <= resize(
                                   (file_bytes + (resize(spc,32) * 512) - 1)
                                   / (resize(spc,32) * 512), 32);
                cur_clus   <= file_first_clus;
                verify_idx <= (others => '0');
                state      <= S_FAT_REQ;
              elsif bad_dir = '1' then
                result_r <= RES_DIR_ERROR;   -- end-of-directory, no .d64 found
                state    <= S_ERROR;
              elsif root_sec_idx + 1 >= spc then
                result_r <= RES_DIR_ERROR;   -- scanned the whole root cluster
                state    <= S_ERROR;
              else
                root_sec_idx <= root_sec_idx + 1;  -- try the next root sector
                state        <= S_ROOT_REQ;
              end if;
            end if;

          -- ── FAT contiguity verification ──────────────────────────────────
          when S_FAT_REQ =>
            -- locate FAT entry for cur_clus: byte offset = cur_clus * 4.
            byte_addr := resize(cur_clus, 32) & "00";  -- *4, 34-bit result
            want_fat_sec <= fat_start + resize(byte_addr(33 downto 9), 32);  -- /512
            want_fat_off <= byte_addr(8 downto 0);                            -- mod 512
            sd_addr_r <= std_logic_vector(
                           fat_start + resize(byte_addr(33 downto 9), 32));
            sd_read_r <= '1';
            byte_idx  <= (others => '0');
            fat_word  <= (others => '0');
            state     <= S_FAT_RD;

          when S_FAT_RD =>
            if sd_sec_read_data_valid = '1' then
              idx := byte_idx;
              b   := unsigned(sd_sec_read_data);
              if idx = want_fat_off then
                fat_word(7 downto 0) <= b;
              elsif idx = want_fat_off + 1 then
                fat_word(15 downto 8) <= b;
              elsif idx = want_fat_off + 2 then
                fat_word(23 downto 16) <= b;
              elsif idx = want_fat_off + 3 then
                fat_word(31 downto 24) <= b;
              end if;
              byte_idx <= byte_idx + 1;
            end if;
            if sd_sec_read_end = '1' then
              -- evaluate the assembled entry (mask to 28 bits)
              if verify_idx = cluster_count - 1 then
                -- last cluster: must be EOC
                if fat_word(27 downto 0) >= FAT_EOC_MIN then
                  state <= S_READY;
                else
                  result_r <= RES_UNSUPPORTED;  -- chain continues past expected end
                  state    <= S_ERROR;
                end if;
              else
                -- intermediate cluster: must point to cur_clus + 1
                if fat_word(27 downto 0) = (cur_clus(27 downto 0) + 1) then
                  cur_clus   <= cur_clus + 1;
                  verify_idx <= verify_idx + 1;
                  state      <= S_FAT_REQ;
                else
                  result_r <= RES_UNSUPPORTED;  -- not contiguous
                  state    <= S_ERROR;
                end if;
              end if;
            end if;

          when S_READY =>
            busy_r   <= '0';
            ready_r  <= '1';
            error_r  <= '0';
            result_r <= RES_OK;
            state    <= S_IDLE;

          when S_ERROR =>
            busy_r  <= '0';
            ready_r <= '0';
            error_r <= '1';
            state   <= S_IDLE;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
