; ============================================================
; Mandelbrot Set — 320x200 Bitmap, 16 C64 Colors
; Coprocessor edition: uses the memory-mapped math coprocessor
; ($88B0) for the signed fixed-point multiply.
;
; 8.24 signed fixed-point arithmetic (range -128.0 .. +127.999..)
; The software fpmul (shift-add) is replaced by four register
; writes + four reads to the hardware DSP multiplier — and 8.24
; gives a far sharper image than the old 4.12.
;
; Build (reuse the standalone $C000 config):
;   ca65 --cpu 65c02 -o mandelbrot_copro.o mandelbrot_copro.s
;   ld65 -C mandelbrot_bitmap.cfg -o mandelbrot_copro.bin mandelbrot_copro.o
;
; Upload:
;   python tools/upload_monitor_hex.py mandelbrot_copro.bin \
;       --port COM15 --baud 230400 --address 0xC000 --run
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
BMP_BASE    = $9010         ; bitmap RAM (8000 bytes)
COL_BASE    = $8400         ; color RAM (1000 bytes)

; --- Mandelbrot constants (8.24 fixed-point) ---
; View: real -2.0..+1.0 (width 3.0), imag -1.2..+1.2 (height 2.4)
X_LEFT      = $FE000000     ; -2.0
CI_START    = $FECCCCCD     ; -1.2
SX_STEP     = $00026666     ; 3.0/320 * 2^24 ~ 157286
SY_STEP     = $0003126F     ; 2.4/200 * 2^24 ~ 201327
ESCAPE_INT  = $04           ; |z|^2 >= 4.0 -> integer byte (bits 24-31) >= 4
MAX_ITER    = 20

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
PTR:        .res 2          ; generic 16-bit pointer (clear loops)
ITER:       .res 1          ; iteration counter
BITS:       .res 1          ; accumulated 8-pixel byte
LASTCOL:    .res 1          ; last escape color in current cell
PY:         .res 1          ; pixel Y (0-199)
PXB:        .res 1          ; byte X (0-39)
PIX:        .res 1          ; pixel index within byte (0-7)
BMPLO:      .res 1          ; bitmap row pointer low
BMPHI:      .res 1          ; bitmap row pointer high
COLLO:      .res 1          ; color row pointer low
COLHI:      .res 1          ; color row pointer high
YCELL:      .res 1          ; Y within color cell (0-7)

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

    ; --- Enable bitmap mode ---
    lda #$01
    sta VIC_MODE

    ; --- Clear bitmap RAM (8192 bytes = 32 pages) ---
    lda #<BMP_BASE
    sta PTR
    lda #>BMP_BASE
    sta PTR+1
    lda #0
    tay
    ldx #32
clr_bmp:
    sta (PTR),y
    iny
    bne clr_bmp
    inc PTR+1
    dex
    bne clr_bmp

    ; --- Fill color RAM with white-on-black ($01), 1024 bytes ---
    lda #<COL_BASE
    sta PTR
    lda #>COL_BASE
    sta PTR+1
    lda #$01
    ldy #0
    ldx #4
clr_col:
    sta (PTR),y
    iny
    bne clr_col
    inc PTR+1
    dex
    bne clr_col

    ; --- Initialize outer loop ---
    LD32I CI, CI_START

    lda #<BMP_BASE
    sta BMPLO
    lda #>BMP_BASE
    sta BMPHI

    lda #<COL_BASE
    sta COLLO
    lda #>COL_BASE
    sta COLHI

    lda #0
    sta PY
    sta YCELL

; ============================================================
; Main loop: for PY = 0 to 199
; ============================================================
row_loop:
    ; Reset CR to X_LEFT for this row
    LD32I CR, X_LEFT

    lda #0
    sta PXB

; --- for PXB = 0 to 39 (byte columns) ---
byte_loop:
    lda #0
    sta BITS
    sta LASTCOL

    ; --- for 8 pixels within this byte ---
    lda #0
    sta PIX
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
    ; Did not escape — pixel stays off
    jmp next_pixel

escaped:
    ; --- Set pixel bit ---
    ldx PIX
    lda mask_table,x
    ora BITS
    sta BITS

    ; --- Set color from iteration count ---
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (1..MAX_ITER)
    tax
    lda color_table,x
    sta LASTCOL

next_pixel:
    ; --- Advance CR by SX ---
    ADD32I CR, SX_STEP

    inc PIX
    lda PIX
    cmp #8
    bcs :+
    jmp pixel_loop
:

    ; --- Store 8-pixel byte to bitmap RAM ---
    lda BITS
    beq skip_bmp
    ldy PXB
    sta (BMPLO),y
skip_bmp:

    ; --- Store color to color RAM ---
    lda LASTCOL
    beq skip_col
    ldy PXB
    sta (COLLO),y
skip_col:

    ; --- Next byte column ---
    inc PXB
    lda PXB
    cmp #40
    bcs :+
    jmp byte_loop
:

    ; --- Advance bitmap pointer by 40 ---
    clc
    lda BMPLO
    adc #40
    sta BMPLO
    bcc :+
    inc BMPHI
:

    ; --- Advance color pointer every 8 rows ---
    inc YCELL
    lda YCELL
    cmp #8
    bcc :+
    lda #0
    sta YCELL
    clc
    lda COLLO
    adc #40
    sta COLLO
    bcc :+
    inc COLHI
:

    ; --- Advance CI by SY ---
    ADD32I CI, SY_STEP

    ; --- Next row ---
    inc PY
    lda PY
    cmp #200
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

; ============================================================
.segment "RODATA"

; Pixel mask table: bit 7 = pixel 0 (leftmost), bit 0 = pixel 7
mask_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

; Color gradient: iteration count -> C64 palette index
color_table:
    .byte 0                 ; 0: unused
    .byte 6                 ; 1: blue
    .byte 6                 ; 2: blue
    .byte 14                ; 3: light blue
    .byte 14                ; 4: light blue
    .byte 3                 ; 5: cyan
    .byte 3                 ; 6: cyan
    .byte 13                ; 7: light green
    .byte 5                 ; 8: green
    .byte 7                 ; 9: yellow
    .byte 7                 ; 10: yellow
    .byte 10                ; 11: light red
    .byte 2                 ; 12: red
    .byte 8                 ; 13: orange
    .byte 9                 ; 14: brown
    .byte 4                 ; 15: purple
    .byte 12                ; 16: gray
    .byte 15                ; 17: light gray
    .byte 1                 ; 18: white
    .byte 11                ; 19: dark gray
    .byte 11                ; 20: dark gray

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
