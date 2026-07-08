; ============================================================
; EhBASIC V2.22 — FPGA HDMI/PS2 port
; ROM segment: $D000-$FFFF (12 KB), placed inside the 16 KB
; shadow ROM ($C000-$FFFF) that the UART monitor loads.
;
; I/O model:
;   VEC_IN  ($E2 ZP BRAM) -> KERNAL_CHRIN_NB ($C009)
;                            reads PS/2 keyboard registers ($8820-$8823)
;   VEC_OUT ($E4 ZP BRAM) -> KERNAL_CHROUT ($C003)
;                            writes to VIC VRAM (VGA)
;                            preserves X, Y; handles $0D->newline, drops $0A
;
; Vectors are in ZP BRAM, NOT page-2 SDRAM.  JMP (VEC_OUT) reads from
; ZP BRAM (single-cycle, no wait states) — avoids SDRAM timing window.
;
; RAM available to BASIC: $0200-$3FFF (~15.5 KB)
;   Ram_top is patched to $4000 by build_fpga_ehbasic.py
;   $0000-$3FFF is on-chip 16 KB BRAM (single-cycle, reliable); $4000-$7FFF is
;   DDR3 and intentionally kept out of BASIC's reach until the bridge is fixed.
;   (above $7FFF: VIC VRAM $8000, VIA $8800, UART $8810, etc.)
;
; Disk commands LOAD/SAVE use the second SD card (data disk).
; LOAD "!" mounts a FAT16-hosted D64 image.  LOAD/SAVE "NAME" then operate on
; that mounted D64.  .BAS is pure tokenized EhBASIC.  .PRG may contain a BASIC
; loader followed by machine code; LOAD adopts the PRG load address and keeps
; the whole file protected below Svar so RUN can start the loader.
;
; Usage: POKE 236,n does nothing. Just SAVE/LOAD.
;
; Build:
;   python tools/build_fpga_ehbasic.py
; Upload + run:
;   python tools/upload_monitor_hex.py tools/roms/fpga_ehbasic_16kb.rom \
;       --port COM15 --baud 230400 --address 0xC000 --run --verbose
; ============================================================

; Kernel jump table (kernel ROM relocated to $F000-$FFFF)
KERNAL_CHROUT   = $F003     ; write char A to VIC text screen
KERNAL_CHRIN    = $F006     ; blocking read + echo (uppercase)
KERNAL_CHRIN_NB = $F009     ; non-blocking: A=char, C=1 ready
KERNAL_CLRSCR   = $F00C     ; clear VIC screen, home cursor
VIC_TEXT_COLOR  = $9003     ; foreground colour for subsequent CHROUT cells
VIC_TEXT_ATTR   = $9005     ; text attributes: bit1 = 80-column mode
VIC_TEXT_80     = $02
VIC_BORDER      = $D020     ; VIC-II border colour  (C64 $D020)
VIC_BACKGROUND  = $D021     ; VIC-II global screen background (C64 $D021)
KERNAL_DISK_MOUNT = $F01E   ; mount first .d64 on SD2  (C=0 ok)
KERNAL_DISK_DIR   = $F021   ; print directory of the mounted image
KERNAL_DISK_LOAD  = $F024   ; load PRG by name; DK_PTR -> name; C=0 ok
KERNAL_DISK_MENU  = $F033   ; interactive .d64 select menu (C=0 mounted, C=1 not)
KERNAL_PENDING_CHAR = $02F7
KERNAL_PENDING_FLAG = $02F8
; Disk scratch in page 2, above EhBASIC's input buffer ($0221-$0268) and below
; the kernel pending-key bytes ($02F7/$02F8).  Keep it outside BASIC RAM
; ($0300-$3FFF), otherwise SAVE would trample the user's program text.
DK_PTR    = $F2
NAMEBUF   = $02D0           ; up to 16 bytes: 15-char filename + null
FS_NAMEL  = $02E1
FS_SLOT   = $02E2
FS_EMPTY  = $02E3
FS_OFF    = $02E4
FS_LENL   = $02E5
FS_LENH   = $02E6
FS_REML   = $02E7
FS_REMH   = $02E8
FS_LBAL   = $02E9
FS_LBAH   = $02EA
FS_CNTL   = $02EB
FS_CNTH   = $02EC
FS_CREATE = $02ED
FS_TMP    = $02EE

D64_IMG0  = $02A0
D64_IMG1  = $02A1
D64_IMG2  = $02A2
D64_IMG3  = $02A3
D64_ABS0  = $02A4
D64_ABS1  = $02A5
D64_ABS2  = $02A6
D64_ABS3  = $02A7
D64_IDX0  = $02A8
D64_IDX1  = $02A9
D64_HALF  = $02AA
D64_TRK   = $02AB
D64_SEC   = $02AC
D64_NEXTT = $02AD
D64_NEXTS = $02AE
D64_DIRT  = $02AF
D64_DIRS  = $02B0
D64_OFF   = $02B1
D64_BLKL  = $02B2
D64_BLKH  = $02B3
D64_FIRSTT = $02B4
D64_FIRSTS = $02B5
D64_STATE = $02B6
D64_TMP   = $02B7
D64_TMP2  = $02B8
D64_CURT  = $02B9
D64_CURS  = $02BA
D64_LAST  = $02BB
D64_DIROFF = $02BC

KERN_DK_STARTL = $0365
KERN_DK_STARTH = $0366
KERN_DK_ENDL   = $0367
KERN_DK_ENDH   = $0368
KERN_DK_MOUNT0 = $0369
KERN_DK_MOUNT1 = $036A
KERN_DK_MOUNT2 = $036B
KERN_DK_MOUNT3 = $036C

SD_CMD     = $88C0
SD_STATUS  = $88C1
SD_LBA0    = $88C2
SD_LBA1    = $88C3
SD_LBA2    = $88C4
SD_LBA3    = $88C5
SD_DATA    = $88C6
SD_DPTR_L  = $88C7
SD_DPTR_H  = $88C8
SDC_READ   = $01
SDC_WRITE  = $02
SDS_BUSY   = $01
SDS_ERROR  = $02
SDS_INIT   = $80

FS_TYPE_BASIC = 'B'
FS_ENTRY_BASE = 16
FS_ENTRY_SIZE = 32
FS_SLOTS      = 8
FS_SLOT_SECT  = 32

; EhBASIC I/O vectors — defined in basic.asm (patched by build_fpga_ehbasic.py
; to ZP BRAM instead of page-2 SDRAM, to avoid T65 JMP-indirect timing bug).
; EhBASIC marks $E2-$EE as "unused"; kernel uses only $F2-$F7.
; VEC_CC=$EA  VEC_IN=$E2  VEC_OUT=$E4  VEC_LD=$E6  VEC_SV=$E8  (after patch)

; IRQ_vec stays at $020D so basic.asm's Ibuffs=IRQ_vec+$14=$0221 (SDRAM
; input buffer) stays correct.  The actual interrupt VECTORS point to
; IRQ_CODE / NMI_CODE which live in ROM — no SDRAM copy needed.
IRQ_vec     = $020D
NMI_FLAG_ZP = $DC
IRQ_FLAG_ZP = $DF

; ============================================================
.segment "EHBASIC"

; ============================================================
; Fixed entry jump table at the very start of EhBASIC ($A000).
; The kernel ROM owns the $FFFA vectors and points them here, so these
; three addresses must stay fixed:
;   $A000 RESET, $A003 IRQ, $A006 NMI.
; ============================================================
ENTRY_TABLE:
    jmp RESET_ENTRY             ; $A000  <- kernel RESET vector
    jmp IRQ_CODE               ; $A003  <- kernel IRQ vector
    jmp NMI_CODE               ; $A006  <- kernel NMI vector

; ============================================================
; RESET_ENTRY — CPU reset lands at $A000 (jmp here).  The kernel is a
; callable library only; it does no boot setup itself.
; ============================================================
RESET_ENTRY:
    sei
    ldx #$FF
    txs                         ; re-init stack (harmless if kernel did it)

    lda #VIC_TEXT_80
    sta VIC_TEXT_ATTR            ; 80x25 text before the screen is cleared

    jsr KERNAL_CLRSCR           ; clear VIC screen

    ; Install EhBASIC I/O vectors in ZP BRAM ($E2-$E9).
    ; ZP writes go to FPGA BRAM — single cycle, no wait states.
    ; LAB_COLD only touches $0200-$0204 (PG2_TABS), so these survive
    ; across EhBASIC cold/warm starts.
    lda #<KERNAL_CHRIN_NB
    sta VEC_IN
    lda #>KERNAL_CHRIN_NB
    sta VEC_IN+1

    lda #<KERNAL_CHROUT
    sta VEC_OUT
    lda #>KERNAL_CHROUT
    sta VEC_OUT+1

    lda #<EHB_DISK_LOAD
    sta VEC_LD
    lda #>EHB_DISK_LOAD
    sta VEC_LD+1

    lda #<EHB_DISK_SAVE
    sta VEC_SV
    lda #>EHB_DISK_SAVE
    sta VEC_SV+1

    ; VEC_CC ($EA ZP BRAM) — CTRL-C check called from BASIC inner loop.
    ; Same T65 JMP-indirect timing fix as VEC_IN/OUT/LD/SV.
    ; The wrapper keeps ordinary input bytes pending so STOP polling
    ; cannot consume them before the line editor sees them.
    lda #<EHB_CTRLC
    sta VEC_CC
    lda #>EHB_CTRLC
    sta VEC_CC+1

    jsr print_boot_banner

    jmp LAB_COLD                ; EhBASIC cold start (never returns)

; Boot banner palette: green border, black screen, light-blue text/rules.
; Ends by leaving light-blue as the default BASIC text colour.
print_boot_banner:
    lda #$05                ; green border
    sta VIC_BORDER
    lda #$00                ; black background
    sta VIC_BACKGROUND

    lda #$0E                ; light blue
    ldx #<ban_rule
    ldy #>ban_rule
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_title
    ldy #>ban_title
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_sys
    ldy #>ban_sys
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_feat
    ldy #>ban_feat
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_rule2
    ldy #>ban_rule2
    jsr banner_seg
    lda #$0E                ; light blue for BASIC text + prompt
    sta VIC_TEXT_COLOR
    rts

; banner_seg: A = colour, X/Y = lo/hi of a null-terminated string.
; The kernel STROUT is unreliable -- its pointer high byte ($EE) aliases nothing
; useful while the indirect load reads $EC, which is CHROUT's own screen-pointer
; scratch -- so we print the bytes ourselves.  CHROUT preserves A/X/Y and only
; clobbers $EC/$ED, so a transient ZP pointer in the disk scratch ($F2/$F3,
; unused until the first LOAD) survives the loop.
BANPTR = $F2
banner_seg:
    sta VIC_TEXT_COLOR
    stx BANPTR
    sty BANPTR+1
    ldy #0
banner_seg_loop:
    lda (BANPTR),y
    beq banner_seg_done
    jsr KERNAL_CHROUT
    iny
    bne banner_seg_loop     ; each banner string is < 256 bytes
banner_seg_done:
    rts

ban_rule:
    .byte $0D, " "
    .repeat 25
    .byte $60
    .endrepeat
    .byte $0D, 0
ban_title:
    .byte "  6502 SBC        ENHANCED BASIC 2.22", $0D, 0
ban_sys:
    .byte "  VIDEO 80x25 TEXT     CPU 65C02/T65     OUTPUT HDMI", $0D, 0
ban_feat:
    .byte "  STORAGE SD DISK      BASIC RAM $0300-$3FFF      KERNEL $F000", $0D, 0
ban_rule2:
    .byte " "
    .repeat 25
    .byte $60
    .endrepeat
    .byte $0D, 0

; ============================================================
; IRQ / NMI handlers — live in ROM (shadow BRAM), not SDRAM.
; $FFFE points here directly; no SDRAM copy needed.
; Update IrqBase/NmiBase (ZP $DF/$DC) flags for EhBASIC's ON IRQ/NMI.
; ============================================================
IRQ_CODE:
    pha
    lda IRQ_FLAG_ZP
    lsr a
    ora IRQ_FLAG_ZP
    sta IRQ_FLAG_ZP
    pla
    rti

NMI_CODE:
    pha
    lda NMI_FLAG_ZP
    lsr a
    ora NMI_FLAG_ZP
    sta NMI_FLAG_ZP
    pla
    rti
IRQ_NMI_CODE_END:   ; (kept for size reference only)

; ============================================================
; EHB_DISK_LOAD / SAVE — D64-backed BASIC disk hooks.
; ============================================================
LD_SRC = $F4               ; short-lived parser pointer; kernel may clobber it
FS_PTRL = $71              ; EhBASIC utility pointer, safe inside disk hooks
FS_PTRH = $72

EHB_DISK_LOAD:
    jsr parse_disk_name
    bcc @name_ok
    jmp disk_error
@name_ok:
    lda NAMEBUF
    cmp #'!'
    bne @not_menu
    lda NAMEBUF+1
    bne @not_menu
    jsr KERNAL_DISK_MENU
    bcs @menu_warm
    jsr KERNAL_DISK_DIR
@menu_warm:
    jmp LAB_WARM
@not_menu:
    lda NAMEBUF
    cmp #'$'
    bne @not_dir
    lda NAMEBUF+1
    bne @not_dir
    jsr KERNAL_DISK_MOUNT
    bcc @dir_mounted
    jmp disk_not_ready
@dir_mounted:
    jsr KERNAL_DISK_DIR
    jmp LAB_WARM
@not_dir:
    jmp d64_load_file

d64_load_file:
    jsr KERNAL_DISK_MOUNT
    bcs @no_d64
    lda #<NAMEBUF
    sta DK_PTR
    lda #>NAMEBUF
    sta DK_PTR+1
    jsr KERNAL_DISK_LOAD
    bcc @ok
    jmp disk_error
@ok:
    lda KERN_DK_STARTL
    sta Smeml
    lda KERN_DK_STARTH
    sta Smemh
    lda KERN_DK_ENDL
    sta Svarl
    lda KERN_DK_ENDH
    sta Svarh
    ldx #0
@basic_msg:
    lda msg_loaded,x
    beq @basic_relink
    jsr KERNAL_CHROUT
    inx
    bne @basic_msg
@basic_relink:
    jmp LAB_1319            ; reset BASIC state and rebuild line links
@no_d64:
    jmp disk_not_ready

; ============================================================
; EHB_DISK_SAVE — Save BASIC text from Smem to Svar
; ============================================================
EHB_DISK_SAVE:
    jsr parse_disk_name
    bcc @name_ok
    jmp disk_error
@name_ok:
    jsr consume_optional_device
    jsr save_force_bas_extension
    sec
    lda Svarl
    sbc Smeml
    sta FS_LENL
    lda Svarh
    sbc Smemh
    sta FS_LENH
    jsr KERNAL_DISK_MOUNT
    bcc @mounted
    jmp disk_not_ready
@mounted:
    jsr d64_save_basic
    bcc @saved
    jmp disk_full
@saved:
    ldx #0
@msg:
    lda msg_saved,x
    beq @done
    jsr KERNAL_CHROUT
    inx
    bne @msg
@done:
    rts

parse_disk_name:
    jsr LAB_EVEX            ; evaluate the "NAME" string expression
    jsr LAB_22B6            ; A=len, X=ptr lo, Y=ptr hi of the string
    stx LD_SRC
    sty LD_SRC+1
    cmp #1
    bcs @has_name
    sec
    rts
@has_name:
    cmp #16
    bcc @len_ok
    lda #15
@len_ok:
    sta FS_NAMEL
    tax
    ldy #0
@copy:
    cpx #0
    beq @done
    lda (LD_SRC),y
    cmp #'a'
    bcc @store
    cmp #'z'+1
    bcs @store
    sec
    sbc #$20
@store:
    sta NAMEBUF,y
    iny
    dex
    jmp @copy
@done:
    lda #0
    sta NAMEBUF,y
    clc
    rts

consume_optional_device:
    jsr LAB_GBYT
    cmp #','
    bne @done
    jsr LAB_IGBY
    jsr LAB_GTBY
@done:
    rts

save_force_bas_extension:
    ldy FS_NAMEL
@scan:
    dey
    bmi @append
    lda NAMEBUF,y
    cmp #'.'
    bne @scan
    rts
@append:
    lda FS_NAMEL
    cmp #12
    bcc @len_ok
    lda #11
@len_ok:
    tax
    lda #'.'
    sta NAMEBUF,x
    inx
    lda #'B'
    sta NAMEBUF,x
    inx
    lda #'A'
    sta NAMEBUF,x
    inx
    lda #'S'
    sta NAMEBUF,x
    inx
    stx FS_NAMEL
    lda #0
    sta NAMEBUF,x
    rts

; ============================================================
; D64 BASIC SAVE support.
; Writes tokenized BASIC as a PRG file named *.BAS into the currently mounted
; D64 image.  The mounted image must be a contiguous .d64 file on the FAT16 SD
; card.
; ============================================================

d64_save_basic:
    jsr d64_get_mount_lba
    jsr d64_find_dir_slot
    bcc @slot_ok
    rts
@slot_ok:
    jsr d64_alloc_sector
    bcc @got_first
    rts
@got_first:
    lda D64_TRK
    sta D64_FIRSTT
    sta D64_CURT
    lda D64_SEC
    sta D64_FIRSTS
    sta D64_CURS
    lda #0
    sta D64_BLKL
    sta D64_BLKH
    sta D64_STATE
    lda Smeml
    sta FS_PTRL
    lda Smemh
    sta FS_PTRH
    lda FS_LENL
    sta FS_REML
    lda FS_LENH
    sta FS_REMH

@block:
    jsr d64_need_next
    bcs @last
    jsr d64_alloc_sector
    bcs @fail
    lda D64_TRK
    sta D64_NEXTT
    lda D64_SEC
    sta D64_NEXTS
    lda #0
    sta D64_LAST
    jmp @write
@last:
    lda #0
    sta D64_NEXTT
    jsr d64_last_index
    sta D64_NEXTS
    lda #1
    sta D64_LAST
@write:
    lda D64_CURT
    sta D64_TRK
    lda D64_CURS
    sta D64_SEC
    jsr d64_prepare_sector_write
    bcs @fail
    lda D64_NEXTT
    sta SD_DATA
    lda D64_NEXTS
    sta SD_DATA
    ldx #254
@payload:
    jsr d64_next_stream_byte
    sta SD_DATA
    dex
    bne @payload
    jsr d64_raw_write_abs
    bcs @fail
    inc D64_BLKL
    bne :+
    inc D64_BLKH
:
    lda D64_LAST
    bne @dir
    lda D64_NEXTT
    sta D64_CURT
    lda D64_NEXTS
    sta D64_CURS
    jmp @block
@dir:
    jsr d64_write_dir_entry
    bcs @fail
    clc
    rts
@fail:
    sec
    rts

d64_get_mount_lba:
    lda KERN_DK_MOUNT0
    sta D64_IMG0
    lda KERN_DK_MOUNT1
    sta D64_IMG1
    lda KERN_DK_MOUNT2
    sta D64_IMG2
    lda KERN_DK_MOUNT3
    sta D64_IMG3
    rts

; Carry clear means another sector is needed after the current block.
; Carry set means this is the last block.
d64_need_next:
    lda D64_STATE
    cmp #2
    beq @prog_only
    lda FS_REMH
    bne @maybe_first_big
    lda FS_REML
    cmp #253                ; first block can hold 252 BASIC bytes + load addr
    bcc @last
@maybe_first_big:
    clc
    rts
@prog_only:
    lda FS_REMH
    bne @more
    lda FS_REML
    cmp #255                ; later blocks can hold 254 BASIC bytes
    bcc @last
@more:
    clc
    rts
@last:
    sec
    rts

d64_last_index:
    lda D64_STATE
    cmp #2
    beq @prog
    lda FS_REML
    clc
    adc #3                  ; payload = load address + remaining BASIC bytes
    rts
@prog:
    lda FS_REML
    clc
    adc #1
    rts

d64_next_stream_byte:
    lda D64_STATE
    beq @load_lo
    cmp #1
    beq @load_hi
    lda FS_REML
    ora FS_REMH
    beq @pad
    ldy #0
    lda (FS_PTRL),y
    inc FS_PTRL
    bne :+
    inc FS_PTRH
:
    dec FS_REML
    lda FS_REML
    cmp #$FF
    bne @done
    dec FS_REMH
@done:
    rts
@load_lo:
    inc D64_STATE
    lda Smeml
    rts
@load_hi:
    inc D64_STATE
    lda Smemh
    rts
@pad:
    lda #0
    rts

; Find an existing directory entry with NAMEBUF, or the first empty entry.
; Returns D64_DIRT/D64_DIRS/D64_OFF set to the slot.
d64_find_dir_slot:
    lda #18
    sta D64_DIRT
    lda #1
    sta D64_DIRS
@sector:
    lda D64_DIRT
    sta D64_TRK
    lda D64_DIRS
    sta D64_SEC
    jsr d64_read_sector_raw
    bcc :+
    rts
:
    lda #2
    sta D64_OFF
    ldx #7
@entry:
    lda D64_OFF
    jsr sd_ptr_a_half
    lda SD_DATA
    beq @use
    cmp #$E5
    beq @use
    and #$07
    cmp #$02
    bne @next
    jsr d64_name_matches
    bcc @use
@next:
    clc
    lda D64_OFF
    adc #32
    sta D64_OFF
    dex
    bne @entry
    jsr sd_ptr0_half
    lda SD_DATA
    beq @full
    sta D64_DIRT
    lda SD_DATA
    sta D64_DIRS
    jmp @sector
@use:
    lda D64_OFF
    sta D64_DIROFF
    clc
    rts
@full:
    sec
    rts

d64_name_matches:
    lda D64_OFF
    clc
    adc #3
    jsr sd_ptr_a_half
    ldy #0
@loop:
    lda NAMEBUF,y
    beq @expect_pad
    sta D64_TMP
    lda SD_DATA
    cmp D64_TMP
    bne @no
    iny
    cpy #16
    bne @loop
    clc
    rts
@expect_pad:
    lda SD_DATA
    cmp #$A0
    bne @no
    iny
    cpy #16
    bne @expect_pad
    clc
    rts
@no:
    sec
    rts

d64_write_dir_entry:
    lda D64_DIRT
    sta D64_TRK
    lda D64_DIRS
    sta D64_SEC
    jsr d64_prepare_sector_write
    bcc :+
    rts
:
    lda D64_DIROFF
    jsr sd_ptr_a_half
    lda #$82
    sta SD_DATA
    lda D64_FIRSTT
    sta SD_DATA
    lda D64_FIRSTS
    sta SD_DATA
    ldy #0
@name:
    cpy FS_NAMEL
    bcs @pad_name
    lda NAMEBUF,y
    jmp @store_name
@pad_name:
    lda #$A0
@store_name:
    sta SD_DATA
    iny
    cpy #16
    bne @name
    lda #0
    ldx #11
@pad:
    sta SD_DATA
    dex
    bne @pad
    lda D64_BLKL
    sta SD_DATA
    lda D64_BLKH
    sta SD_DATA
    jmp d64_raw_write_abs

d64_alloc_sector:
    lda #18
    sta D64_TRK
    lda #0
    sta D64_SEC
    jsr d64_prepare_sector_write
    bcc :+
    rts
:
    lda #1
    sta D64_TRK
@track:
    lda D64_TRK
    cmp #36
    bcs @fail
    cmp #18
    beq @next_track
    jsr d64_bam_base
    lda D64_OFF
    jsr sd_ptr_a_half
    lda SD_DATA
    beq @next_track
    lda #0
    sta D64_SEC
@sec:
    jsr d64_sectors_per_track
    cmp D64_SEC
    beq @next_track
    jsr d64_bam_byte_mask
    lda D64_OFF
    jsr sd_ptr_a_half
    lda SD_DATA
    sta D64_TMP2
    lda D64_TMP2
    and D64_TMP
    bne @take
    inc D64_SEC
    jmp @sec
@take:
    lda D64_TMP2
    eor D64_TMP
    sta D64_TMP2
    lda D64_OFF
    jsr sd_ptr_a_half
    lda D64_TMP2
    sta SD_DATA
    jsr d64_bam_base
    lda D64_OFF
    jsr sd_ptr_a_half
    lda SD_DATA
    sec
    sbc #1
    sta D64_TMP2
    lda D64_OFF
    jsr sd_ptr_a_half
    lda D64_TMP2
    sta SD_DATA
    jsr d64_raw_write_abs  ; write BAM back
    clc
    rts
@next_track:
    inc D64_TRK
    jmp @track
@fail:
    sec
    rts

d64_bam_base:
    lda D64_TRK
    sec
    sbc #1
    asl
    asl
    clc
    adc #4
    sta D64_OFF
    rts

d64_bam_byte_mask:
    lda D64_SEC
    lsr
    lsr
    lsr
    clc
    adc D64_OFF
    adc #1
    sta D64_OFF
    lda D64_SEC
    and #7
    tax
    lda d64_bit,x
    sta D64_TMP
    rts

d64_sectors_per_track:
    lda D64_TRK
    cmp #18
    bcc @t21
    cmp #25
    bcc @t19
    cmp #31
    bcc @t18
    lda #17
    rts
@t21:
    lda #21
    rts
@t19:
    lda #19
    rts
@t18:
    lda #18
    rts

d64_read_sector_raw:
    jsr d64_calc_abs
    jsr d64_raw_read_abs
    bcs @fail
    jmp sd_ptr0_half
@fail:
    rts

d64_prepare_sector_write:
    jsr d64_calc_abs
    jsr d64_raw_read_abs
    bcs @fail
    jmp sd_ptr0_half
@fail:
    rts

d64_calc_abs:
    lda D64_SEC
    sta D64_IDX0
    lda #0
    sta D64_IDX1
    lda D64_TRK
    cmp #18
    bcs @r2
    sec
    sbc #1
    tax
    lda #21
    jsr d64_add_ax
    jmp @done_index
@r2:
    cmp #25
    bcs @r3
    lda #<357
    sta D64_IDX0
    lda #>357
    sta D64_IDX1
    lda D64_TRK
    sec
    sbc #18
    tax
    lda #19
    jsr d64_add_ax
    clc
    lda D64_IDX0
    adc D64_SEC
    sta D64_IDX0
    bcc @done_index
    inc D64_IDX1
    jmp @done_index
@r3:
    cmp #31
    bcs @r4
    lda #<490
    sta D64_IDX0
    lda #>490
    sta D64_IDX1
    lda D64_TRK
    sec
    sbc #25
    tax
    lda #18
    jsr d64_add_ax
    clc
    lda D64_IDX0
    adc D64_SEC
    sta D64_IDX0
    bcc @done_index
    inc D64_IDX1
    jmp @done_index
@r4:
    lda #<598
    sta D64_IDX0
    lda #>598
    sta D64_IDX1
    lda D64_TRK
    sec
    sbc #31
    tax
    lda #17
    jsr d64_add_ax
    clc
    lda D64_IDX0
    adc D64_SEC
    sta D64_IDX0
    bcc @done_index
    inc D64_IDX1
@done_index:
    lda D64_IDX0
    and #1
    sta D64_HALF
    lsr D64_IDX1
    ror D64_IDX0
    clc
    lda D64_IMG0
    adc D64_IDX0
    sta D64_ABS0
    lda D64_IMG1
    adc D64_IDX1
    sta D64_ABS1
    lda D64_IMG2
    adc #0
    sta D64_ABS2
    lda D64_IMG3
    adc #0
    sta D64_ABS3
    rts

d64_add_ax:
    sta D64_TMP
    cpx #0
    beq @done
@loop:
    clc
    lda D64_IDX0
    adc D64_TMP
    sta D64_IDX0
    bcc :+
    inc D64_IDX1
:
    dex
    bne @loop
@done:
    rts

d64_raw_read_abs:
    jsr d64_set_abs_lba
    lda #SDC_READ
    sta SD_CMD
    jsr sd_wait
    bcs @fail
    jsr sd_ptr0
    clc
    rts
@fail:
    sec
    rts

d64_raw_write_abs:
    jsr d64_set_abs_lba
    lda #SDC_WRITE
    sta SD_CMD
    jmp sd_wait

d64_set_abs_lba:
    lda D64_ABS0
    sta SD_LBA0
    lda D64_ABS1
    sta SD_LBA1
    lda D64_ABS2
    sta SD_LBA2
    lda D64_ABS3
    sta SD_LBA3
    rts

sd_ptr0_half:
    lda #0
sd_ptr_a_half:
    sta SD_DPTR_L
    lda D64_HALF
    sta SD_DPTR_H
    rts

d64_bit:
    .byte $01,$02,$04,$08,$10,$20,$40,$80

sd_wait:
    ldx #0
    ldy #0
@poll:
    lda SD_STATUS
    cmp #$FF
    beq @fail
    and #SDS_INIT
    beq @fail
    lda SD_STATUS
    and #SDS_BUSY
    beq @not_busy
    inx
    bne @poll
    iny
    bne @poll
@fail:
    sec
    rts
@not_busy:
    lda SD_STATUS
    and #SDS_ERROR
    bne @fail
    clc
    rts

sd_ptr0:
    lda #0
    sta SD_DPTR_L
    sta SD_DPTR_H
    rts

disk_not_ready:
    ldx #0
@lp:
    lda msg_not_ready,x
    beq @dn
    jsr KERNAL_CHROUT
    inx
    bne @lp
@dn:
    rts

disk_error:
    ldx #0
@lp:
    lda msg_disk_err,x
    beq @dn
    jsr KERNAL_CHROUT
    inx
    bne @lp
@dn:
    rts

disk_full:
    ldx #0
@lp:
    lda msg_disk_full,x
    beq @dn
    jsr KERNAL_CHROUT
    inx
    bne @lp
@dn:
    rts

msg_not_ready:
    .byte $0D, "?SD2 NOT READY", $0D, $00
msg_disk_err:
    .byte $0D, "?FILE NOT FOUND", $0D, $00
msg_loaded:
    .byte $0D, "LOADED", $0D, $00
msg_saved:
    .byte $0D, "SAVED", $0D, $00
msg_disk_full:
    .byte $0D, "?DISK FULL", $0D, $00

; ============================================================
; EHB_CTRLC — EhBASIC STOP/Ctrl-C poll hook.
; The stock handler reads VEC_IN and consumes every non-Ctrl-C byte while
; BASIC is polling.  Put normal bytes back for the real input loop.
; ============================================================
EHB_CTRLC:
    lda KERNAL_PENDING_FLAG
    bne ehb_ctrlc_done
    jsr KERNAL_CHRIN_NB
    bcc ehb_ctrlc_done
    cmp #$03
    beq ehb_ctrlc_stop
    sta KERNAL_PENDING_CHAR
    lda #1
    sta KERNAL_PENDING_FLAG
ehb_ctrlc_done:
    rts
ehb_ctrlc_stop:
    lda #$03
    jmp LAB_1636

; ============================================================
; EhBASIC V2.22 source (patched by build_fpga_ehbasic.py)
; ============================================================
.include "basic.asm"

; ============================================================
; The 6502 interrupt vectors ($FFFA-$FFFF) now live in the KERNEL ROM
; ($F000-$FFFF) and point at the fixed ENTRY_TABLE above
; ($A000/$A003/$A006).  EhBASIC therefore no longer defines a VECTORS
; segment.
; ============================================================
