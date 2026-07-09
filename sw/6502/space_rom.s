; ROM build of the space blitter demo: the unmodified PRG from the emulator repo
; is carried in ROM and copied to its load address at reset (see
; prg_rom_wrapper.inc). Build from the repo root:
;   make roms/6502/space_rom.bin
.define PRG_FILE "space.prg"
.include "prg_rom_wrapper.inc"
