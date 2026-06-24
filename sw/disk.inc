; disk.inc — D64 GoDrive register map and constants for the FPGA 6502 SBC.
;
; The drive lives in the DEV_DISK window at $8824 (see docs/D64_DRIVE.md and
; rtl/core/peripherals/d64_subsystem.vhd).  The 6502 issues MOUNT then
; READ_SECTOR and reads the 256-byte D64 sector through the DATA port.

; ── Registers ──────────────────────────────────────────────────────────────
DISK_STATUS  = $8824        ; R
DISK_COMMAND = $8825        ; W
DISK_TRACK   = $8826        ; RW  (1-based)
DISK_SECTOR  = $8827        ; RW  (0-based)
DISK_RESULT  = $8828        ; R   last DISK_RESULT code
DISK_DATA    = $8829        ; R   sector-buffer port (read auto-increments)
DISK_PTR_LO  = $882A        ; RW  buffer pointer 0..255
DISK_PTR_HI  = $882B        ; R   reserved (always 0) — also raw LBA[7:0] on write
; Raw debug LBA bytes (write before CMD_RAW_READ). Offsets 8..11 of the window.
DISK_RAW_LBA0 = $882C        ; W  raw LBA byte 0 (LSB)
DISK_RAW_LBA1 = $882D        ; W  raw LBA byte 1
DISK_RAW_LBA2 = $882E        ; W  raw LBA byte 2
DISK_RAW_LBA3 = $882F        ; W  raw LBA byte 3 (MSB)
; Debug-word readback: write a selector to DISK_DBG_SEL, then read the 32-bit
; value (LSB..MSB) from DISK_RAW_LBA0..3. Selectors:
;   0=data_start 1=fat_start 2=root_lba 3=spf 4=file_lba 5=reserved
DISK_DBG_SEL  = $882B        ; W  (same addr as PTR_HI; write-only debug select)
DBG_DATA_START = 0
DBG_FAT_START  = 1
DBG_ROOT_LBA   = 2
DBG_SPF        = 3
DBG_FILE_LBA   = 4
DBG_RESERVED   = 5

; ── STATUS bits ──────────────────────────────────────────────────────────--
STATUS_BUSY          = %00000001
STATUS_DONE          = %00000010
STATUS_ERROR         = %00000100
STATUS_MOUNTED       = %00001000
STATUS_WRITE_PROTECT = %00010000
STATUS_IMAGE_READY   = %01000000

; ── Commands ─────────────────────────────────────────────────────────────--
CMD_NOP          = $00
CMD_READ_SECTOR  = $01
CMD_MOUNT        = $03
CMD_UNMOUNT      = $04
CMD_RAW_READ     = $05      ; debug: read raw card LBA (lower 256 bytes -> DATA)
CMD_RESET        = $0A

; ── Result codes ─────────────────────────────────────────────────────────--
DISK_OK              = $00
DISK_NO_IMAGE        = $01
DISK_INVALID_TRACK   = $02
DISK_INVALID_SECTOR  = $03
DISK_SD_READ_ERROR   = $04
DISK_UNSUPPORTED     = $06
DISK_INVALID_COMMAND = $0A
DISK_DIR_ERROR       = $0B

; ── D64 geometry ─────────────────────────────────────────────────────────--
DIR_TRACK        = 18
BAM_SECTOR       = 0
DIR_FIRST_SECTOR = 1

; D64 directory entry layout (offsets within a 32-byte entry)
DE_TYPE     = 0             ; file type ($00 DEL, $82 = closed PRG, ...)
DE_TRACK    = 1             ; first file block track
DE_SECTOR   = 2             ; first file block sector
DE_NAME     = 3             ; 16 PETSCII bytes, $A0 padded
DE_SIZE_LO  = 30            ; size in blocks, low byte
DE_SIZE_HI  = 31

FT_TYPE_MASK = $07
FT_PRG       = $02
FT_CLOSED    = $80
