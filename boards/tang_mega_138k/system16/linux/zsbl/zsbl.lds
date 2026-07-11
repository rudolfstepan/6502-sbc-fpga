/* GoRV32 Plus ZSBL: code and rodata execute in place from the QSPI XIP
 * window, data/bss/stack live in the IP's on-chip RAM. The 32K SRAM length
 * keeps the layout valid for both the 32KB and 64KB IP configurations. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  XIP  (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
  SRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 32K
}
SECTIONS {
  .text : {
    KEEP(*(.text.start))
    *(.text*)
    *(.rodata*)
    *(.srodata*)
    . = ALIGN(4);
  } > XIP
  __data_load = LOADADDR(.data);
  .data : {
    __data_start = .;
    *(.data*)
    *(.sdata*)
    . = ALIGN(4);
    __data_end = .;
  } > SRAM AT > XIP
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > SRAM
  __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
}
