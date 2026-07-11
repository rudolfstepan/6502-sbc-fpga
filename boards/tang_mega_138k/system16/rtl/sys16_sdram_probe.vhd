library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_sdram_probe is
  port(clk,reset_n,start:in std_logic; mem_req:out std_logic;
       mem_addr:out std_logic_vector(23 downto 1);mem_rdata:in std_logic_vector(15 downto 0);
       mem_ready:in std_logic;done,failed:out std_logic);
end entity;
architecture rtl of sys16_sdram_probe is
  type st_t is(IDLE,READ0,DROP0,READ1,DROP1,READ2,DROP2,READ3,DROP3,PASS,FAIL);
  signal st:st_t:=IDLE;
begin
  mem_req<='1' when st=READ0 or st=READ1 or st=READ2 or st=READ3 else '0';
  mem_addr<=std_logic_vector(to_unsigned(16#001000#/2,23)) when st=READ0 else
            std_logic_vector(to_unsigned(16#001002#/2,23)) when st=READ1 else
            std_logic_vector(to_unsigned(16#00210C#/2,23)) when st=READ2 else
            std_logic_vector(to_unsigned(16#00210E#/2,23));
  done<='1' when st=PASS or st=FAIL else '0';failed<='1' when st=FAIL else '0';
  process(clk)begin if rising_edge(clk)then if reset_n='0'then st<=IDLE;else case st is
    when IDLE=>if start='1'then st<=READ0;end if;
    when READ0=>if mem_ready='1'then if mem_rdata=x"0337"then st<=DROP0;else st<=FAIL;end if;end if;
    when DROP0=>if mem_ready='0'then st<=READ1;end if;
    when READ1=>if mem_ready='1'then if mem_rdata=x"F000"then st<=DROP1;else st<=FAIL;end if;end if;
    when DROP1=>if mem_ready='0'then st<=READ2;end if;
    -- Patched OpenSBI 0x210c contains jal 0x13ae0 (little-endian
    -- halfwords 0x10ef, 0x1d51). This catches corruption beyond the shim.
    when READ2=>if mem_ready='1'then if mem_rdata=x"10EF"then st<=DROP2;else st<=FAIL;end if;end if;
    when DROP2=>if mem_ready='0'then st<=READ3;end if;
    when READ3=>if mem_ready='1'then if mem_rdata=x"1D51"then st<=DROP3;else st<=FAIL;end if;end if;
    when DROP3=>if mem_ready='0'then st<=PASS;end if;
    when others=>null;end case;end if;end if;end process;
end architecture;
