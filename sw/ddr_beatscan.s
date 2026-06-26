; ============================================================
; DDR3 read-beat scanner (UART report)
;
; The nand2mario controller returns a BL8 read as 8 words (dout128); which beat
; carries the addressed word is board/calibration dependent (dq_in[0] on his
; board, dq_in[4] in sim). Needs vic_fb_ddr3 built with DBG_BEAT_SCAN=true: a
; CPU read then ignores the VIC_MODE bank bits for the word ADDRESS (every bank
; reads word 0) but returns beat = bank number.
;
; A BL8 read of word 0 returns words 0..7 spread across the 8 beats. So we first
; write 8 DISTINCT values C0..C7 to words 0..7, then read beats 0..7 and print
; them. Now every beat has a known expected value:
;   - beats show some permutation of C0..C7  -> writes work, find the beat that
;     reads C0: that beat index is the correct RD_BEAT (word 0 lands there).
;   - beats show garbage (no clean C0..C7)   -> writes are NOT landing; the
;     problem is write leveling / DM masking, not the read lane.
;
; Build:
;   ca65 --cpu 65c02 -o ddr_beatscan.o ddr_beatscan.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/ddr_beatscan.rom ddr_beatscan.o
; ============================================================

VIC_MODE  = $9000
UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10
FB_WIN    = $6000

.segment "ZEROPAGE"
SPTR:   .res 2
BANK:   .res 1

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; write C0..C7 to words 0..7 (bank 0; offset = word in DBG_BEAT_SCAN)
    lda #$00
    sta VIC_MODE
    ldx #0
wr: txa
    ora #$C0               ; value = $C0 + index
    sta FB_WIN,x
    inx
    cpx #8
    bne wr

    ; scan beats 0..7 (bank bits select the beat in DBG_BEAT_SCAN builds)
    lda #0
    sta BANK
scan:
    lda BANK
    asl
    asl
    asl
    asl
    asl
    sta VIC_MODE           ; bank -> VIC_MODE bits 5-7 -> beat select
    lda BANK
    clc
    adc #'0'
    jsr putc               ; print beat index 0..7
    lda #'='
    jsr putc
    lda FB_WIN+0           ; read word 0, returns selected beat
    jsr puthex
    lda #' '
    jsr putc
    inc BANK
    lda BANK
    cmp #8
    bne scan

    lda #$0D
    jsr putc
    ldx #<msg_foot
    ldy #>msg_foot
    jsr putstr

    lda #$00
    sta VIC_MODE
halt:
    jmp halt

; ---- UART helpers ----
putc:
    pha
pw: lda UART_SR
    and #UART_TDRE
    beq pw
    pla
    sta UART_DATA
    rts

puthex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr hexdig
    pla
    and #$0F
    jsr hexdig
    rts
hexdig:
    and #$0F
    cmp #10
    bcc :+
    clc
    adc #('A'-10-'0')
:   clc
    adc #'0'
    jmp putc

putstr:
    stx SPTR
    sty SPTR+1
    ldy #0
ps: lda (SPTR),y
    beq psd
    jsr putc
    iny
    bne ps
psd:
    rts

.segment "RODATA"
msg_hdr:  .byte $0D, "DDR3 BEAT SCAN wrote words0-7=C0..C7", $0D, $00
msg_foot: .byte "beat reading C0 -> RD_BEAT; garbage -> writes fail", $0D, $00

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
