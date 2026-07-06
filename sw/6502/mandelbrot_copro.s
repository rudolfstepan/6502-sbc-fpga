; ============================================================
; Mandelbrot Set — 320x200, 256 colours (RGB332) from DDR3
; Coprocessor edition: the hardware math coprocessor ($88B0) does the signed
; 8.24 fixed-point multiply (four writes + four reads instead of shift-add fpmul).
;
; Ported from the old 180x120 packed-RGB222 (color64) version to the DDR3
; framebuffer: $9000 bit 4 = DDR3 320x200 8bpp mode, bits 7:5 = 8 KiB bank; one
; RGB332 colour byte per pixel into the banked $6000-$7FFF window. The 8.24
; escape maths and the MUL32 coprocessor macro are unchanged.
;
; Build (split-map application at $A000, vectors at $FFFA):
;   ca65 --cpu 65c02 -o mandelbrot_copro.o mandelbrot_copro.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../../roms/6502/mandelbrot_copro.bin mandelbrot_copro.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/mandelbrot_copro.bin --split-rom --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000         ; bit4 = DDR3 320x200 8bpp, bits7:5 = 8 KiB bank
FB_WIN      = $6000         ; banked framebuffer window ($6000-$7FFF)
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Math coprocessor ($88B0..$88BF) ---
;   +0..3  W operand A (32-bit signed)   +4..7 W operand B
;   +8..B  R result = (A*B) >> SHIFT (8.24)     +C  W SHIFT (default 24)
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
MAX_ITER    = 32

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
BANK:   .res 1             ; current 8 KiB bank 0..7

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

    ; --- Enable DDR3 320x200 8bpp mode, bank 0, pointer at $6000 ---
    lda #$10
    sta VIC_MODE
    lda #<FB_WIN
    sta BMPLO
    lda #>FB_WIN
    sta BMPHI
    lda #0
    sta BANK

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
    lda #$00                ; inside the set: black
    jmp plot

escaped:
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (0..MAX_ITER-1)
    tax
    lda color_table,x       ; RGB332 colour

plot:
    ; A = pixel colour byte; write it to the framebuffer window
    ldy #0
    sta (BMPLO),y

    ; advance the window pointer; hop to the next bank when it passes $7FFF
    inc BMPLO
    bne no_carry
    inc BMPHI
    lda BMPHI
    cmp #$80
    bne no_carry
    lda #>FB_WIN
    sta BMPHI
    inc BANK
    lda BANK
    asl a
    asl a
    asl a
    asl a
    asl a                   ; bank << 5 -> bits 7:5
    ora #$10                ; keep bit 4 (DDR3 mode)
    sta VIC_MODE
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

; Escape-iteration colour gradient in RGB332 (RRRGGGBB), 32 entries for
; MAX_ITER=32. Index = iterations used (0 = far, 31 = near the set). Interior
; pixels are drawn black by the code above, not from this table.
color_table:
    .byte $03,$07,$0B,$0F,$13,$17,$1B,$1F    ; blue -> cyan
    .byte $1E,$1C,$3C,$5C,$7C,$9C,$BC,$DC    ; cyan -> green -> toward yellow
    .byte $FC,$F8,$F4,$F0,$EC,$E8,$E4,$E0    ; yellow -> red
    .byte $E1,$E2,$E3,$C3,$A3,$63,$A7,$FF    ; red -> magenta -> violet -> white

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
