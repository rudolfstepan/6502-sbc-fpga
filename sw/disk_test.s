; disk_test.s — D64 GoDrive exerciser ROM for the FPGA SBC.
;
; Standalone 16 KB split-map ROM; build + upload with:
;   make -C sw disk-test
;   python tools/upload_monitor_hex.py sw/disk_test.rom --split-rom --run
;
; It mounts the first .d64 on SD2, peeks the BAM (T18/S0), lists the directory,
; and loads the first tune PRG by name — printing each step to the UART so a
; captured log shows the drive working end to end.

.include "disk.inc"

; routines + shared data exported by disk.s
.import disk_mount, disk_read_sector, disk_dir_open, disk_dir_next
.import disk_entry_is_prg, disk_load_prg_by_name
.importzp dsk_ptr, dsk_dst
.import dsk_entry, dsk_end, dsk_start

UART_DATA   = $8810
UART_STATUS = $8811
UART_TDRE   = $10

.segment "ZEROPAGE"
; (disk.s owns dsk_ptr/dsk_dst/dsk_blocks/dsk_tmp; we add our own scratch)
tmp_x:  .res 1

.segment "CODE"

reset:
    sei
    cld
    ldx #$FF
    txs

    ldx #<msg_banner
    ldy #>msg_banner
    jsr puts

    ; ── mount the first .d64 on SD2 ──────────────────────────────────────────
    ldx #<msg_mount
    ldy #>msg_mount
    jsr puts
    jsr disk_mount
    bcc @mounted
    ldx #<msg_fail
    ldy #>msg_fail
    jsr puts
    jsr print_result
    jmp halt
@mounted:
    ldx #<msg_ok
    ldy #>msg_ok
    jsr puts

    ; ── read T18/S0 (BAM) and dump first 16 bytes ────────────────────────────
    ldx #<msg_bam
    ldy #>msg_bam
    jsr puts
    lda #18
    ldx #0
    jsr disk_read_sector
    bcs @rerr
    jsr dump16
    jmp @dir
@rerr:
    ldx #<msg_fail
    ldy #>msg_fail
    jsr puts
    jsr print_result

    ; ── directory listing ────────────────────────────────────────────────────
@dir:
    ldx #<msg_dir
    ldy #>msg_dir
    jsr puts
    jsr disk_dir_open
    bcs @dirdone
@dnext:
    jsr disk_dir_next
    bcs @dirdone
    jsr print_entry
    jmp @dnext
@dirdone:

    ; ── load the first tune PRG by name ──────────────────────────────────────
    ldx #<msg_load
    ldy #>msg_load
    jsr puts
    lda #<name_test
    sta dsk_ptr
    lda #>name_test
    sta dsk_ptr+1
    jsr disk_load_prg_by_name
    bcc @loaded
    ldx #<msg_fail
    ldy #>msg_fail
    jsr puts
    jmp halt
@loaded:
    ldx #<msg_loadok
    ldy #>msg_loadok
    jsr puts
    ; print start and end address
    lda dsk_start+1
    jsr print_hex
    lda dsk_start
    jsr print_hex
    lda #'-'
    jsr putc
    lda dsk_end+1
    jsr print_hex
    lda dsk_end
    jsr print_hex
    jsr crlf

    ldx #<msg_done
    ldy #>msg_done
    jsr puts

halt:
    jmp halt

; ── dump16: print first 16 bytes of the sector buffer as hex ────────────────
dump16:
    lda #0
    ; fall through to dump16_at with A=0
; ── dump16_at: seek the buffer pointer to A, then print 16 hex bytes ─────────
dump16_at:
    sta DISK_PTR_LO
    ldx #16
@loop:
    lda DISK_DATA
    jsr print_hex
    lda #' '
    jsr putc
    dex
    bne @loop
    jmp crlf

; ── print_entry: print one directory entry "  nn PRG NAME" ──────────────────
print_entry:
    lda #' '
    jsr putc
    lda #' '
    jsr putc
    lda dsk_entry+DE_SIZE_LO
    jsr print_hex
    lda #' '
    jsr putc
    jsr disk_entry_is_prg
    bcs @notprg
    ldx #<lbl_prg
    ldy #>lbl_prg
    jsr puts
    jmp @name
@notprg:
    ldx #<lbl_other
    ldy #>lbl_other
    jsr puts
@name:
    ; print the 16-char name, stop at $A0 padding
    ldy #0
@nloop:
    lda dsk_entry+DE_NAME,y
    cmp #$A0
    beq @ndone
    jsr putc
    iny
    cpy #16
    bne @nloop
@ndone:
    jmp crlf

; ── print_result: "RESULT=xx" + CRLF ────────────────────────────────────────
print_result:
    ldx #<msg_result
    ldy #>msg_result
    jsr puts
    lda DISK_RESULT
    jsr print_hex
    jmp crlf

; ── UART helpers ────────────────────────────────────────────────────────────
; puts: print zero-terminated string at X=lo, Y=hi
puts:
    stx dsk_ptr
    sty dsk_ptr+1
    ldy #0
@loop:
    lda (dsk_ptr),y
    beq @end
    jsr putc
    iny
    bne @loop
@end:
    rts

putc:
    pha
@wait:
    lda UART_STATUS
    and #UART_TDRE
    beq @wait
    pla
    sta UART_DATA
    rts

crlf:
    lda #13
    jsr putc
    lda #10
    jmp putc

; print_hex: print A as two hex digits
print_hex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr @nyb
    pla
    and #$0F
@nyb:
    and #$0F
    cmp #10
    bcc @dig
    adc #'A'-10-1          ; carry set adds 1 already
    jmp putc
@dig:
    adc #'0'
    jmp putc

.segment "RODATA"
msg_banner: .byte "D64 GODRIVE TEST", 13, 10, 0
msg_mount:  .byte "MOUNT: ", 0
msg_ok:     .byte "OK", 13, 10, 0
msg_fail:   .byte "FAIL ", 0
msg_result: .byte "RESULT=", 0
msg_bam:    .byte "BAM T18/S0: ", 0
msg_dir:    .byte "DIR:", 13, 10, 0
msg_load:   .byte "LOAD: ", 0
msg_loadok: .byte "OK ", 0
msg_done:   .byte "DONE", 13, 10, 0
lbl_prg:    .byte "PRG ", 0
lbl_other:  .byte "??? ", 0
name_test:  .byte "ZOIDS", 0

.segment "VECTORS"
    .word reset            ; NMI
    .word reset            ; RESET
    .word reset            ; IRQ
