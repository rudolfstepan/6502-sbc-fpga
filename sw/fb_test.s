; ============================================================
; DDR3 framebuffer smoke test — 320x200 8bpp (RGB332)
;
; Fills the whole framebuffer with a fast diagonal gradient (colour = X xor Y),
; no Mandelbrot maths. Purpose: isolate the display/DDR3 path from the demo.
;   * pattern visible  -> fb display + DDR3 read/write + bank switching all work
;   * screen black      -> DDR3 not calibrated or read/write protocol wrong
;
; Build:
;   ca65 --cpu 65c02 -o fb_test.o fb_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/fb_test.rom fb_test.o
; ============================================================

VIC_MODE    = $9000
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

FB_WIN      = $6000
FB_MODE     = $10

.segment "ZEROPAGE"
PY:     .res 1
CXLO:   .res 1
CXHI:   .res 1
PHYSLO: .res 1
PHYSHI: .res 1
BANK:   .res 1

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    lda #FB_MODE            ; fb display on, bank 0
    sta VIC_MODE

    lda #<FB_WIN
    sta PHYSLO
    lda #>FB_WIN
    sta PHYSHI
    lda #0
    sta BANK
    sta PY

row:
    lda #0
    sta CXLO
    sta CXHI

col:
    ; colour = (CXLO xor PY) — diagonal bands across all 256 RGB332 values
    lda CXLO
    eor PY
    ldy #0
    sta (PHYSLO),y

    ; advance framebuffer pointer, bank every 8 KB
    inc PHYSLO
    bne adv
    inc PHYSHI
    lda PHYSHI
    cmp #$80
    bne adv
    lda #>FB_WIN
    sta PHYSHI
    inc BANK
    lda BANK
    asl
    asl
    asl
    asl
    asl
    ora #FB_MODE
    sta VIC_MODE
adv:

    inc CXLO
    bne :+
    inc CXHI
:
    lda CXHI
    cmp #>320
    bne col
    lda CXLO
    cmp #<320
    bne col

    inc PY
    lda PY
    cmp #200
    bcc row

done:
    lda UART_SR
    and #UART_RDRF
    beq done
    lda UART_DATA
    lda #$00
    sta VIC_MODE
halt:
    jmp halt

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
