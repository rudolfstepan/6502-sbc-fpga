; ============================================================
; Mandelbrot Set — 320x200, 256 colours (RGB332) from DDR3
;
; Ported from the old 1bpp hires version to the DDR3 framebuffer:
;   * $9000 bit 4 = DDR3 320x200 8bpp mode, bits 7:5 = 8 KiB bank (8 banks)
;   * one colour byte per pixel written to the banked $6000-$7FFF window
;   * each pixel is coloured by its escape-iteration count (inside = black)
; The fixed-point escape maths and fpmul are unchanged from the 1bpp version.
;
; Build (split-map ROM, run at $A000):
;   ca65 --cpu 65c02 -o mandelbrot_bitmap.o mandelbrot_bitmap.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/mandelbrot_bitmap.rom mandelbrot_bitmap.o
; Upload:
;   python tools/upload_monitor_hex.py roms/mandelbrot_bitmap.rom --split-rom --run
; ============================================================

VIC_MODE    = $9000         ; bit4 = DDR3 320x200 8bpp, bits7:5 = 8 KiB bank
FB_WIN      = $6000         ; banked framebuffer window ($6000-$7FFF)
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; Fixed-point 4.12 view: real [-2.0, +1.0), imag [-1.2, +1.2)
X_LEFT      = $E000         ; -2.0
CI_START    = $ECCD         ; -1.2
SX_STEP     = 38            ; 3.0/320 * 4096 ~ 38
SY_STEP     = 49            ; 2.4/200 * 4096 ~ 49
ESCAPE_HI   = $40           ; 4.0 in 4.12 = $4000, check high byte >= $40
MAX_ITER    = 20

; ============================================================
.segment "ZEROPAGE"
ZR:         .res 2          ; z real
ZI:         .res 2          ; z imaginary
CR:         .res 2          ; c real
CI:         .res 2          ; c imaginary
ZR2:        .res 2          ; zr^2 (positive)
ZI2:        .res 2          ; zi^2 (positive)
TMP:        .res 2          ; scratch (TMP+1 used by the escape sum)
ITER:       .res 1          ; iteration counter (counts down from MAX_ITER)
PY:         .res 1          ; pixel Y (0-199)
PX:         .res 2          ; pixel X (0-319, 16-bit)
PTR:        .res 2          ; framebuffer window pointer
BANK:       .res 1          ; current 8 KiB bank 0..7
SIGN:       .res 1          ; multiply sign flag
MUL_A:      .res 2          ; multiply operand A (destroyed)
MUL_B:      .res 2          ; multiply operand B (multiplicand)
MUL_M:      .res 2          ; multiplier working copy (shifted out)
MUL_R:      .res 4          ; 32-bit multiply result

; ============================================================
.segment "CODE"

RESET:
    sei
    ldx #$FF
    txs

    ; --- Enable DDR3 320x200 8bpp mode, bank 0, pointer at $6000 ---
    lda #$10
    sta VIC_MODE
    lda #<FB_WIN
    sta PTR
    lda #>FB_WIN
    sta PTR+1
    lda #0
    sta BANK

    ; --- Initialise outer loop ---
    lda #<CI_START
    sta CI
    lda #>CI_START
    sta CI+1
    lda #0
    sta PY

; ============================================================
; Main loop: for PY = 0 to 199
; ============================================================
row_loop:
    ; Reset CR to X_LEFT for this row
    lda #<X_LEFT
    sta CR
    lda #>X_LEFT
    sta CR+1
    ; PX = 0
    lda #0
    sta PX
    sta PX+1

; --- for PX = 0 to 319 ---
px_loop:
    ; --- Mandelbrot iteration: z = 0, iterate z = z^2 + c ---
    lda #0
    sta ZR
    sta ZR+1
    sta ZI
    sta ZI+1
    lda #MAX_ITER
    sta ITER

iter_loop:
    ; --- Compute ZR2 = ZR * ZR ---
    lda ZR
    sta MUL_A
    sta MUL_B
    lda ZR+1
    sta MUL_A+1
    sta MUL_B+1
    jsr fpmul
    lda MUL_R+1
    sta ZR2
    lda MUL_R+2
    sta ZR2+1
    ; Check overflow: if ZR2 >= 4.0, escape. These branches are too far from
    ; the escaped handler for a relative branch, so branch over an absolute jmp.
    lda ZR2+1
    bpl :+
    jmp escaped             ; negative = overflow past 8.0
:
    cmp #ESCAPE_HI
    bcc :+
    jmp escaped
:

    ; --- Compute ZI2 = ZI * ZI ---
    lda ZI
    sta MUL_A
    sta MUL_B
    lda ZI+1
    sta MUL_A+1
    sta MUL_B+1
    jsr fpmul
    lda MUL_R+1
    sta ZI2
    lda MUL_R+2
    sta ZI2+1
    lda ZI2+1
    bpl :+
    jmp escaped
:
    cmp #ESCAPE_HI
    bcc :+
    jmp escaped
:

    ; --- Check ZR2 + ZI2 > 4.0 ---
    clc
    lda ZR2
    adc ZI2
    sta TMP+1               ; temp low
    lda ZR2+1
    adc ZI2+1
    bcs escaped             ; carry = overflow
    bmi escaped             ; negative = overflow
    cmp #ESCAPE_HI
    bcs escaped

    ; --- Compute new ZI = 2 * ZR * ZI + CI ---
    lda ZR
    sta MUL_A
    lda ZR+1
    sta MUL_A+1
    lda ZI
    sta MUL_B
    lda ZI+1
    sta MUL_B+1
    jsr fpmul
    ; result * 2 (shift left 1)
    asl MUL_R+1
    rol MUL_R+2
    ; add CI
    clc
    lda MUL_R+1
    adc CI
    sta ZI
    lda MUL_R+2
    adc CI+1
    sta ZI+1

    ; --- Compute new ZR = ZR2 - ZI2 + CR ---
    sec
    lda ZR2
    sbc ZI2
    sta ZR
    lda ZR2+1
    sbc ZI2+1
    sta ZR+1
    clc
    lda ZR
    adc CR
    sta ZR
    lda ZR+1
    adc CR+1
    sta ZR+1

    ; --- Next iteration ---
    dec ITER
    beq no_escape
    jmp iter_loop

no_escape:
    ; Inside the set: black
    lda #$00
    jmp plot

escaped:
    ; Colour from iteration count: A = iterations used (0..MAX_ITER-1)
    lda #MAX_ITER
    sec
    sbc ITER
    tax
    lda color_table,x

plot:
    ; A = pixel colour byte; write it to the framebuffer window
    ldy #0
    sta (PTR),y

    ; advance the window pointer; hop to the next bank when it passes $7FFF
    inc PTR
    bne no_carry
    inc PTR+1
    lda PTR+1
    cmp #$80
    bne no_carry
    lda #>FB_WIN
    sta PTR+1
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
    clc
    lda CR
    adc #<SX_STEP
    sta CR
    lda CR+1
    adc #>SX_STEP
    sta CR+1

    ; --- PX++ ; loop while PX < 320 ---
    inc PX
    bne px_chk
    inc PX+1
px_chk:
    lda PX+1
    beq px_more             ; PX < 256 -> keep going
    lda PX                  ; PX high == 1: compare low to 320 & $FF = $40
    cmp #<320
    bcc px_more
    jmp row_done            ; PX == 320 -> row finished
px_more:
    jmp px_loop

row_done:
    ; --- Advance CI by SY_STEP ---
    clc
    lda CI
    adc #<SY_STEP
    sta CI
    lda CI+1
    adc #>SY_STEP
    sta CI+1

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
; fpmul — Signed 4.12 fixed-point multiply
;
; Input:  MUL_A (16-bit signed, destroyed)
;         MUL_B (16-bit signed, preserved)
; Output: MUL_R+1 (result low), MUL_R+2 (result high)
;         in 4.12 signed fixed-point
; ============================================================
.proc fpmul
    ; Determine result sign
    lda MUL_A+1
    eor MUL_B+1
    sta SIGN

    ; Absolute value of A
    lda MUL_A+1
    bpl a_pos
    jsr neg_a
a_pos:

    ; Absolute value of B (save original for restore)
    lda MUL_B+1
    bpl b_pos
    jsr neg_b
b_pos:

    ; --- Unsigned 16x16 -> 32 multiply (shift-add, product shifts right) ---
    lda MUL_A
    sta MUL_M
    lda MUL_A+1
    sta MUL_M+1
    lda #0
    sta MUL_R
    sta MUL_R+1
    sta MUL_R+2
    sta MUL_R+3

    ldx #16
mul_loop:
    lsr MUL_M+1             ; multiplier LSB -> carry
    ror MUL_M
    bcc no_add
    clc
    lda MUL_R+2
    adc MUL_B
    sta MUL_R+2
    lda MUL_R+3
    adc MUL_B+1
    sta MUL_R+3
no_add:
    ror MUL_R+3            ; rotate 32-bit result right (carry from add at top)
    ror MUL_R+2
    ror MUL_R+1
    ror MUL_R
    dex
    bne mul_loop

    ; --- Extract 4.12: shift bytes [3:2:1] right by 4 ---
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    ; Result: MUL_R+1 = low byte, MUL_R+2 = high byte

    ; --- Apply sign ---
    bit SIGN
    bpl no_neg
    sec
    lda #0
    sbc MUL_R+1
    sta MUL_R+1
    lda #0
    sbc MUL_R+2
    sta MUL_R+2
no_neg:
    ; MUL_A / MUL_B may be left negated; the Mandelbrot caller always
    ; reloads both operands before each call, so no restore is needed.
    rts

neg_a:
    sec
    lda #0
    sbc MUL_A
    sta MUL_A
    lda #0
    sbc MUL_A+1
    sta MUL_A+1
    rts

neg_b:
    sec
    lda #0
    sbc MUL_B
    sta MUL_B
    lda #0
    sbc MUL_B+1
    sta MUL_B+1
    rts
.endproc

; ============================================================
.segment "RODATA"

; Escape-iteration colour gradient in RGB332 (RRRGGGBB).
; Index = iterations used (0 = escaped immediately/far ... 19 = near the set).
; Points that never escape are drawn black by the code above, not from here.
color_table:
    .byte $03               ; 0  blue (far)
    .byte $07               ; 1
    .byte $0F               ; 2  cyan
    .byte $1F               ; 3  bright cyan
    .byte $1E               ; 4
    .byte $1C               ; 5  green
    .byte $3C               ; 6
    .byte $5C               ; 7
    .byte $7C               ; 8
    .byte $BC               ; 9
    .byte $FC               ; 10 yellow
    .byte $F8               ; 11
    .byte $F4               ; 12 orange
    .byte $EC               ; 13
    .byte $E4               ; 14
    .byte $E0               ; 15 red
    .byte $E3               ; 16 magenta
    .byte $E7               ; 17
    .byte $EB               ; 18
    .byte $FF               ; 19 white (near the set)

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
