; ============================================================
; Mandelbrot Set — 320x200 Bitmap, 16 C64 Colors
; Enhanced graphics edition: square-pixel view, higher iteration depth,
; and stable 8x8 color-cell accumulation.
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
BMP_BASE    = $6000         ; bitmap RAM (8 KB, first 8000 bytes visible)
COL_BASE    = $8400         ; color RAM (1000 bytes)

; --- Mandelbrot constants (8.24 fixed-point) ---
; View: real -2.2..+1.0 (width 3.2), imag -1.0..+1.0 (height 2.0)
; This matches the 320:200 aspect ratio: both axes use a 0.01 pixel step.
X_LEFT      = $FDCCCCCD     ; -2.2 in 8.24
CI_START    = $FF000000     ; -1.0 in 8.24
SX_STEP     = $00028F5C     ; 3.2/320 * 2^24 ~= 167772
SY_STEP     = $00028F5C     ; 2.0/200 * 2^24 ~= 167772
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
PTR:        .res 2          ; generic 16-bit pointer (clear loops)
ITER:       .res 1          ; iteration counter
BITS:       .res 1          ; accumulated 8-pixel byte
ESCIT:      .res 1          ; escape iteration count for current pixel
PAGES:      .res 1          ; page counter for post-processing loops
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

    ; --- Clear color RAM as temporary 8x8-cell iteration buffer ---
    ; During rendering each color cell stores the maximum escape iteration
    ; seen in its 8x8 tile. After the render pass, this is translated
    ; through color_table into final palette values.
    lda #<COL_BASE
    sta PTR
    lda #>COL_BASE
    sta PTR+1
    lda #0
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

    ; --- Accumulate best color score for this 8x8 color cell ---
    ; Color RAM is 40x25 while the bitmap is 320x200.  The old version
    ; stored the last escaped pixel color for each byte row, so later rows
    ; overwrote earlier detail.  Here we keep the maximum escape iteration
    ; for the whole 8x8 cell, then map it to a palette color after rendering.
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (1..MAX_ITER)
    sta ESCIT
    ldy PXB
    lda (COLLO),y           ; existing max iteration for this 8x8 cell
    cmp ESCIT
    bcs :+                  ; keep existing if existing >= new
    lda ESCIT
    sta (COLLO),y
:

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
    ; Convert accumulated per-cell iteration counts to final palette colors
    ; ============================================================
    lda #<COL_BASE
    sta PTR
    lda #>COL_BASE
    sta PTR+1
    lda #4                  ; 4 pages = 1024 bytes, harmlessly covers 40x25 plus padding
    sta PAGES
    ldy #0
map_colors:
    lda (PTR),y             ; 0..MAX_ITER
    tax
    lda color_table,x
    sta (PTR),y
    iny
    bne map_colors
    inc PTR+1
    dec PAGES
    bne map_colors

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

; Color gradient: escape iteration count -> C64 palette index
; Entry 0 is used for untouched cells.  Entries 1..32 form a smoother
; cold-to-hot contour ramp.  The bitmap still decides which pixels are lit;
; this table only chooses the color of each 8x8 cell.
color_table:
    .byte 0                 ; 0: no escaped pixels in this cell
    .byte 6                 ; 1: blue
    .byte 6                 ; 2: blue
    .byte 14                ; 3: light blue
    .byte 14                ; 4: light blue
    .byte 3                 ; 5: cyan
    .byte 3                 ; 6: cyan
    .byte 13                ; 7: light green
    .byte 13                ; 8: light green
    .byte 5                 ; 9: green
    .byte 5                 ; 10: green
    .byte 7                 ; 11: yellow
    .byte 7                 ; 12: yellow
    .byte 10                ; 13: light red
    .byte 10                ; 14: light red
    .byte 2                 ; 15: red
    .byte 2                 ; 16: red
    .byte 8                 ; 17: orange
    .byte 8                 ; 18: orange
    .byte 9                 ; 19: brown
    .byte 9                 ; 20: brown
    .byte 4                 ; 21: purple
    .byte 4                 ; 22: purple
    .byte 12                ; 23: gray
    .byte 12                ; 24: gray
    .byte 15                ; 25: light gray
    .byte 15                ; 26: light gray
    .byte 1                 ; 27: white
    .byte 1                 ; 28: white
    .byte 11                ; 29: dark gray
    .byte 11                ; 30: dark gray
    .byte 0                 ; 31: black near boundary
    .byte 1                 ; 32: white highlight

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
