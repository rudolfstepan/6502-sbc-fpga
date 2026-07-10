library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_fat32_finder is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    start     : in  std_logic;
    sd_init_done : in std_logic;

    busy      : out std_logic;
    ready     : out std_logic;
    error     : out std_logic;
    file_start_lba : out std_logic_vector(31 downto 0);
    file_size      : out std_logic_vector(31 downto 0);

    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic
  );
end entity;

architecture rtl of sys16_fat32_finder is
  type state_t is (
    S_IDLE,
    S_MBR_REQ, S_MBR_READ,
    S_BPB_REQ, S_BPB_READ, S_BPB_CALC,
    S_ROOT_REQ, S_ROOT_READ,
    S_READY, S_ERROR
  );

  signal state          : state_t := S_IDLE;
  signal byte_index     : unsigned(8 downto 0) := (others => '0');
  signal sector_zero_b0 : std_logic_vector(7 downto 0) := (others => '0');
  signal part_lba       : unsigned(31 downto 0) := (others => '0');
  signal bps            : unsigned(15 downto 0) := (others => '0');
  signal spc            : unsigned(7 downto 0) := (others => '0');
  signal reserved       : unsigned(15 downto 0) := (others => '0');
  signal num_fats       : unsigned(7 downto 0) := (others => '0');
  signal sectors_per_fat: unsigned(31 downto 0) := (others => '0');
  signal root_cluster   : unsigned(31 downto 0) := (others => '0');
  signal data_start     : unsigned(31 downto 0) := (others => '0');
  signal root_lba       : unsigned(31 downto 0) := (others => '0');
  signal root_sector    : unsigned(7 downto 0) := (others => '0');

  signal entry_match    : std_logic := '0';
  signal entry_regular  : std_logic := '0';
  signal dir_end        : std_logic := '0';
  signal found_file     : std_logic := '0';
  signal first_cluster_hi : unsigned(15 downto 0) := (others => '0');
  signal first_cluster_lo : unsigned(15 downto 0) := (others => '0');
  signal entry_size       : unsigned(31 downto 0) := (others => '0');
  signal file_lba_r       : unsigned(31 downto 0) := (others => '0');
  signal file_size_r      : unsigned(31 downto 0) := (others => '0');

  signal sd_read_r      : std_logic := '0';
  signal sd_addr_r      : std_logic_vector(31 downto 0) := (others => '0');
  signal busy_r         : std_logic := '0';
  signal ready_r        : std_logic := '0';
  signal error_r        : std_logic := '0';

  function filename_byte(index : natural) return std_logic_vector is
  begin
    case index is
      when 0 => return x"53"; -- S
      when 1 => return x"59"; -- Y
      when 2 => return x"53"; -- S
      when 3 => return x"54"; -- T
      when 4 => return x"45"; -- E
      when 5 => return x"4D"; -- M
      when 6 => return x"31"; -- 1
      when 7 => return x"36"; -- 6
      when 8 => return x"42"; -- B
      when 9 => return x"49"; -- I
      when 10 => return x"4E"; -- N
      when others => return x"00";
    end case;
  end function;
begin
  busy  <= busy_r;
  ready <= ready_r;
  error <= error_r;
  file_start_lba <= std_logic_vector(file_lba_r);
  file_size      <= std_logic_vector(file_size_r);
  sd_sec_read      <= sd_read_r;
  sd_sec_read_addr <= sd_addr_r;

  process(clk)
    variable offset_v      : natural range 0 to 31;
    variable fats_size_v   : unsigned(31 downto 0);
    variable data_start_v  : unsigned(31 downto 0);
    variable cluster_v     : unsigned(31 downto 0);
    variable cluster_off_v : unsigned(39 downto 0);
    variable size_v        : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state            <= S_IDLE;
        byte_index       <= (others => '0');
        sector_zero_b0   <= (others => '0');
        part_lba         <= (others => '0');
        bps              <= (others => '0');
        spc              <= (others => '0');
        reserved         <= (others => '0');
        num_fats         <= (others => '0');
        sectors_per_fat  <= (others => '0');
        root_cluster     <= (others => '0');
        data_start       <= (others => '0');
        root_lba         <= (others => '0');
        root_sector      <= (others => '0');
        entry_match      <= '0';
        entry_regular    <= '0';
        dir_end          <= '0';
        found_file       <= '0';
        first_cluster_hi <= (others => '0');
        first_cluster_lo <= (others => '0');
        entry_size       <= (others => '0');
        file_lba_r       <= (others => '0');
        file_size_r      <= (others => '0');
        sd_read_r        <= '0';
        sd_addr_r        <= (others => '0');
        busy_r           <= '0';
        ready_r          <= '0';
        error_r          <= '0';
      else
        sd_read_r <= '0';

        case state is
          when S_IDLE =>
            busy_r  <= '0';
            ready_r <= '0';
            error_r <= '0';
            if start = '1' then
              if sd_init_done = '1' then
                busy_r <= '1';
                state  <= S_MBR_REQ;
              else
                error_r <= '1';
                state   <= S_ERROR;
              end if;
            end if;

          when S_MBR_REQ =>
            sd_addr_r  <= (others => '0');
            sd_read_r  <= '1';
            byte_index <= (others => '0');
            part_lba   <= (others => '0');
            state      <= S_MBR_READ;

          when S_MBR_READ =>
            if sd_sec_read_data_valid = '1' then
              case to_integer(byte_index) is
                when 0   => sector_zero_b0 <= sd_sec_read_data;
                when 454 => part_lba(7 downto 0)   <= unsigned(sd_sec_read_data);
                when 455 => part_lba(15 downto 8)  <= unsigned(sd_sec_read_data);
                when 456 => part_lba(23 downto 16) <= unsigned(sd_sec_read_data);
                when 457 => part_lba(31 downto 24) <= unsigned(sd_sec_read_data);
                when others => null;
              end case;
              byte_index <= byte_index + 1;
            end if;
            if sd_sec_read_end = '1' then
              if sector_zero_b0 = x"EB" or sector_zero_b0 = x"E9" then
                part_lba <= (others => '0');
              end if;
              state <= S_BPB_REQ;
            end if;

          when S_BPB_REQ =>
            sd_addr_r      <= std_logic_vector(part_lba);
            sd_read_r      <= '1';
            byte_index     <= (others => '0');
            bps            <= (others => '0');
            spc            <= (others => '0');
            reserved       <= (others => '0');
            num_fats       <= (others => '0');
            sectors_per_fat<= (others => '0');
            root_cluster   <= (others => '0');
            state          <= S_BPB_READ;

          when S_BPB_READ =>
            if sd_sec_read_data_valid = '1' then
              case to_integer(byte_index) is
                when 11 => bps(7 downto 0) <= unsigned(sd_sec_read_data);
                when 12 => bps(15 downto 8) <= unsigned(sd_sec_read_data);
                when 13 => spc <= unsigned(sd_sec_read_data);
                when 14 => reserved(7 downto 0) <= unsigned(sd_sec_read_data);
                when 15 => reserved(15 downto 8) <= unsigned(sd_sec_read_data);
                when 16 => num_fats <= unsigned(sd_sec_read_data);
                when 36 => sectors_per_fat(7 downto 0) <= unsigned(sd_sec_read_data);
                when 37 => sectors_per_fat(15 downto 8) <= unsigned(sd_sec_read_data);
                when 38 => sectors_per_fat(23 downto 16) <= unsigned(sd_sec_read_data);
                when 39 => sectors_per_fat(31 downto 24) <= unsigned(sd_sec_read_data);
                when 44 => root_cluster(7 downto 0) <= unsigned(sd_sec_read_data);
                when 45 => root_cluster(15 downto 8) <= unsigned(sd_sec_read_data);
                when 46 => root_cluster(23 downto 16) <= unsigned(sd_sec_read_data);
                when 47 => root_cluster(31 downto 24) <= unsigned(sd_sec_read_data);
                when others => null;
              end case;
              byte_index <= byte_index + 1;
            end if;
            if sd_sec_read_end = '1' then
              state <= S_BPB_CALC;
            end if;

          when S_BPB_CALC =>
            if bps /= to_unsigned(512, 16) or spc = 0 or reserved = 0 or
               (num_fats /= 1 and num_fats /= 2) or sectors_per_fat = 0 or
               root_cluster < 2 then
              error_r <= '1';
              state   <= S_ERROR;
            else
              if num_fats = 1 then
                fats_size_v := sectors_per_fat;
              else
                fats_size_v := shift_left(sectors_per_fat, 1);
              end if;
              data_start_v := part_lba + resize(reserved, 32) + fats_size_v;
              cluster_off_v := (root_cluster - 2) * spc;
              data_start <= data_start_v;
              root_lba   <= data_start_v + resize(cluster_off_v, 32);
              root_sector <= (others => '0');
              dir_end     <= '0';
              found_file  <= '0';
              state       <= S_ROOT_REQ;
            end if;

          when S_ROOT_REQ =>
            sd_addr_r      <= std_logic_vector(root_lba + resize(root_sector, 32));
            sd_read_r      <= '1';
            byte_index     <= (others => '0');
            entry_match    <= '0';
            entry_regular  <= '0';
            state          <= S_ROOT_READ;

          when S_ROOT_READ =>
            if sd_sec_read_data_valid = '1' then
              offset_v := to_integer(byte_index(4 downto 0));
              if offset_v = 0 then
                entry_regular <= '0';
                if sd_sec_read_data = x"00" then
                  dir_end     <= '1';
                  entry_match <= '0';
                elsif sd_sec_read_data = filename_byte(0) then
                  entry_match <= '1';
                else
                  entry_match <= '0';
                end if;
              elsif offset_v <= 10 then
                if sd_sec_read_data /= filename_byte(offset_v) then
                  entry_match <= '0';
                end if;
              elsif offset_v = 11 then
                if sd_sec_read_data(4) = '0' and sd_sec_read_data(3) = '0' then
                  entry_regular <= '1';
                else
                  entry_regular <= '0';
                end if;
              end if;

              case offset_v is
                when 20 => first_cluster_hi(7 downto 0) <= unsigned(sd_sec_read_data);
                when 21 => first_cluster_hi(15 downto 8) <= unsigned(sd_sec_read_data);
                when 26 => first_cluster_lo(7 downto 0) <= unsigned(sd_sec_read_data);
                when 27 => first_cluster_lo(15 downto 8) <= unsigned(sd_sec_read_data);
                when 28 => entry_size(7 downto 0) <= unsigned(sd_sec_read_data);
                when 29 => entry_size(15 downto 8) <= unsigned(sd_sec_read_data);
                when 30 => entry_size(23 downto 16) <= unsigned(sd_sec_read_data);
                when 31 =>
                  size_v := unsigned(sd_sec_read_data) & entry_size(23 downto 0);
                  cluster_v := first_cluster_hi & first_cluster_lo;
                  if entry_match = '1' and entry_regular = '1' and
                     size_v /= 0 and cluster_v >= 2 then
                    cluster_off_v := (cluster_v - 2) * spc;
                    file_lba_r  <= data_start + resize(cluster_off_v, 32);
                    file_size_r <= size_v;
                    found_file  <= '1';
                  end if;
                when others => null;
              end case;
              byte_index <= byte_index + 1;
            end if;

            if sd_sec_read_end = '1' then
              if found_file = '1' then
                busy_r  <= '0';
                ready_r <= '1';
                state   <= S_READY;
              elsif dir_end = '1' or root_sector + 1 >= spc then
                busy_r  <= '0';
                error_r <= '1';
                state   <= S_ERROR;
              else
                root_sector <= root_sector + 1;
                state       <= S_ROOT_REQ;
              end if;
            end if;

          when S_READY =>
            busy_r  <= '0';
            ready_r <= '1';

          when S_ERROR =>
            busy_r  <= '0';
            error_r <= '1';
        end case;
      end if;
    end if;
  end process;
end architecture;
