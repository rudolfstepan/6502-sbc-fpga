; MiSTer64 SD FAT16 D64 selector.
;
; Unlike sw/c64_sd_d64_select.s this PRG does not need a PC-generated LBA
; table: it parses the FAT16 filesystem on the SD card itself through the
; probe's raw-block window and lists every *.D64 in the root directory.
;
;   $DF00-$DF03  LBA register, little-endian (scratch during the scan,
;                mounted .d64 start LBA at the end)
;   $DF04        write $01 to mount the LBA as packed .d64
;   $DF05        status: bit0 SD ready, bit1 drive active, bit2 mounted
;   $DF0A        byte offset inside the buffered 256-byte half
;   $DF0B        status: bit0 SD ready, bit1 busy, bit2 ready, bit3 error;
;                write bit1=1 to clear a stale error
;   $DF0C        buffered data byte at $DF0A
;   $DF0D        write bit0=1 to read the SD block at $DF00-$DF03,
;                bit1 selects the buffered half (0 = bytes 0-255)
;
; Handles both card layouts of tools/d64/make_fat16_d64_card.py: MBR with
; one FAT16 partition (default, start LBA 2048) and superfloppy (boot sector
; at LBA 0).  Before mounting, the FAT chain of the selected file is walked
; to make sure the .d64 is stored contiguously; fragmented files are refused
; because the packed-D64 backend reads sectors by plain LBA arithmetic.
;
; After selecting a disk, return to BASIC and use:
;   LOAD"$",8
;   LIST
;   LOAD"*",8,1

.setcpu "6502"

LOAD_ADDR  = $0801

CHROUT = $FFD2
GETIN  = $FFE4

SD_LBA0  = $DF00
SD_LBA1  = $DF01
SD_LBA2  = $DF02
SD_LBA3  = $DF03
SD_CMD   = $DF04
SD_STAT  = $DF05
FL_OFFSET = $DF0A
FL_STAT   = $DF0B
FL_DATA   = $DF0C
RAW_CMD   = $DF0D

MAX_ENTRIES = 16                 ; menu page size: keys 1-9 then A-G
; name_tab: 16 bytes per entry (zero-terminated display name)
; meta_tab:  8 bytes per entry (+0 start LBA, +4 start cluster, +6 clusters)

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
PTR:    .res 2

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"
start:
        sei
        cld
        lda #$93
        jsr CHROUT
        lda #<title
        ldy #>title
        jsr print_z

        lda SD_STAT
        and #$01
        bne sd_ok
        lda #<no_sd
        ldy #>no_sd
        jsr print_z
        jmp done
sd_ok:
        lda #<scanning
        ldy #>scanning
        jsr print_z

        jsr find_partition
        bcc :+
        jmp scan_failed
:
        jsr parse_vbr
        bcc :+
        jmp scan_failed
:
        lda #$00
        sta PAGE_START
scan_page:
        jsr scan_root_dir
        bcc :+
        jmp scan_failed
:
        lda ENTRY_CNT
        bne have_entries
        lda #<no_files
        ldy #>no_files
        jsr print_z
        jmp done

have_entries:
        jsr show_menu

wait_key:
        jsr GETIN
        beq wait_key
        cmp #$03                 ; RUN/STOP
        bne :+
        jmp done
:
        cmp #$11                 ; cursor down/right -> next page
        beq next_page
        cmp #$1D
        beq next_page
        cmp #$91                 ; cursor up/left -> previous page
        beq prev_page
        cmp #$9D
        beq prev_page
        jsr key_to_index
        bcs wait_key
        sta SEL
        jsr check_contiguous
        bcc do_mount
        lda #<fragmented
        ldy #>fragmented
        jsr print_z
        jmp wait_key

next_page:
        lda PAGE_MORE
        beq wait_key
        clc
        lda PAGE_START
        adc #MAX_ENTRIES
        sta PAGE_START
        jmp scan_page

prev_page:
        lda PAGE_START
        beq wait_key
        sec
        sbc #MAX_ENTRIES
        sta PAGE_START
        jmp scan_page

do_mount:
        jsr meta_ptr
        lda meta_tab+0,x
        sta SD_LBA0
        lda meta_tab+1,x
        sta SD_LBA1
        lda meta_tab+2,x
        sta SD_LBA2
        lda meta_tab+3,x
        sta SD_LBA3
        lda #$01
        sta SD_CMD
        lda #<mounted_msg
        ldy #>mounted_msg
        jsr print_z
        jsr name_ptr
        jsr print_entry_name
        lda #$0D
        jsr CHROUT
        lda #<usage
        ldy #>usage
        jsr print_z

done:
        cli
        rts

scan_failed:
        lda #<scan_err
        ldy #>scan_err
        jsr print_z
        lda ERRCODE
        jsr print_hex
        lda #$0D
        jsr CHROUT
        jmp done

; ---------------------------------------------------------------------------
; Raw SD block access
; ---------------------------------------------------------------------------

; Read the SD block at CUR_LBA; A = 0 lower half, 1 upper half.
; Returns carry set on error/timeout.
read_half:
        asl
        ora #$01
        pha
        lda CUR_LBA
        sta SD_LBA0
        lda CUR_LBA+1
        sta SD_LBA1
        lda CUR_LBA+2
        sta SD_LBA2
        lda CUR_LBA+3
        sta SD_LBA3
        lda #$02                 ; clear a stale error first
        sta FL_STAT
        pla
        sta RAW_CMD
        lda #$00
        sta WAIT0
        sta WAIT1
read_wait:
        lda FL_STAT
        and #$08
        bne read_err
        lda FL_STAT
        and #$04
        bne read_done
        dec WAIT0
        bne read_wait
        dec WAIT1
        bne read_wait
read_err:
        lda #$D1
        sta ERRCODE
        sec
        rts
read_done:
        clc
        rts

; A = buffer offset, returns byte in A.  X and Y are preserved.
get_byte:
        sta FL_OFFSET
        lda FL_DATA
        rts

; ---------------------------------------------------------------------------
; 32-bit LBA helpers
; ---------------------------------------------------------------------------

cur_lba_zero:
        lda #$00
        sta CUR_LBA
        sta CUR_LBA+1
        sta CUR_LBA+2
        sta CUR_LBA+3
        rts

; CUR_LBA += ADD16 (16-bit little-endian operand)
cur_lba_add16:
        clc
        lda CUR_LBA
        adc ADD16
        sta CUR_LBA
        lda CUR_LBA+1
        adc ADD16+1
        sta CUR_LBA+1
        lda CUR_LBA+2
        adc #$00
        sta CUR_LBA+2
        lda CUR_LBA+3
        adc #$00
        sta CUR_LBA+3
        rts

cur_lba_inc:
        inc CUR_LBA
        bne :+
        inc CUR_LBA+1
        bne :+
        inc CUR_LBA+2
        bne :+
        inc CUR_LBA+3
:
        rts

; ---------------------------------------------------------------------------
; Partition / boot sector parsing
; ---------------------------------------------------------------------------

; Sets PART_LBA.  MBR layout: boot signature $55AA at $1FE, first partition
; entry at $1BE with a FAT16 type byte.  Anything else is treated as a
; superfloppy with the FAT16 boot sector directly at LBA 0.
find_partition:
        jsr cur_lba_zero
        lda #$01                 ; upper half holds bytes $100-$1FF
        jsr read_half
        bcc :+
        rts
:
        lda #$FE                 ; $1FE boot signature
        jsr get_byte
        cmp #$55
        bne no_boot_sig
        lda #$FF
        jsr get_byte
        cmp #$AA
        bne no_boot_sig

        lda #$C2                 ; $1BE + 4: partition type
        jsr get_byte
        cmp #$04                 ; FAT16 <32M
        beq mbr_part
        cmp #$06                 ; FAT16
        beq mbr_part
        cmp #$0E                 ; FAT16 LBA
        beq mbr_part
        ; no FAT16 partition entry: assume superfloppy
        lda #$00
        sta PART_LBA
        sta PART_LBA+1
        sta PART_LBA+2
        sta PART_LBA+3
        clc
        rts

mbr_part:
        lda #$C6                 ; $1BE + 8: partition start LBA
        jsr get_byte
        sta PART_LBA
        lda #$C7
        jsr get_byte
        sta PART_LBA+1
        lda #$C8
        jsr get_byte
        sta PART_LBA+2
        lda #$C9
        jsr get_byte
        sta PART_LBA+3
        clc
        rts

no_boot_sig:
        lda #$D2
        sta ERRCODE
        sec
        rts

; Parses the FAT16 boot sector at PART_LBA and derives FAT_LBA, ROOT_LBA,
; DATA_LBA, SPC_SHIFT and ROOT_SECT.
vbr_fail:
        jmp bad_vbr
parse_vbr:
        lda PART_LBA
        sta CUR_LBA
        lda PART_LBA+1
        sta CUR_LBA+1
        lda PART_LBA+2
        sta CUR_LBA+2
        lda PART_LBA+3
        sta CUR_LBA+3
        lda #$00
        jsr read_half
        bcc :+
        rts
:
        lda #$0B                 ; bytes per sector must be 512
        jsr get_byte
        cmp #$00
        bne vbr_fail
        lda #$0C
        jsr get_byte
        cmp #$02
        bne vbr_fail

        lda #$0D                 ; sectors per cluster (power of two)
        jsr get_byte
        beq vbr_fail
        ldx #$00
spc_shift_loop:
        lsr
        beq spc_shift_done
        inx
        jmp spc_shift_loop
spc_shift_done:
        stx SPC_SHIFT

        lda #$10                 ; number of FATs
        jsr get_byte
        sta NFATS
        beq vbr_fail

        lda #$11                 ; root entries -> ROOT_SECT = entries/16
        jsr get_byte
        sta ROOT_SECT
        lda #$12
        jsr get_byte
        sta ROOT_SECT+1
        ldx #$04
root_shift:
        lsr ROOT_SECT+1
        ror ROOT_SECT
        dex
        bne root_shift

        lda #$16                 ; sectors per FAT
        jsr get_byte
        sta SPF
        lda #$17
        jsr get_byte
        sta SPF+1

        lda #$0E                 ; reserved sectors
        jsr get_byte
        sta ADD16
        lda #$0F
        jsr get_byte
        sta ADD16+1
        jsr cur_lba_add16        ; CUR_LBA = PART_LBA + reserved = first FAT

        lda CUR_LBA
        sta FAT_LBA
        lda CUR_LBA+1
        sta FAT_LBA+1
        lda CUR_LBA+2
        sta FAT_LBA+2
        lda CUR_LBA+3
        sta FAT_LBA+3

        lda SPF                  ; + NFATS * sectors per FAT
        sta ADD16
        lda SPF+1
        sta ADD16+1
        ldx NFATS
fat_add_loop:
        jsr cur_lba_add16
        dex
        bne fat_add_loop

        lda CUR_LBA
        sta ROOT_LBA
        lda CUR_LBA+1
        sta ROOT_LBA+1
        lda CUR_LBA+2
        sta ROOT_LBA+2
        lda CUR_LBA+3
        sta ROOT_LBA+3

        lda ROOT_SECT            ; + root directory size
        sta ADD16
        lda ROOT_SECT+1
        sta ADD16+1
        jsr cur_lba_add16

        lda CUR_LBA
        sta DATA_LBA
        lda CUR_LBA+1
        sta DATA_LBA+1
        lda CUR_LBA+2
        sta DATA_LBA+2
        lda CUR_LBA+3
        sta DATA_LBA+3
        clc
        rts

bad_vbr:
        lda #$D3
        sta ERRCODE
        sec
        rts

; ---------------------------------------------------------------------------
; Root directory scan
; ---------------------------------------------------------------------------

scan_root_dir:
        lda #$00
        sta ENTRY_CNT
        sta SCAN_DONE
        sta PAGE_MORE
        lda PAGE_START
        sta SKIP_LEFT
        lda ROOT_SECT
        sta SEC_LEFT
        lda ROOT_SECT+1
        sta SEC_LEFT+1
        lda ROOT_LBA
        sta CUR_LBA
        lda ROOT_LBA+1
        sta CUR_LBA+1
        lda ROOT_LBA+2
        sta CUR_LBA+2
        lda ROOT_LBA+3
        sta CUR_LBA+3

root_sector_loop:
        lda SEC_LEFT
        ora SEC_LEFT+1
        beq root_scan_end
        lda #$00
        sta HALF
root_half_loop:
        lda HALF
        jsr read_half
        bcc :+
        rts
:
        lda #$00
        sta ENT_OFF
root_entry_loop:
        jsr scan_one_entry
        lda SCAN_DONE
        bne root_scan_end
        clc
        lda ENT_OFF
        adc #32
        sta ENT_OFF
        bne root_entry_loop
        inc HALF
        lda HALF
        cmp #$02
        bcc root_half_loop
        jsr cur_lba_inc
        lda SEC_LEFT
        bne :+
        dec SEC_LEFT+1
:
        dec SEC_LEFT
        jmp root_sector_loop

root_scan_end:
        clc
        rts

; Examines the 32-byte directory entry at buffer offset ENT_OFF.
scan_one_entry:
        lda ENT_OFF
        jsr get_byte
        bne :+
        lda #$01                 ; first never-used entry ends the directory
        sta SCAN_DONE
        rts
:
        cmp #$E5                 ; deleted
        beq entry_skip
        clc
        lda ENT_OFF
        adc #11
        jsr get_byte
        and #$18                 ; volume label, LFN slot or directory
        bne entry_skip
        clc
        lda ENT_OFF
        adc #8
        jsr get_byte
        cmp #'D'
        bne entry_skip
        clc
        lda ENT_OFF
        adc #9
        jsr get_byte
        cmp #'6'
        bne entry_skip
        clc
        lda ENT_OFF
        adc #10
        jsr get_byte
        cmp #'4'
        bne entry_skip
        jmp entry_record
entry_skip:
        rts

entry_record:
        lda SKIP_LEFT
        beq entry_not_skipped
        dec SKIP_LEFT
        rts
entry_not_skipped:
        lda ENTRY_CNT
        cmp #MAX_ENTRIES
        bcc entry_store
        lda #$01
        sta PAGE_MORE
        sta SCAN_DONE
        rts
entry_store:
        sta SEL

        ; display name: stem without trailing blanks + ".D64"
        jsr name_ptr
        ldy #$00
name_copy:
        tya
        clc
        adc ENT_OFF
        jsr get_byte
        cmp #' '
        beq name_stem_end
        sta name_tab,x
        inx
        iny
        cpy #$08
        bcc name_copy
name_stem_end:
        lda #'.'
        sta name_tab,x
        inx
        lda #'D'
        sta name_tab,x
        inx
        lda #'6'
        sta name_tab,x
        inx
        lda #'4'
        sta name_tab,x
        inx
        lda #$00
        sta name_tab,x

        ; start cluster
        jsr meta_ptr
        clc
        lda ENT_OFF
        adc #26
        jsr get_byte
        sta meta_tab+4,x
        sta CLUS
        clc
        lda ENT_OFF
        adc #27
        jsr get_byte
        sta meta_tab+5,x
        sta CLUS+1

        ; sectors = (size + 511) >> 9, then clusters = ceil(sectors / SPC)
        clc
        lda ENT_OFF
        adc #28
        jsr get_byte
        sta SIZE0
        clc
        lda ENT_OFF
        adc #29
        jsr get_byte
        sta SIZE1
        clc
        lda ENT_OFF
        adc #30
        jsr get_byte
        sta SIZE2
        clc                      ; 24-bit size += $0001FF
        lda SIZE0
        adc #$FF
        sta SIZE0
        lda SIZE1
        adc #$01
        sta SIZE1
        lda SIZE2
        adc #$00
        sta SIZE2
        lda SIZE2                ; >> 9: drop SIZE0, shift the rest right once
        lsr
        sta SECT16+1
        lda SIZE1
        ror
        sta SECT16
        ldy SPC_SHIFT
        beq clus_count_done
        lda #$00
        sta ROUND_UP
clus_shift:
        lsr SECT16+1
        ror SECT16
        bcc :+
        lda #$01                 ; a remainder bit fell out: round up later
        sta ROUND_UP
:
        dey
        bne clus_shift
        lda ROUND_UP
        beq clus_count_done
        inc SECT16
        bne clus_count_done
        inc SECT16+1
clus_count_done:
        lda SECT16
        sta meta_tab+6,x
        lda SECT16+1
        sta meta_tab+7,x

        ; start LBA = DATA_LBA + (cluster - 2) << SPC_SHIFT
        sec
        lda CLUS
        sbc #$02
        sta MUL24
        lda CLUS+1
        sbc #$00
        sta MUL24+1
        lda #$00
        sta MUL24+2
        ldy SPC_SHIFT
        beq lba_shift_done
lba_shift:
        asl MUL24
        rol MUL24+1
        rol MUL24+2
        dey
        bne lba_shift
lba_shift_done:
        clc
        lda DATA_LBA
        adc MUL24
        sta meta_tab+0,x
        lda DATA_LBA+1
        adc MUL24+1
        sta meta_tab+1,x
        lda DATA_LBA+2
        adc MUL24+2
        sta meta_tab+2,x
        lda DATA_LBA+3
        adc #$00
        sta meta_tab+3,x

        inc ENTRY_CNT
        rts

; ---------------------------------------------------------------------------
; FAT chain contiguity check for entry SEL
; ---------------------------------------------------------------------------

check_contiguous:
        jsr meta_ptr
        lda meta_tab+4,x
        sta CLUS
        lda meta_tab+5,x
        sta CLUS+1
        lda meta_tab+6,x
        sta NCLUS
        lda meta_tab+7,x
        sta NCLUS+1
        lda #$FF
        sta FAT_CACHE_L          ; invalidate the cached FAT sector
        sta FAT_CACHE_H

walk_loop:
        ; done once at most the last cluster remains
        lda NCLUS+1
        bne :+
        lda NCLUS
        cmp #$02
        bcc walk_ok
:
        jsr read_fat_entry
        bcs walk_fail
        clc                      ; FAT entry must be CLUS + 1
        lda CLUS
        adc #$01
        sta TMP
        lda CLUS+1
        adc #$00
        cmp FATVAL+1
        bne walk_fail
        lda TMP
        cmp FATVAL
        bne walk_fail
        inc CLUS
        bne :+
        inc CLUS+1
:
        lda NCLUS
        bne :+
        dec NCLUS+1
:
        dec NCLUS
        jmp walk_loop

walk_ok:
        clc
        rts
walk_fail:
        sec
        rts

; Reads the 16-bit FAT16 entry for cluster CLUS into FATVAL.
; FAT sector index = CLUS >> 8, half = CLUS bit 7, offset = (CLUS & $7F) * 2.
read_fat_entry:
        lda CLUS
        and #$80
        sta TMP
        lda CLUS+1
        cmp FAT_CACHE_H
        bne fat_load
        lda FAT_CACHE_L
        cmp TMP
        beq fat_cached
fat_load:
        lda FAT_LBA
        sta CUR_LBA
        lda FAT_LBA+1
        sta CUR_LBA+1
        lda FAT_LBA+2
        sta CUR_LBA+2
        lda FAT_LBA+3
        sta CUR_LBA+3
        lda CLUS+1
        sta ADD16
        lda #$00
        sta ADD16+1
        jsr cur_lba_add16
        lda #$00
        ldy TMP
        beq :+
        lda #$01
:
        jsr read_half
        bcc :+
        rts
:
        lda CLUS+1
        sta FAT_CACHE_H
        lda TMP
        sta FAT_CACHE_L
fat_cached:
        lda CLUS
        and #$7F
        asl
        pha
        jsr get_byte
        sta FATVAL
        pla
        clc
        adc #$01
        jsr get_byte
        sta FATVAL+1
        clc
        rts

; ---------------------------------------------------------------------------
; Menu
; ---------------------------------------------------------------------------

show_menu:
        lda #$93
        jsr CHROUT
        lda #<title
        ldy #>title
        jsr print_z
        lda #<found_msg
        ldy #>found_msg
        jsr print_z
        lda #$00
        sta SEL
menu_loop:
        lda SEL
        cmp ENTRY_CNT
        bcs menu_done
        cmp #$09
        bcs menu_alpha
        clc
        adc #'1'
        jmp menu_key
menu_alpha:
        sec
        sbc #$09
        clc
        adc #'A'
menu_key:
        jsr CHROUT
        lda #' '
        jsr CHROUT
        jsr name_ptr
        jsr print_entry_name
        lda #$0D
        jsr CHROUT
        inc SEL
        jmp menu_loop
menu_done:
        lda #<prompt
        ldy #>prompt
        jsr print_z
        rts

; PETSCII key in A -> entry index in A, carry set if invalid.
key_to_index:
        cmp #'1'
        bcc not_digit
        cmp #('9' + 1)
        bcs not_digit
        sec
        sbc #'1'
        jmp check_index
not_digit:
        cmp #'A'
        bcc bad_key
        cmp #('Z' + 1)
        bcs bad_key
        sec
        sbc #('A' - 9)
check_index:
        cmp ENTRY_CNT
        bcs bad_key
        clc
        rts
bad_key:
        sec
        rts

; X = SEL * 16 into name_tab.
name_ptr:
        lda SEL
        asl
        asl
        asl
        asl
        tax
        rts

; X = SEL * 8 into meta_tab.
meta_ptr:
        lda SEL
        asl
        asl
        asl
        tax
        rts

print_entry_name:
        lda name_tab,x
        beq :+
        jsr CHROUT
        inx
        jmp print_entry_name
:
        rts

; ---------------------------------------------------------------------------
; Output helpers
; ---------------------------------------------------------------------------

print_z:
        sta PTR
        sty PTR+1
        ldy #$00
:
        lda (PTR),y
        beq :+
        jsr CHROUT
        iny
        bne :-
:
        rts

print_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr print_nibble
        pla
        and #$0F
print_nibble:
        cmp #$0A
        bcc :+
        adc #$06
:
        adc #$30
        jmp CHROUT

.segment "RODATA"
title:
        .byte "TANG SD FAT16 D64 SELECTOR", $0D, $0D, 0
scanning:
        .byte "SCANNING FAT16 ROOT DIR...", $0D, 0
no_sd:
        .byte "SD NOT READY", $0D, 0
no_files:
        .byte "NO D64 FILES FOUND", $0D, 0
scan_err:
        .byte "FAT16 SCAN ERROR $", 0
fragmented:
        .byte "FILE IS FRAGMENTED - NOT MOUNTED", $0D, 0
found_msg:
        .byte $0D, "D64 IMAGES:", $0D, 0
prompt:
        .byte $0D, "1-9/A-G SELECT, CRSR PAGE, STOP EXIT", $0D, 0
mounted_msg:
        .byte $0D, "MOUNTED: ", 0
usage:
        .byte "NOW USE: LOAD", $22, "$", $22, ",8 / LOAD", $22, "*", $22, ",8,1", $0D, 0

.segment "BSS"
CUR_LBA:    .res 4
PART_LBA:   .res 4
FAT_LBA:    .res 4
ROOT_LBA:   .res 4
DATA_LBA:   .res 4
ADD16:      .res 2
SPC_SHIFT:  .res 1
NFATS:      .res 1
SPF:        .res 2
ROOT_SECT:  .res 2
SEC_LEFT:   .res 2
HALF:       .res 1
ENT_OFF:    .res 1
SCAN_DONE:  .res 1
ENTRY_CNT:  .res 1
PAGE_START: .res 1
SKIP_LEFT:  .res 1
PAGE_MORE:  .res 1
SEL:        .res 1
CLUS:       .res 2
NCLUS:      .res 2
FATVAL:     .res 2
FAT_CACHE_L: .res 1
FAT_CACHE_H: .res 1
SIZE0:      .res 1
SIZE1:      .res 1
SIZE2:      .res 1
SECT16:     .res 2
MUL24:      .res 3
ROUND_UP:   .res 1
TMP:        .res 1
ERRCODE:    .res 1
WAIT0:      .res 1
WAIT1:      .res 1

name_tab:   .res MAX_ENTRIES * 16
meta_tab:   .res MAX_ENTRIES * 8
