; ============================================================
; Mandelbrot Set — 180x120 packed bitmap, 64 RGB222 colors
; Coprocessor edition: uses the memory-mapped math coprocessor
; ($88B0) for the signed fixed-point multiply.
;
; 8.24 signed fixed-point arithmetic (range -128.0 .. +127.999..)
; The software fpmul (shift-add) is replaced by four register
; writes + four reads to the hardware DSP multiplier — and 8.24
; gives a far sharper image than the old 4.12.
;
; Build (split-map application at $A000, vectors at $FFFA):
;   ca65 --cpu 65c02 -o mandelbrot_copro.o mandelbrot_copro.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/mandelbrot_copro.bin mandelbrot_copro.o
;
; Upload:
;   python tools/upload_monitor_hex.py roms/mandelbrot_copro.bin \
;       --split-rom --port COM15 --baud 115200 --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Math coprocessor ($88B0..$88BF) ---
;   +0..3  W operand A (32-bit signed)   R raw product byte 0..3
;   +4..7  W operand B                   R raw product byte 4..7
;   +8..B  R result = (A*B) >> SHIFT (8.24)
;   +C     W SHIFT amount (default 24)
MUL         = $88B0
MUL_A       = MUL+0
MUL_B       = MUL+4
MUL_RES     = MUL+8
MUL_SHIFT   = MUL+12

; --- Memory map ---
BMP_BASE    = $6000         ; 8 KB CPU window into 16 KB framebuffer
MODE_RGB0   = $09           ; bitmap + packed RGB222, framebuffer bank 0
MODE_RGB1   = $0D           ; bitmap + packed RGB222, framebuffer bank 1

; --- Mandelbrot constants (8.24 fixed-point) ---
; View: real -2.625..+1.125 (width 3.75), imag -1.25..+1.25 (height 2.5).
; Zoomed out from the old -2.1..+0.9 / -1.0..+1.0: the old imag range clipped
; the set's top/bottom bulbs (which reach ~+/-1.13). Now the whole set fits with
; margin. Both axes share a 1/48 pixel step, so pixels stay square
; (180*1/48 = 3.75 wide, 120*1/48 = 2.5 tall).
X_LEFT      = $FD600000     ; -2.625 in 8.24
CI_START    = $FEC00000     ; -1.25 in 8.24
SX_STEP     = $00055555     ; 1/48 * 2^24 ~= 349525  (3.75/180 = 2.5/120)
SY_STEP     = $00055555     ; 1/48 * 2^24 ~= 349525
ESCAPE_INT  = $04           ; |z|^2 >= 4.0 -> integer byte (bits 24-31) >= 4
MAX_ITER    = 32            ; more contour detail than the old 20

; ============================================================
.segment "ZEROPAGE"

ZR:         .res 4          ; z real        (8.24)
ZI:         .res 4          ; z imaginary
CR:         .res 4          ; c real
CI:         .res 4          ; c imaginary
ZR2:        .res 4          ; zr^2
ZI2:        .res 4          ; zi^2
PROD:       .res 4          ; scratch product (zr*zi)
SUM:        .res 4          ; zr^2 + zi^2
ITER:       .res 1          ; iteration counter
PIXCOLOR:   .res 1          ; RGB222 color for current pixel
PACKBYTE:   .res 1          ; partial 4-pixel / 3-byte group
PACKPOS:    .res 1          ; pixel position within packed group (0-3)
PY:         .res 1          ; pixel Y (0-119)
PX:         .res 1          ; pixel X (0-179)
BMPLO:      .res 1          ; bitmap row pointer low
BMPHI:      .res 1          ; bitmap row pointer high

; ============================================================
; Macros: 32-bit fixed-point helpers
; ============================================================

; Load a 32-bit immediate into a zero-page quad.
; Byte extractors use fixed bit-ranges, so they are immune to how
; ca65 sign-extends the constant.
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

; Add a 32-bit immediate to a zero-page quad.
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

; Copy a zero-page quad.
.macro MOV32 dst, src
    lda src+0
    sta dst+0
    lda src+1
    sta dst+1
    lda src+2
    sta dst+2
    lda src+3
    sta dst+3
.endmacro

; dst = (opA * opB) >> 24, signed, via the hardware coprocessor.
; opA / opB are zero-page quads.  Operands are written low byte first;
; writing B byte 3 completes the operand set, and by the time the first
; result byte is read the DSP pipeline (2 clocks) has long settled.
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

    ; --- Enable 180x120 packed RGB222 mode, framebuffer bank 0 ---
    lda #MODE_RGB0
    sta VIC_MODE

    ; --- Clear the framebuffer first so the previous render does not linger;
    ;     the new image then visibly builds up from a black screen. ---
    jsr clear_fb

    ; --- Initialize outer loop ---
    LD32I CI, CI_START

    lda #<BMP_BASE
    sta BMPLO
    lda #>BMP_BASE
    sta BMPHI

    lda #0
    sta PY
    sta PACKPOS

; ============================================================
; Main loop: for PY = 0 to 119
; ============================================================
row_loop:
    ; Reset CR to X_LEFT for this row
    LD32I CR, X_LEFT

    lda #0
    sta PX

; --- for PX = 0 to 179 ---
pixel_loop:
    lda #0
    sta PIXCOLOR            ; points inside the set remain black

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
    ; --- ZR2 = ZR * ZR ---
    MUL32 ZR, ZR, ZR2

    ; --- ZI2 = ZI * ZI ---
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
    ; escape if |z|^2 >= 4.0 (or overflowed into the sign bit).  The MUL32
    ; macros make the loop body large, so reach 'escaped' via an absolute jmp.
    bpl :+
    jmp escaped             ; defensive: overflow into sign
:
    lda SUM+3
    cmp #ESCAPE_INT
    bcc :+
    jmp escaped
:

    ; --- ZI = 2 * ZR * ZI + CI ---
    MUL32 ZR, ZI, PROD
    asl PROD+0              ; PROD = PROD * 2
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
    ; Did not escape — PIXCOLOR remains black.
    jmp next_pixel

escaped:
    ; Map the escape iteration directly to one RGB222 pixel.
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (0..MAX_ITER-1)
    tax
    lda color_table,x
    sta PIXCOLOR

next_pixel:
    ; Pack four 6-bit pixels into three bytes:
    ; B0=P0[5:0],P1[5:4] B1=P1[3:0],P2[5:2] B2=P2[1:0],P3[5:0].
    lda PACKPOS
    beq pack_0
    cmp #1
    beq pack_1
    cmp #2
    beq pack_2

pack_3:
    lda PIXCOLOR
    ora PACKBYTE
    jsr store_byte
    jmp packed

pack_0:
    lda PIXCOLOR
    asl
    asl
    sta PACKBYTE
    jmp packed

pack_1:
    lda PIXCOLOR
    lsr
    lsr
    lsr
    lsr
    ora PACKBYTE
    jsr store_byte
    lda PIXCOLOR
    and #$0F
    asl
    asl
    asl
    asl
    sta PACKBYTE
    jmp packed

pack_2:
    lda PIXCOLOR
    lsr
    lsr
    ora PACKBYTE
    jsr store_byte
    lda PIXCOLOR
    and #$03
    asl
    asl
    asl
    asl
    asl
    asl
    sta PACKBYTE

packed:
    inc PACKPOS
    lda PACKPOS
    and #$03
    sta PACKPOS

    ; --- Advance CR by SX ---
    ADD32I CR, SX_STEP

    inc PX
    lda PX
    cmp #180
    bcs :+
    jmp pixel_loop
:

    ; --- Advance CI by SY ---
    ADD32I CI, SY_STEP

    ; --- Next row ---
    inc PY
    lda PY
    cmp #120
    bcs :+
    jmp row_loop
:

    ; ============================================================
    ; Done — wait for UART key, then text mode
    ; ============================================================
wait_key:
    lda UART_SR
    and #UART_RDRF
    beq wait_key
    lda UART_DATA           ; consume key

    lda #$00
    sta VIC_MODE            ; back to text mode

halt:
    jmp halt

; Clear the whole 16 KiB framebuffer (both 8 KiB CPU-window banks) to black.
; Leaves the mode at MODE_RGB0 / bank 0 so rendering can start writing linearly.
clear_fb:
    lda #MODE_RGB0
    sta VIC_MODE            ; bank 0 in the $6000 window
    jsr clear_window
    lda #MODE_RGB1
    sta VIC_MODE            ; bank 1 in the $6000 window
    jsr clear_window
    lda #MODE_RGB0
    sta VIC_MODE            ; rendering starts in bank 0
    rts

; Zero $6000-$7FFF (8 KiB) of the currently banked framebuffer window.
clear_window:
    lda #<BMP_BASE
    sta BMPLO
    lda #>BMP_BASE
    sta BMPHI
    lda #0
    tay                     ; Y = 0 index (stays 0); A = 0 (stays 0)
@cw:
    sta (BMPLO),y
    inc BMPLO
    bne @cw
    inc BMPHI
    ldx BMPHI
    cpx #$80                ; past $7FFF -> done
    bne @cw
    rts

; Write A to the current framebuffer byte and switch CPU banks at 8 KiB.
store_byte:
    ldy #0
    sta (BMPLO),y
    inc BMPLO
    bne store_done
    inc BMPHI
    lda BMPHI
    cmp #$80                ; first 8192 bytes completed?
    bne store_done
    lda #MODE_RGB1
    sta VIC_MODE
    lda #<BMP_BASE
    sta BMPLO
    lda #>BMP_BASE
    sta BMPHI
store_done:
    rts

; ============================================================
.segment "RODATA"

; Escape iteration -> RRGGBB. Interior pixels bypass the table and stay black.
color_table:
    .byte $03,$07,$0B,$0F,$0E,$0D,$0C,$1C
    .byte $2C,$3C,$38,$34,$30,$31,$32,$33
    .byte $23,$13,$03,$17,$2B,$3F,$3E,$3D
    .byte $3C,$39,$36,$33,$2A,$15,$2A,$3F

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
