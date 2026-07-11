library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_sd_bootloader is
  generic (WATCHDOG_CYCLES : positive := 500_000_000; LITTLE_ENDIAN : boolean := false);
  port (
    clk,reset_n,sd_init_done:in std_logic; sd_sec_read:out std_logic;
    sd_sec_read_addr:out std_logic_vector(31 downto 0); sd_sec_read_data:in std_logic_vector(7 downto 0);
    sd_sec_read_data_valid,sd_sec_read_end:in std_logic;
    mem_req:out std_logic; mem_addr:out std_logic_vector(23 downto 1); mem_be:out std_logic_vector(1 downto 0);
    mem_wdata:out std_logic_vector(15 downto 0); mem_ready:in std_logic;
    boot_done,boot_error:out std_logic; boot_entry:out std_logic_vector(23 downto 0); debug:out std_logic_vector(3 downto 0)
  );
end entity;
architecture rtl of sys16_sd_bootloader is
  type st_t is (WAIT_SD,HEADER_REQ,HEADER,HEADER_END,PAYLOAD_REQ,PAYLOAD,BUS_WAIT,BUS_DROP,DONE,ERROR);
  signal st:st_t:=WAIT_SD; signal idx:natural range 0 to 511:=0; signal watchdog:natural range 0 to WATCHDOG_CYCLES:=0;
  signal magic:std_logic_vector(63 downto 0):=(others=>'0'); signal load_addr,entry:unsigned(23 downto 0):=(others=>'0');
  signal length,expected_sum,sum:unsigned(31 downto 0):=(others=>'0'); signal count:unsigned(31 downto 0):=(others=>'0');
  signal first_byte:std_logic_vector(7 downto 0):=(others=>'0'); signal have_first:std_logic:='0';
  signal req_r:std_logic:='0'; signal word_r:std_logic_vector(15 downto 0):=(others=>'0'); signal word_addr:unsigned(23 downto 0):=(others=>'0');
  signal error_reason:std_logic_vector(3 downto 0):=(others=>'0');
begin
  sd_sec_read<='1' when st=HEADER_REQ or st=PAYLOAD_REQ else '0';
  sd_sec_read_addr<=x"00000000" when st=HEADER_REQ else std_logic_vector(to_unsigned(1,32)+(count srl 9));
  mem_req<=req_r; mem_addr<=std_logic_vector(word_addr(23 downto 1)); mem_be<="11"; mem_wdata<=word_r;
  boot_done<='1' when st=DONE else '0'; boot_error<='1' when st=ERROR else '0'; boot_entry<=std_logic_vector(entry);
  debug<=error_reason when st=ERROR else std_logic_vector(to_unsigned(st_t'pos(st),4));
  process(clk) variable b:unsigned(7 downto 0); begin if rising_edge(clk) then
    if reset_n='0' then st<=WAIT_SD;idx<=0;watchdog<=0;req_r<='0';error_reason<=(others=>'0');magic<=(others=>'0');load_addr<=(others=>'0');entry<=(others=>'0');length<=(others=>'0');expected_sum<=(others=>'0');sum<=(others=>'0');count<=(others=>'0');have_first<='0';
    else
      -- Stall watchdog, not a total boot-time limit. A multi-megabyte Linux
      -- image legitimately takes several seconds over SPI and the 16-bit
      -- SDRAM bridge. Any SD byte or completed memory write proves progress.
      if st/=DONE and st/=ERROR then
        if sd_sec_read_data_valid='1' or sd_sec_read_end='1' or mem_ready='1' then
          watchdog<=0;
        elsif watchdog=WATCHDOG_CYCLES then
          error_reason<=x"1"; st<=ERROR; -- stalled SD or SDRAM transaction
        else
          watchdog<=watchdog+1;
        end if;
      end if;
      case st is
        when WAIT_SD=>if sd_init_done='1' then st<=HEADER_REQ;end if;
        when HEADER_REQ=>idx<=0;st<=HEADER;
        when HEADER=>if sd_sec_read_data_valid='1' then
          if idx<8 then magic(63-idx*8 downto 56-idx*8)<=sd_sec_read_data;
          elsif idx>=8 and idx<=10 then load_addr<=load_addr(15 downto 0)&unsigned(sd_sec_read_data);
          elsif idx>=11 and idx<=13 then entry<=entry(15 downto 0)&unsigned(sd_sec_read_data);
          elsif idx>=14 and idx<=17 then length<=length(23 downto 0)&unsigned(sd_sec_read_data);
          elsif idx>=18 and idx<=21 then expected_sum<=expected_sum(23 downto 0)&unsigned(sd_sec_read_data);end if;
          if idx<511 then idx<=idx+1;end if; end if; if sd_sec_read_end='1' then st<=HEADER_END;end if;
        when HEADER_END=>if magic=x"5359533136534431" and length/=0 and load_addr>=x"001000" and load_addr+resize(length,24)<=x"F00000" then word_addr<=load_addr;count<=(others=>'0');sum<=(others=>'0');st<=PAYLOAD_REQ;else error_reason<=x"2";st<=ERROR;end if;
        when PAYLOAD_REQ=>st<=PAYLOAD;
        when PAYLOAD=>if sd_sec_read_data_valid='1' and count<length then b:=unsigned(sd_sec_read_data);sum<=sum+resize(b,32);count<=count+1;
          if have_first='0' then first_byte<=sd_sec_read_data;have_first<='1';
          else if LITTLE_ENDIAN then word_r<=sd_sec_read_data & first_byte;else word_r<=first_byte & sd_sec_read_data;end if;have_first<='0';req_r<='1';st<=BUS_WAIT;end if;
        elsif sd_sec_read_end='1' and count<length then st<=PAYLOAD_REQ;end if;
        when BUS_WAIT=>if mem_ready='1' then req_r<='0';st<=BUS_DROP;end if;
        when BUS_DROP=>if mem_ready='0' then word_addr<=word_addr+2;if count=length then if sum=expected_sum then st<=DONE;else error_reason<=x"3";st<=ERROR;end if;elsif count(8 downto 0)=0 then st<=PAYLOAD_REQ;else st<=PAYLOAD;end if;end if;
        when others=>null;
      end case;
    end if; end if; end process;
end architecture;
