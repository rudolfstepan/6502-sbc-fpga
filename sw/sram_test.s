; ============================================================
; $4000-$5FFF RAM self-test (UART report)
;
; Verifies the 8 KB "SRAM" region (bram_byte_bridge on the BSRAM build) that
; SID tunes like Commando ($5000) load into. Writes a pattern, reads it back,
; reports PASS/FAIL + first failing address over UART.
;
; Build:
;   ca65 --cpu 65c02 -o sram_test.o sram_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/sram_test.rom sram_test.o
; ============================================================

UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10

RAM_LO = $4000
RAM_HI = $6000          ; one past the region

.segment "ZEROPAGE"
PTR:    .res 2
ERRLO:  .res 1
ERRHI:  .res 1
GOTF:   .res 1
FALO:   .res 1
FAHI:   .res 1
FGOT:   .res 1
SPTR:   .res 2

.segment "CODE"
RESET:
    sei
    cld
    ldx #$FF
    txs

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; ---- write pass: value = low byte of address ----
    lda #<RAM_LO
    sta PTR
    lda #>RAM_LO
    sta PTR+1
w0: ldy #0
    lda PTR             ; value = addr low byte
    sta (PTR),y
    inc PTR
    bne wnc
    inc PTR+1
wnc:
    lda PTR+1
    cmp #>RAM_HI
    bne w0

    ; ---- read/verify pass ----
    lda #0
    sta ERRLO
    sta ERRHI
    sta GOTF
    lda #<RAM_LO
    sta PTR
    lda #>RAM_LO
    sta PTR+1
r0: ldy #0
    lda (PTR),y
    cmp PTR             ; expected = addr low byte
    beq rok
    ; error
    inc ERRLO
    bne re1
    inc ERRHI
re1:
    lda GOTF
    bne rok
    lda #1
    sta GOTF
    lda PTR
    sta FALO
    lda PTR+1
    sta FAHI
    lda (PTR),y
    sta FGOT
rok:
    inc PTR
    bne rnc
    inc PTR+1
rnc:
    lda PTR+1
    cmp #>RAM_HI
    bne r0

    ; ---- report ----
    ldx #<msg_errs
    ldy #>msg_errs
    jsr putstr
    lda ERRHI
    jsr puthex
    lda ERRLO
    jsr puthex
    lda #$0D
    jsr putc

    lda ERRLO
    ora ERRHI
    beq allok
    ldx #<msg_first
    ldy #>msg_first
    jsr putstr
    lda FAHI
    jsr puthex
    lda FALO
    jsr puthex
    lda #' '
    jsr putc
    lda #'G'
    jsr putc
    lda FGOT
    jsr puthex
    lda #$0D
    jsr putc
    jmp done
allok:
    ldx #<msg_ok
    ldy #>msg_ok
    jsr putstr
done:
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
msg_hdr:   .byte $0D, "SRAM $4000-$5FFF TEST", $0D, $00
msg_errs:  .byte "ERRS=", $00
msg_first: .byte "FIRST@", $00
msg_ok:    .byte "ALL OK", $0D, $00

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
