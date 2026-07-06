; ============================================================
; Mandelbrot Set — 320x200, TRUE COLOUR (RGB565, 65536 colours) from DDR3
; Coprocessor edition: the hardware math coprocessor ($88B0) does the signed
; 8.24 fixed-point multiply.
;
; The "more colours" version: $9000 bit 6 = DDR3 320x200 16bpp RGB565 mode. Two
; bytes per pixel (low = GGGBBBBB, high = RRRRRGGG), so the escape gradient is a
; smooth 64-entry RGB565 palette instead of the coarse 32-entry RGB332 table.
; MAX_ITER is 64 (twice the bands) — together that kills the visible colour
; stepping of the 8bpp versions.
;
;   * $9000 bit 6 = 320x200 16bpp mode (bits 4,5 clear)
;   * $9006 = 5-bit framebuffer bank (0..15); 320*200*2 = 128000 bytes = 16 banks
;   * pixels reached through the banked $6000-$7FFF window, 2 bytes each
;
; Build (split-map application at $A000, vectors at $FFFA):
;   ca65 --cpu 65c02 -o mandelbrot_true.o mandelbrot_true.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../../roms/6502/mandelbrot_true.bin mandelbrot_true.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/mandelbrot_true.bin --split-rom --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000         ; bit6 = DDR3 320x200 16bpp RGB565 (bits 4,5 clear)
VIC_FB_BANK = $9006         ; 5-bit framebuffer bank 0..15
FB_WIN      = $6000         ; banked framebuffer window ($6000-$7FFF)
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Math coprocessor ($88B0..$88BF) ---
MUL         = $88B0
MUL_A       = MUL+0
MUL_B       = MUL+4
MUL_RES     = MUL+8
MUL_SHIFT   = MUL+12

; --- Mandelbrot constants (8.24 fixed-point), sampled at 320x200 ---
; View: real -2.625..+1.125 (width 3.75), imag -1.25..+1.25 (height 2.5).
X_LEFT      = $FD600000     ; -2.625 in 8.24
CI_START    = $FEC00000     ; -1.25  in 8.24
SX_STEP     = $00030000     ; 3.75/320 * 2^24 = 196608
SY_STEP     = $00033333     ; 2.5/200  * 2^24 = 209715
ESCAPE_INT  = $04           ; |z|^2 >= 4.0 -> integer byte (bits 24-31) >= 4
MAX_ITER    = 64

; ============================================================
.segment "ZEROPAGE"
ZR:     .res 4              ; z real      (8.24)
ZI:     .res 4              ; z imaginary
CR:     .res 4              ; c real
CI:     .res 4              ; c imaginary
ZR2:    .res 4              ; zr^2
ZI2:    .res 4              ; zi^2
PROD:   .res 4              ; scratch product (zr*zi)
SUM:    .res 4              ; zr^2 + zi^2
ITER:   .res 1              ; iteration counter (down from MAX_ITER)
PY:     .res 1              ; pixel Y (0-199)
PX:     .res 2              ; pixel X (0-319, 16-bit)
BMPLO:  .res 1              ; framebuffer window pointer low
BMPHI:  .res 1              ; framebuffer window pointer high
BANK:   .res 1             ; current 8 KiB bank 0..15
PIXLO:  .res 1              ; RGB565 low byte for this pixel
PIXHI:  .res 1              ; RGB565 high byte

; ============================================================
; Macros
; ============================================================
.macro LD32I dst, val
    lda #<(val)
    sta dst+0
    lda #>(val)
    sta dst+1
    lda #^(val)
    sta dst+2
    lda #>((val) >> 16)
    sta dst+3
.endmacro

.macro ADD32I dst, val
    clc
    lda dst+0
    adc #<(val)
    sta dst+0
    lda dst+1
    adc #>(val)
    sta dst+1
    lda dst+2
    adc #^(val)
    sta dst+2
    lda dst+3
    adc #>((val) >> 16)
    sta dst+3
.endmacro

; dst = (opA * opB) >> 24, signed, via the hardware coprocessor.
.macro MUL32 opA, opB, dst
    lda opA+0
    sta MUL_A+0
    lda opA+1
    sta MUL_A+1
    lda opA+2
    sta MUL_A+2
    lda opA+3
    sta MUL_A+3
    lda opB+0
    sta MUL_B+0
    lda opB+1
    sta MUL_B+1
    lda opB+2
    sta MUL_B+2
    lda opB+3
    sta MUL_B+3
    lda MUL_RES+0
    sta dst+0
    lda MUL_RES+1
    sta dst+1
    lda MUL_RES+2
    sta dst+2
    lda MUL_RES+3
    sta dst+3
.endmacro

; ============================================================
.segment "CODE"

RESET:
    sei
    ldx #$FF
    txs

    ; --- Configure coprocessor for 8.24 (SHIFT = 24) ---
    lda #24
    sta MUL_SHIFT

    ; --- Enable DDR3 320x200 16bpp mode, bank 0, pointer at $6000 ---
    lda #$40
    sta VIC_MODE
    lda #0
    sta VIC_FB_BANK
    sta BANK
    lda #<FB_WIN
    sta BMPLO
    lda #>FB_WIN
    sta BMPHI

    ; --- Initialise outer loop ---
    LD32I CI, CI_START
    lda #0
    sta PY

; ============================================================
; Main loop: for PY = 0 to 199
; ============================================================
row_loop:
    LD32I CR, X_LEFT
    lda #0
    sta PX+0
    sta PX+1

; --- for PX = 0 to 319 ---
pixel_loop:
    ; --- Mandelbrot iteration: z = 0, iterate z = z^2 + c ---
    lda #0
    sta ZR+0
    sta ZR+1
    sta ZR+2
    sta ZR+3
    sta ZI+0
    sta ZI+1
    sta ZI+2
    sta ZI+3
    lda #MAX_ITER
    sta ITER

iter_loop:
    ; --- ZR2 = ZR * ZR ; ZI2 = ZI * ZI (hardware coprocessor) ---
    MUL32 ZR, ZR, ZR2
    MUL32 ZI, ZI, ZI2

    ; --- SUM = ZR2 + ZI2 ; escape if |z|^2 >= 4.0 ---
    clc
    lda ZR2+0
    adc ZI2+0
    sta SUM+0
    lda ZR2+1
    adc ZI2+1
    sta SUM+1
    lda ZR2+2
    adc ZI2+2
    sta SUM+2
    lda ZR2+3
    adc ZI2+3
    sta SUM+3
    ; The MUL32 macros make the body large, so reach 'escaped' via an abs jmp.
    bpl :+
    jmp escaped             ; defensive: overflow into the sign bit
:
    lda SUM+3
    cmp #ESCAPE_INT
    bcc :+
    jmp escaped
:

    ; --- ZI = 2 * ZR * ZI + CI ---
    MUL32 ZR, ZI, PROD
    asl PROD+0
    rol PROD+1
    rol PROD+2
    rol PROD+3
    clc
    lda PROD+0
    adc CI+0
    sta ZI+0
    lda PROD+1
    adc CI+1
    sta ZI+1
    lda PROD+2
    adc CI+2
    sta ZI+2
    lda PROD+3
    adc CI+3
    sta ZI+3

    ; --- ZR = ZR2 - ZI2 + CR ---
    sec
    lda ZR2+0
    sbc ZI2+0
    sta ZR+0
    lda ZR2+1
    sbc ZI2+1
    sta ZR+1
    lda ZR2+2
    sbc ZI2+2
    sta ZR+2
    lda ZR2+3
    sbc ZI2+3
    sta ZR+3
    clc
    lda ZR+0
    adc CR+0
    sta ZR+0
    lda ZR+1
    adc CR+1
    sta ZR+1
    lda ZR+2
    adc CR+2
    sta ZR+2
    lda ZR+3
    adc CR+3
    sta ZR+3

    ; --- Next iteration ---
    dec ITER
    beq no_escape
    jmp iter_loop

no_escape:
    lda #$00                ; inside the set: black (RGB565 = $0000)
    sta PIXLO
    sta PIXHI
    jmp plot

escaped:
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (0..MAX_ITER-1)
    tax
    lda color_lo,x          ; RGB565 low  byte (GGGBBBBB)
    sta PIXLO
    lda color_hi,x          ; RGB565 high byte (RRRRRGGG)
    sta PIXHI

plot:
    ; write the 16-bit pixel: low byte then high byte at the window pointer
    ldy #0
    lda PIXLO
    sta (BMPLO),y
    iny
    lda PIXHI
    sta (BMPLO),y

    ; advance the window pointer by 2; hop to the next bank when it passes $7FFF
    clc
    lda BMPLO
    adc #2
    sta BMPLO
    bcc chk_bank
    inc BMPHI
chk_bank:
    lda BMPHI
    cmp #$80
    bne no_carry
    lda #>FB_WIN           ; wrap the window back to $6000 ...
    sta BMPHI
    inc BANK              ; ... and select the next 8 KiB bank via $9006
    lda BANK
    sta VIC_FB_BANK
no_carry:

    ; --- Advance CR by SX_STEP ---
    ADD32I CR, SX_STEP

    ; --- PX++ ; loop while PX < 320 ---
    inc PX+0
    bne px_chk
    inc PX+1
px_chk:
    lda PX+1
    beq px_more             ; PX < 256 -> keep going
    lda PX+0                ; PX high == 1: compare low to 320 & $FF = $40
    cmp #<320
    bcc px_more
    jmp row_done
px_more:
    jmp pixel_loop

row_done:
    ; --- Advance CI by SY_STEP ---
    ADD32I CI, SY_STEP

    ; --- Next row ---
    inc PY
    lda PY
    cmp #200
    bcs done
    jmp row_loop

done:
    ; wait for a UART key, then back to text mode
wait_key:
    lda UART_SR
    and #UART_RDRF
    beq wait_key
    lda UART_DATA
    lda #$00
    sta VIC_MODE
halt:
    jmp halt

; ============================================================
.segment "RODATA"

; Smooth 64-entry RGB565 escape gradient (cosine rainbow), split into low/high
; byte tables so the plot code can index each with a single lda ,x. Index =
; iterations used (0 = far, 63 = near the set). Interior pixels are drawn black.
color_lo:
    .byte $08,$C9,$8A,$4C,$0D,$CE,$B0,$71
    .byte $52,$33,$35,$16,$17,$18,$19,$3A
    .byte $3B,$5C,$7D,$BD,$DE,$1E,$3F,$7F
    .byte $DF,$1F,$5F,$BF,$FE,$5E,$9D,$FD
    .byte $5C,$9B,$FA,$59,$98,$F7,$36,$75
    .byte $B3,$F2,$31,$4F,$6E,$AD,$AC,$CA
    .byte $E9,$E8,$E7,$E6,$C5,$C4,$A3,$82
    .byte $62,$21,$E1,$C0,$80,$40,$E0,$A0

color_hi:
    .byte $FA,$F9,$F9,$F9,$F1,$F0,$E8,$E0
    .byte $E0,$D8,$D0,$C8,$C0,$B8,$A8,$A0
    .byte $98,$90,$80,$78,$70,$61,$59,$51
    .byte $49,$3A,$32,$2A,$22,$1B,$1B,$13
    .byte $0C,$0C,$0C,$05,$05,$05,$06,$06
    .byte $06,$0E,$0F,$17,$1F,$1F,$27,$2F
    .byte $37,$3F,$47,$57,$5F,$67,$6F,$7F
    .byte $87,$8F,$9E,$A6,$AE,$B6,$C5,$CD

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
