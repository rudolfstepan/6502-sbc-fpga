; ============================================================
; Mandelbrot Set — 320x240 FULL SCREEN, TRUE COLOUR (RGB565) from DDR3
; Coprocessor edition ($88B0), 8.24 fixed-point.
;
; Same as mandelbrot_true but full height: $9007 bit 0 = 1 turns the 320-wide
; framebuffer into 240 lines (2x = 480 = the whole active area, no top/bottom
; border). The view keeps the horizontal scale and extends imag to -1.5..+1.5 so
; the extra 40 rows show more of the plane instead of stretching it.
;
;   * $9000 bit 6 = 320x200/240 16bpp RGB565 mode
;   * $9007 bit 0 = full height (240 lines)
;   * $9006 = 5-bit bank (0..18); 320*240*2 = 153600 bytes = 19 banks
;
; Build (split-map application at $A000, vectors at $FFFA):
;   ca65 --cpu 65c02 -o mandelbrot_true240.o mandelbrot_true240.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../../roms/6502/mandelbrot_true240.bin mandelbrot_true240.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/mandelbrot_true240.bin --split-rom --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000         ; bit6 = 16bpp RGB565
VIC_FB_BANK = $9006         ; 5-bit framebuffer bank 0..18
VIC_FB_CTRL = $9007         ; bit0 = full height (240 lines)
FB_WIN      = $6000
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Math coprocessor ($88B0..$88BF) ---
MUL         = $88B0
MUL_A       = MUL+0
MUL_B       = MUL+4
MUL_RES     = MUL+8
MUL_SHIFT   = MUL+12

; --- Mandelbrot constants (8.24 fixed-point), sampled at 320x240 ---
; View: real -2.625..+1.125 (width 3.75), imag -1.5..+1.5 (height 3.0, 240 rows).
X_LEFT      = $FD600000     ; -2.625 in 8.24
CI_START    = $FE800000     ; -1.5   in 8.24
SX_STEP     = $00030000     ; 3.75/320 * 2^24 = 196608
SY_STEP     = $00033333     ; 0.0125 * 2^24 = 209715 (same scale as the 200-line view)
ESCAPE_INT  = $04
MAX_ITER    = 64

; ============================================================
.segment "ZEROPAGE"
ZR:     .res 4
ZI:     .res 4
CR:     .res 4
CI:     .res 4
ZR2:    .res 4
ZI2:    .res 4
PROD:   .res 4
SUM:    .res 4
ITER:   .res 1
PY:     .res 1              ; pixel Y (0-239)
PX:     .res 2              ; pixel X (0-319, 16-bit)
BMPLO:  .res 1
BMPHI:  .res 1
BANK:   .res 1
PIXLO:  .res 1
PIXHI:  .res 1

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

    lda #24
    sta MUL_SHIFT

    ; --- Enable 320x240 full-height 16bpp mode, bank 0, pointer at $6000 ---
    lda #$40
    sta VIC_MODE
    lda #$01
    sta VIC_FB_CTRL         ; full height (240 lines)
    lda #0
    sta VIC_FB_BANK
    sta BANK
    lda #<FB_WIN
    sta BMPLO
    lda #>FB_WIN
    sta BMPHI

    LD32I CI, CI_START
    lda #0
    sta PY

; ============================================================
row_loop:
    LD32I CR, X_LEFT
    lda #0
    sta PX+0
    sta PX+1

pixel_loop:
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
    MUL32 ZR, ZR, ZR2
    MUL32 ZI, ZI, ZI2

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
    bpl :+
    jmp escaped
:
    lda SUM+3
    cmp #ESCAPE_INT
    bcc :+
    jmp escaped
:

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

    dec ITER
    beq no_escape
    jmp iter_loop

no_escape:
    lda #$00                ; inside the set: black
    sta PIXLO
    sta PIXHI
    jmp plot

escaped:
    lda #MAX_ITER
    sec
    sbc ITER
    tax
    lda color_lo,x
    sta PIXLO
    lda color_hi,x
    sta PIXHI

plot:
    ldy #0
    lda PIXLO
    sta (BMPLO),y
    iny
    lda PIXHI
    sta (BMPLO),y

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
    lda #>FB_WIN
    sta BMPHI
    inc BANK
    lda BANK
    sta VIC_FB_BANK
no_carry:

    ADD32I CR, SX_STEP

    inc PX+0
    bne px_chk
    inc PX+1
px_chk:
    lda PX+1
    beq px_more
    lda PX+0
    cmp #<320
    bcc px_more
    jmp row_done
px_more:
    jmp pixel_loop

row_done:
    ADD32I CI, SY_STEP

    inc PY
    lda PY
    cmp #240
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
    lda #$00
    sta VIC_FB_CTRL         ; back to 200-line default
halt:
    jmp halt

; ============================================================
.segment "RODATA"

; Smooth 64-entry RGB565 escape gradient (cosine rainbow), split low/high.
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
