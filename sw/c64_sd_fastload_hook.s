; Tang MiSTer64 combined resident SD hook: fastloader + FAT16 disk menu.
;
; One resident program at $C000 replaces the separate fastload hook and disk
; selector.  It installs a LOAD vector hook at $0330; the patched KERNAL also
; detects it by the JMP opcode at $C000 and enters at $C003 directly, so the
; hook survives RUN/STOP+RESTORE.
;
;   LOAD"@",8       FAT16 disk menu: scans the SD root directory for *.D64,
;                   walks the FAT chain (fragmented files are refused) and
;                   mounts the selection
;   LOAD"*",8,1     fastload the first PRG from the mounted D64
;   LOAD"NAME",8,1  fastload by name through the $DF08-$DF0C sector window
;   LOAD"$",8       falls back to the original KERNAL/IEC path, like VERIFY
;                   and every other device

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $C000

CHROUT = $FFD2
GETIN  = $FFE4
ILOAD  = $0330

STATUS_REG = $90
MEMUSS     = $C3
TXTTAB     = $2B
VARTAB     = $2D
ARYTAB     = $2F
STREND     = $31
FNLEN      = $B7
SA         = $B9
FA         = $BA
FNADR      = $BB

ZP_PTR = $FB

SD_LBA0   = $DF00
SD_LBA1   = $DF01
SD_LBA2   = $DF02
SD_LBA3   = $DF03
SD_CMD    = $DF04
SD_STAT   = $DF05
FL_TRACK  = $DF08
FL_SECTOR = $DF09
FL_OFFSET = $DF0A
FL_STAT   = $DF0B
FL_DATA   = $DF0C
RAW_CMD   = $DF0D

MAX_ENTRIES = 16                 ; menu page size: keys 1-9 then A-G

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "49152", 0     ; 10 SYS 49152 ($C000)
basic_end:
        .word 0

.segment "CODE"
hook_header:
        jmp install               ; $C000: the KERNAL stub checks for this JMP
hook_load_entry:
        jmp vload                 ; $C003: entered directly by the KERNAL stub

install:
        sei
        cld
        jsr save_zp
        lda #<$F4A5
        sta old_load
        lda #>$F4A5
        sta old_load+1
        lda #<vload
        sta ILOAD
        lda #>vload
        sta ILOAD+1
        lda #<install_msg
        ldy #>install_msg
        jsr print_z
        jsr restore_zp
        cli
        rts

; ---------------------------------------------------------------------------
; LOAD dispatch
; ---------------------------------------------------------------------------

vload:
        stx MEMUSS
        sty MEMUSS+1
        sta verify_flag
        stx req_addr
        sty req_addr+1
        lda VARTAB               ; kept intact for the menu return path
        sta vartab_save
        lda VARTAB+1
        sta vartab_save+1
        lda verify_flag
        cmp #$00
        beq :+
        jmp old_load_entry
:
        lda FA
        cmp #$08
        beq vload_device8
        jmp old_load_entry

vload_device8:
        lda FNLEN
        beq fastload_ok_name
        ldy #0
        lda (FNADR),y
        cmp #'$'
        bne :+
        jmp old_load_entry
:
        cmp #'@'
        bne fastload_ok_name
        jmp menu_entry

fastload_ok_name:
        sei
        cld
        jsr save_zp
        lda #$00
        sta STATUS_REG
        sta ERRCODE
        sta LAST_STAT
        lda req_addr
        sta DST
        sta LOADP
        lda req_addr+1
        sta DST+1
        sta LOADP+1
        jsr set_zp_dst

        lda FL_STAT
        and #$01
        bne :+
        lda #$E1
        jmp load_failed_code
:
        lda FL_STAT
        and #$10                 ; bit4 = D64 mounted via $DF00-$DF04
        bne :+
        lda #$E5
        jmp load_failed_code
:

        jsr find_requested_prg
        bcc found_prg
        lda ERRCODE
        bne :+
        lda #$E3
:
        jmp load_failed_code
found_prg:
        jsr load_prg_chain
        bcc :+
        lda #$E4
        jmp load_failed_code
:

        jsr patch_basic_if_0801
        jsr restore_zp
        cli
        ldx DST
        ldy DST+1
        lda #$00
        clc
        rts

load_failed:
        lda #$EF
load_failed_code:
        sta ERRCODE
        jsr print_fail_diag
        lda ERRCODE
        cmp #$E5
        bne :+
        lda #<menu_hint
        ldy #>menu_hint
        jsr print_z
:
        lda #$05
        sta STATUS_REG
        jsr restore_zp
        cli
        lda #$04                 ; KERNAL error: file not found
        sec
        rts

old_load_entry:
        lda verify_flag
        ldx req_addr
        ldy req_addr+1
        jmp (old_load)

; ---------------------------------------------------------------------------
; Fastload: directory search and sector chain copy ($DF08-$DF0C)
; ---------------------------------------------------------------------------

find_requested_prg:
        lda #18
        sta DIRT
        lda #1
        sta DIRS

dir_sector:
        lda DIRT
        sta REQT
        lda DIRS
        sta REQS
        jsr read_sector
        bcc :+
        lda #$E2
        sta ERRCODE
        rts
:
        lda #0
        jsr get_byte
        sta NEXTT
        lda #1
        jsr get_byte
        sta NEXTS
        lda #2
        sta ENTRY_OFF
        ldx #8

dir_entry:
        lda ENTRY_OFF
        jsr get_byte
        sta TMP
        lda TMP
        and #$80
        beq dir_next
        lda TMP
        and #$07
        cmp #$02                 ; PRG
        bne dir_next
        jsr name_matches
        bcc dir_found

dir_next:
        clc
        lda ENTRY_OFF
        adc #32
        sta ENTRY_OFF
        dex
        bne dir_entry
        lda NEXTT
        beq dir_not_found
        sta DIRT
        lda NEXTS
        sta DIRS
        jmp dir_sector

dir_found:
        clc
        lda ENTRY_OFF
        adc #1
        jsr get_byte
        sta CURT
        clc
        lda ENTRY_OFF
        adc #2
        jsr get_byte
        sta CURS
        clc
        rts

dir_not_found:
        lda #$E3
        sta ERRCODE
        sec
        rts

name_matches:
        lda FNLEN
        beq match_yes
        ldy #0
        lda (FNADR),y
        cmp #'*'
        beq match_yes
        sty MATCH_POS

match_loop:
        ldy MATCH_POS
        cpy FNLEN
        beq match_rest_padding
        lda (FNADR),y
        cmp #'*'
        beq match_yes
        cmp #','
        beq match_rest_padding
        sta WANT_CHAR
        clc
        lda ENTRY_OFF
        adc #3                   ; ENTRY_OFF points at the type byte, name is at +3
        clc
        adc MATCH_POS
        jsr get_byte
        cmp WANT_CHAR
        bne match_no
        inc MATCH_POS
        lda MATCH_POS
        cmp #16
        bcc match_loop
        clc
        rts

match_rest_padding:
        lda MATCH_POS
        cmp #16
        bcs match_yes
        clc
        lda ENTRY_OFF
        adc #3                   ; ENTRY_OFF points at the type byte, name is at +3
        clc
        adc MATCH_POS
        jsr get_byte
        cmp #$A0
        bne match_no
        inc MATCH_POS
        jmp match_rest_padding

match_yes:
        clc
        rts
match_no:
        sec
        rts

load_prg_chain:
        lda #1
        sta FIRST

load_sector:
        lda CURT
        sta REQT
        lda CURS
        sta REQS
        jsr read_sector
        bcc :+
        rts
:
        lda #0
        jsr get_byte
        sta NEXTT
        lda #1
        jsr get_byte
        sta NEXTS

        lda #2
        sta OFFSET
        lda FIRST
        beq have_payload_start
        lda #2
        jsr get_byte
        sta FILE_LOAD
        lda #3
        jsr get_byte
        sta FILE_LOAD+1
        lda SA
        beq keep_requested_addr
        lda FILE_LOAD
        sta DST
        sta LOADP
        lda FILE_LOAD+1
        sta DST+1
        sta LOADP+1
        jsr set_zp_dst
keep_requested_addr:
        lda #4
        sta OFFSET
        lda #0
        sta FIRST

have_payload_start:
        lda NEXTT
        beq last_sector
        lda #$FF
        sta ENDOFF
        jmp copy_payload

last_sector:
        lda NEXTS
        sta ENDOFF

copy_payload:
        lda ENDOFF
        cmp OFFSET
        bcc sector_done
        lda OFFSET
        jsr get_byte
        ldy #0
        sta (ZP_PTR),y
        jsr inc_dst
        lda OFFSET
        cmp ENDOFF
        beq sector_done
        inc OFFSET
        jmp copy_payload

sector_done:
        lda NEXTT
        beq load_done
        sta CURT
        lda NEXTS
        sta CURS
        jmp load_sector

load_done:
        clc
        rts

read_sector:
        lda REQT
        sta FL_TRACK
        lda REQS
        sta FL_SECTOR
        lda #$00
        sta WAIT0
        sta WAIT1
        lda #$03                 ; clear previous error + start
        sta FL_STAT

read_wait:
        lda FL_STAT
        sta LAST_STAT
        and #$08
        bne read_error
        lda LAST_STAT
        and #$04
        bne read_ok
        dec WAIT0
        bne read_wait
        dec WAIT1
        bne read_wait
        sec
        rts

read_error:
        sec
        rts
read_ok:
        clc
        rts

get_byte:
        sta FL_OFFSET
        lda FL_DATA
        rts

inc_dst:
        inc DST
        bne inc_done
        inc DST+1
inc_done:
        jsr set_zp_dst
        rts

set_zp_dst:
        lda DST
        sta ZP_PTR
        lda DST+1
        sta ZP_PTR+1
        rts

patch_basic_if_0801:
        lda LOADP
        cmp #<LOAD_ADDR
        bne patch_done
        lda LOADP+1
        cmp #>LOAD_ADDR
        bne patch_done
        lda LOADP
        sta TXTTAB
        lda LOADP+1
        sta TXTTAB+1
        lda DST
        sta VARTAB
        sta ARYTAB
        sta STREND
        lda DST+1
        sta VARTAB+1
        sta ARYTAB+1
        sta STREND+1
patch_done:
        rts

; ---------------------------------------------------------------------------
; Disk menu (LOAD"@",8): FAT16 root directory scan + mount
; ---------------------------------------------------------------------------

menu_entry:
        cld
        jsr save_zp
        cli                      ; GETIN needs the IRQ keyboard scan
        lda #$00
        sta STATUS_REG
        lda #<menu_title
        ldy #>menu_title
        jsr print_z

        lda FL_STAT
        and #$01
        bne :+
        lda #<no_sd_msg
        ldy #>no_sd_msg
        jsr print_z
        jmp menu_exit
:
        jsr find_partition
        bcc :+
        jmp menu_scan_fail
:
        jsr parse_vbr
        bcc :+
        jmp menu_scan_fail
:
        lda #$00
        sta PAGE_START
menu_scan_page:
        jsr scan_root_dir
        bcc :+
        jmp menu_scan_fail
:
        lda ENTRY_CNT
        bne :+
        lda #<no_files_msg
        ldy #>no_files_msg
        jsr print_z
        jmp menu_exit
:
        jsr show_menu

menu_key_loop:
        jsr GETIN
        beq menu_key_loop
        cmp #$03                 ; RUN/STOP
        bne :+
        jmp menu_exit
:
        cmp #$11                 ; cursor down/right -> next page
        beq menu_next_page
        cmp #$1D
        beq menu_next_page
        cmp #$91                 ; cursor up/left -> previous page
        beq menu_prev_page
        cmp #$9D
        beq menu_prev_page
        jsr key_to_index
        bcs menu_key_loop
        sta SEL
        jsr check_contiguous
        bcc menu_mount
        lda #<frag_msg
        ldy #>frag_msg
        jsr print_z
        jmp menu_key_loop

menu_next_page:
        lda PAGE_MORE
        beq menu_key_loop
        clc
        lda PAGE_START
        adc #MAX_ENTRIES
        sta PAGE_START
        jmp menu_scan_page

menu_prev_page:
        lda PAGE_START
        beq menu_key_loop
        sec
        sbc #MAX_ENTRIES
        sta PAGE_START
        jmp menu_scan_page

menu_mount:
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
        lda #<usage_msg
        ldy #>usage_msg
        jsr print_z

menu_exit:
        jsr restore_zp
        lda #$00
        sta STATUS_REG
        ldx vartab_save          ; report "nothing loaded": BASIC keeps VARTAB
        ldy vartab_save+1
        lda #$00
        clc
        rts

menu_scan_fail:
        lda #<scan_err_msg
        ldy #>scan_err_msg
        jsr print_z
        lda ERRCODE
        jsr print_hex
        lda #$0D
        jsr CHROUT
        jmp menu_exit

; ---------------------------------------------------------------------------
; Raw SD block access ($DF0D window)
; ---------------------------------------------------------------------------

; Read the SD block at CUR_LBA; A = 0 lower half, 1 upper half.
; Returns carry set on error/timeout.
raw_read_half:
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
raw_wait:
        lda FL_STAT
        and #$08
        bne raw_err
        lda FL_STAT
        and #$04
        bne raw_done
        dec WAIT0
        bne raw_wait
        dec WAIT1
        bne raw_wait
raw_err:
        lda #$D1
        sta ERRCODE
        sec
        rts
raw_done:
        clc
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
; FAT16: partition and boot sector parsing
; ---------------------------------------------------------------------------

; Sets PART_LBA.  MBR layout: boot signature $55AA at $1FE, first partition
; entry at $1BE with a FAT16 type byte.  Anything else is treated as a
; superfloppy with the FAT16 boot sector directly at LBA 0.
find_partition:
        jsr cur_lba_zero
        lda #$01                 ; upper half holds bytes $100-$1FF
        jsr raw_read_half
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
        jsr raw_read_half
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
; FAT16: root directory scan
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
        jsr raw_read_half
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
        jsr raw_read_half
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
; Menu output and key handling
; ---------------------------------------------------------------------------

show_menu:
        lda #$93
        jsr CHROUT
        lda #<menu_title
        ldy #>menu_title
        jsr print_z
        lda #<found_msg
        ldy #>found_msg
        jsr print_z
        lda #$00
        sta SEL
menu_list_loop:
        lda SEL
        cmp ENTRY_CNT
        bcs menu_list_done
        cmp #$09
        bcs menu_alpha
        clc
        adc #'1'
        jmp menu_key_char
menu_alpha:
        sec
        sbc #$09
        clc
        adc #'A'
menu_key_char:
        jsr CHROUT
        lda #' '
        jsr CHROUT
        jsr name_ptr
        jsr print_entry_name
        lda #$0D
        jsr CHROUT
        inc SEL
        jmp menu_list_loop
menu_list_done:
        lda #<prompt_msg
        ldy #>prompt_msg
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
; Shared helpers
; ---------------------------------------------------------------------------

; Only ZP_PTR ($FB/$FC) is user-visible state; DST is internal scratch and
; must survive restore_zp because the end address is returned from it.
save_zp:
        lda ZP_PTR
        sta zp_save
        lda ZP_PTR+1
        sta zp_save+1
        rts

restore_zp:
        lda zp_save
        sta ZP_PTR
        lda zp_save+1
        sta ZP_PTR+1
        rts

print_z:
        sta ZP_PTR
        sty ZP_PTR+1
        ldy #0
print_loop:
        lda (ZP_PTR),y
        beq print_done
        jsr CHROUT
        iny
        bne print_loop
print_done:
        rts

print_fail_diag:
        lda #<fail_msg
        ldy #>fail_msg
        jsr print_z
        lda ERRCODE
        jsr print_hex
        lda #' '
        jsr CHROUT
        lda LAST_STAT
        jsr print_hex
        lda #' '
        jsr CHROUT
        lda REQT
        jsr print_hex
        lda #'/'
        jsr CHROUT
        lda REQS
        jsr print_hex
        lda #$0D
        jsr CHROUT
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
        bcc print_digit
        adc #$06
print_digit:
        adc #$30
        jmp CHROUT

.segment "RODATA"
old_load:
        .word $F4A5
install_msg:
        .byte "SD HOOK V3 READY", $0D
        .byte "LOAD", $22, "@", $22, ",8   = DISK MENU", $0D
        .byte "LOAD", $22, "*", $22, ",8,1 = FASTLOAD", $0D, 0
fail_msg:
        .byte "SD FASTLOAD ERR $", 0
menu_hint:
        .byte "NO DISK MOUNTED - USE LOAD", $22, "@", $22, ",8", $0D, 0
menu_title:
        .byte $0D, "SD DISK MENU", $0D, 0
no_sd_msg:
        .byte "SD NOT READY", $0D, 0
no_files_msg:
        .byte "NO D64 FILES FOUND", $0D, 0
scan_err_msg:
        .byte "FAT16 SCAN ERROR $", 0
frag_msg:
        .byte "FILE IS FRAGMENTED - NOT MOUNTED", $0D, 0
found_msg:
        .byte $0D, "D64 IMAGES:", $0D, 0
prompt_msg:
        .byte $0D, "1-9/A-G SELECT, CRSR PAGE, STOP EXIT", $0D, 0
mounted_msg:
        .byte $0D, "MOUNTED: ", 0
usage_msg:
        .byte "NOW USE: LOAD", $22, "$", $22, ",8 / LOAD", $22, "*", $22, ",8,1", $0D, 0

.segment "BSS"
req_addr:   .res 2
verify_flag:.res 1
vartab_save:.res 2
DST:        .res 2
LOADP:      .res 2
FILE_LOAD:  .res 2
REQT:       .res 1
REQS:       .res 1
DIRT:       .res 1
DIRS:       .res 1
CURT:       .res 1
CURS:       .res 1
NEXTT:      .res 1
NEXTS:      .res 1
ENTRY_OFF:  .res 1
OFFSET:     .res 1
ENDOFF:     .res 1
FIRST:      .res 1
TMP:        .res 1
MATCH_POS:  .res 1
WANT_CHAR:  .res 1
ERRCODE:    .res 1
LAST_STAT:  .res 1
WAIT0:      .res 1
WAIT1:      .res 1
zp_save:    .res 2

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

name_tab:   .res MAX_ENTRIES * 16
meta_tab:   .res MAX_ENTRIES * 8
