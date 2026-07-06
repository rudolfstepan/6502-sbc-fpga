; ============================================================
; 320x240 16-colour framebuffer test (color16_mode, VIC bit 4)
;
; Fills the whole 38400-byte framebuffer with 16 vertical colour bars
; (20 px each) so you can verify, in one shot:
;   - the new 320x240 4bpp mode displays at all,
;   - the 16-colour palette (indices 0..15 left to right),
;   - nibble unpack (two pixels per byte: low nibble = even x, high = odd x),
;   - the 5-bank $6000 window addressing (vic_mode_reg bits 7:5).
;
; Pixel mapping: byte = y*160 + x/2; even x -> low nibble, odd x -> high nibble.
; Because each bar is 20 px (even) wide, both pixels in a byte share a colour,
; so each line is the 160-byte pattern: bytes 0..9 = $00, 10..19 = $11, ...,
; 150..159 = $FF (colour c in byte = c*$11). Every line is identical.
;
; Build:
;   ca65 --cpu 65c02 -o fb16_test.o fb16_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/fb16_test.rom fb16_test.o
; ============================================================

VIC_MODE = $9000
FB_WIN   = $6000
FB_END   = $8000          ; one past the 8 KB window
MODE16   = $11            ; bit0 = bitmap, bit4 = 320x240 16-colour, bank 0

.segment "ZEROPAGE"
PTR:  .res 2              ; current write pointer inside the $6000 window
COL:  .res 1             ; line column 0..159 (index into linepat)
BANK: .res 1             ; current 8 KB bank 0..4
CLO:  .res 1             ; bytes-left-in-bank low
CHI:  .res 1             ; bytes-left-in-bank high

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    lda #0
    sta COL
    sta BANK

bankloop:
    ; VIC_MODE = MODE16 | (BANK << 5)
    lda BANK
    asl
    asl
    asl
    asl
    asl
    ora #MODE16
    sta VIC_MODE

    ; PTR = $6000
    lda #<FB_WIN
    sta PTR
    lda #>FB_WIN
    sta PTR+1

    ; bytes in this bank: banks 0..3 = 8192 ($2000); bank 4 = 5632 ($1600)
    lda BANK
    cmp #4
    beq lastbank
    lda #$00
    sta CLO
    lda #$20
    sta CHI
    jmp byteloop
lastbank:
    lda #$00
    sta CLO
    lda #$16
    sta CHI

byteloop:
    ; write the pattern byte for this column
    ldx COL
    lda linepat,x
    ldy #0
    sta (PTR),y

    ; COL = (COL + 1) mod 160
    inx
    cpx #160
    bne colok
    ldx #0
colok:
    stx COL

    ; PTR++
    inc PTR
    bne ptrok
    inc PTR+1
ptrok:

    ; bytes-left-- (16-bit), continue while != 0
    lda CLO
    sec
    sbc #1
    sta CLO
    lda CHI
    sbc #0
    sta CHI
    lda CLO
    ora CHI
    bne byteloop

    ; next bank
    inc BANK
    lda BANK
    cmp #5
    bne bankloop

    ; leave display in 320x240 16-colour mode, bank 0 for tidy CPU reads
    lda #MODE16
    sta VIC_MODE
halt:
    jmp halt

.segment "RODATA"
; 160-byte line pattern: byte i carries colour (i/10) in both nibbles.
linepat:
.repeat 160, I
    .byte (I / 10) * $11
.endrepeat

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
