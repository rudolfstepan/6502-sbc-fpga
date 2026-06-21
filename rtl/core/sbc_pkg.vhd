-- SBC Package: Defines common types, constants, and utilities for the 6502 Single Board Computer
-- This package centralizes the memory map definitions and device selection logic
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sbc_pkg is
  -- Standard address and data bus widths for 6502 architecture
  subtype addr_t is std_logic_vector(15 downto 0);  -- 16-bit address bus
  subtype data_t is std_logic_vector(7 downto 0);   -- 8-bit data bus

  -- VIC Memory Arrays
  type text_ram_t is array (0 to 2047) of data_t;   -- 2KB text display buffer
  type color_ram_t is array (0 to 255) of data_t;   -- Color buffer for text mode

  -- Memory map constants: Define address ranges for all peripherals and memory regions
  -- The 6502 has a 64KB address space (0x0000 - 0xFFFF)

  -- SRAM: Primary RAM for program and data storage (32KB)
  constant ADDR_SRAM_BASE       : unsigned(15 downto 0) := x"0000";
  constant ADDR_SRAM_LAST       : unsigned(15 downto 0) := x"7FFF";

  -- VIC Chip: Video display controller text memory (2KB text buffer)
  constant ADDR_VIC_TEXT_BASE   : unsigned(15 downto 0) := x"8000";
  constant ADDR_VIC_TEXT_LAST   : unsigned(15 downto 0) := x"87FF";

  -- VIA: Versatile Interface Adapter for parallel I/O (16 bytes)
  constant ADDR_VIA_BASE        : unsigned(15 downto 0) := x"8800";
  constant ADDR_VIA_LAST        : unsigned(15 downto 0) := x"880F";

  -- UART: Serial communication interface (4 bytes)
  constant ADDR_UART_BASE       : unsigned(15 downto 0) := x"8810";
  constant ADDR_UART_LAST       : unsigned(15 downto 0) := x"8813";

  -- USB HID host: keyboard register file (4 bytes)
  constant ADDR_USB_BASE        : unsigned(15 downto 0) := x"8820";
  constant ADDR_USB_LAST        : unsigned(15 downto 0) := x"8823";

  -- Disk controller: Floppy disk interface (12 bytes, after USB)
  constant ADDR_DISK_BASE       : unsigned(15 downto 0) := x"8824";
  constant ADDR_DISK_LAST       : unsigned(15 downto 0) := x"882F";

  -- Sound synthesizer channel 0 (10 bytes)
  constant ADDR_SOUND0_BASE     : unsigned(15 downto 0) := x"8830";
  constant ADDR_SOUND0_LAST     : unsigned(15 downto 0) := x"883D";

  -- VIC Blit engine: Hardware graphics blitter (16 bytes)
  constant ADDR_VIC_BLIT_BASE   : unsigned(15 downto 0) := x"8840";
  constant ADDR_VIC_BLIT_LAST   : unsigned(15 downto 0) := x"884F";

  -- VIC Sprite controller: Manages sprite graphics (64 bytes for 8 sprites)
  constant ADDR_VIC_SPR_BASE    : unsigned(15 downto 0) := x"8850";
  constant ADDR_VIC_SPR_LAST    : unsigned(15 downto 0) := x"888F";

  -- Sound synthesizer channel 1 (10 bytes)
  constant ADDR_SOUND1_BASE     : unsigned(15 downto 0) := x"8890";
  constant ADDR_SOUND1_LAST     : unsigned(15 downto 0) := x"8899";

  -- Sound synthesizer channel 2 (10 bytes)
  constant ADDR_SOUND2_BASE     : unsigned(15 downto 0) := x"889A";
  constant ADDR_SOUND2_LAST     : unsigned(15 downto 0) := x"88A3";

  -- Sound synthesizer channel 3 (10 bytes)
  constant ADDR_SOUND3_BASE     : unsigned(15 downto 0) := x"88A4";
  constant ADDR_SOUND3_LAST     : unsigned(15 downto 0) := x"88AD";

  -- Math coprocessor: signed 32x32 fixed-point multiplier (16 bytes)
  constant ADDR_MATH_BASE       : unsigned(15 downto 0) := x"88B0";
  constant ADDR_MATH_LAST       : unsigned(15 downto 0) := x"88BF";

  -- VIC Sprite data: Sprite pattern storage (256 bytes)
  constant ADDR_VIC_SPD_BASE    : unsigned(15 downto 0) := x"8900";
  constant ADDR_VIC_SPD_LAST    : unsigned(15 downto 0) := x"89FF";

  -- VIC Control registers: Chip configuration and control (16 bytes)
  constant ADDR_VIC_REG_BASE    : unsigned(15 downto 0) := x"9000";
  constant ADDR_VIC_REG_LAST    : unsigned(15 downto 0) := x"900F";

  -- VIC Bitmap: Main video frame buffer (40KB for graphics display)
  -- Dedicated 8 KB bitmap RAM. Kept below EhBASIC ($A000) and outside its
  -- configured working RAM ($0200-$3FFF). This replaces the old $9010-$AF4F
  -- window, which overlapped the relocated EhBASIC ROM.
  constant ADDR_VIC_BMP_BASE    : unsigned(15 downto 0) := x"6000";
  constant ADDR_VIC_BMP_LAST    : unsigned(15 downto 0) := x"7FFF";

  constant ADDR_SID_BASE        : unsigned(15 downto 0) := x"D400";
  constant ADDR_SID_LAST        : unsigned(15 downto 0) := x"D418";

  -- ROM (legacy single-window constants, still used by the older boot monitors).
  constant ADDR_ROM_BASE        : unsigned(15 downto 0) := x"C000";
  constant ADDR_ROM_LAST        : unsigned(15 downto 0) := x"FFFF";

  -- Split ROM layout for the Tang build: EhBASIC at $A000-$CFFF and the Kernel
  -- at $F000-$FFFF, leaving $D000-$DFFF free for I/O.  The 16K ROM image keeps a
  -- single boot_shadow_rom; rom_offset() maps each window into it.
  constant ADDR_BASROM_BASE     : unsigned(15 downto 0) := x"A000";   -- EhBASIC
  constant ADDR_BASROM_LAST     : unsigned(15 downto 0) := x"CFFF";
  constant ADDR_KERNROM_BASE    : unsigned(15 downto 0) := x"F000";   -- Kernel
  constant ADDR_KERNROM_LAST    : unsigned(15 downto 0) := x"FFFF";

  -- Device selection enumeration: Used by bus decoder to identify which peripheral is active
  type device_sel_t is (
    DEV_NONE,      -- No device selected (invalid address)
    DEV_SRAM,      -- Main system RAM
    DEV_VIC_TEXT,  -- VIC text display memory
    DEV_VIA,       -- Parallel I/O controller
    DEV_UART,      -- Serial UART interface
    DEV_USB,       -- USB HID host keyboard
    DEV_DISK,      -- Disk controller
    DEV_SOUND0,    -- Synthesis channel 0
    DEV_VIC_BLIT,  -- Hardware graphics blitter
    DEV_VIC_SPR,   -- Sprite register controller
    DEV_SOUND1,    -- Synthesis channel 1
    DEV_SOUND2,    -- Synthesis channel 2
    DEV_SOUND3,    -- Synthesis channel 3
    DEV_VIC_SPD,   -- Sprite pattern data
    DEV_VIC_REG,   -- VIC control registers
    DEV_VIC_BMP,   -- Bitmap frame buffer
    DEV_MATH,      -- Fixed-point math coprocessor
    DEV_SID,       -- MOS 6581-compatible audio registers
    DEV_ROM        -- Read-only firmware
  );

  -- Utility function: Checks if an address falls within a specified range
  -- Used by the bus decoder to determine device selection
  function in_range(addr : addr_t; first_addr : unsigned; last_addr : unsigned)
    return boolean;

  -- True if addr is in either ROM window (BASIC $A000-$CFFF, Kernel $F000-$FFFF).
  function is_rom_addr(addr : addr_t) return boolean;

  -- Map a CPU/monitor address in a ROM window to its byte offset in the 16K ROM
  -- image: $A000-$CFFF -> $0000-$2FFF, $F000-$FFFF -> $3000-$3FFF.
  function rom_offset(addr : addr_t) return std_logic_vector;
end package;

package body sbc_pkg is
  -- Function implementation: Address range checking utility
  -- Returns true if addr is within [first_addr, last_addr] inclusive
  -- Handles X (unknown) addresses safely by returning false
  function in_range(addr : addr_t; first_addr : unsigned; last_addr : unsigned)
    return boolean is
    variable a : unsigned(15 downto 0);
  begin
    -- Check for undefined/unknown bits in address (typical in simulation)
    if is_x(addr) then
      return false;
    end if;

    -- Convert address to unsigned and compare against range bounds
    a := unsigned(addr);
    return a >= first_addr and a <= last_addr;
  end function;

  function is_rom_addr(addr : addr_t) return boolean is
    variable a : unsigned(15 downto 0);
  begin
    if is_x(addr) then
      return false;
    end if;
    a := unsigned(addr);
    return (a >= ADDR_BASROM_BASE  and a <= ADDR_BASROM_LAST)
        or (a >= ADDR_KERNROM_BASE and a <= ADDR_KERNROM_LAST);
  end function;

  function rom_offset(addr : addr_t) return std_logic_vector is
    variable a : unsigned(15 downto 0);
    variable o : unsigned(15 downto 0);
    variable r : std_logic_vector(13 downto 0) := (others => '0');
  begin
    if is_x(addr) then
      return r;
    end if;
    a := unsigned(addr);
    if a >= ADDR_KERNROM_BASE then
      o := a - x"C000";   -- $F000-$FFFF -> $3000-$3FFF
    else
      o := a - x"A000";   -- $A000-$CFFF -> $0000-$2FFF
    end if;
    r := std_logic_vector(o(13 downto 0));
    return r;
  end function;
end package body;
