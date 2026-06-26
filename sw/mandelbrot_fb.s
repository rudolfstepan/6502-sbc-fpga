; ============================================================
; Mandelbrot Set — 320x200, 256 colours (RGB332), DDR3 framebuffer
; Coprocessor edition: the signed fixed-point multiply runs on the
; memory-mapped math coprocessor ($88B0) in 8.24 fixed-point.
;
;   VIC_MODE $9000  bit4 = 320x200 8bpp framebuffer display enable
;                   bits5-7 = 8 KB CPU bank for the $6000-$7FFF window
;   Framebuffer    = 64000 bytes (320*200), one RGB332 byte per pixel, in DDR3.
;
; Pixels are written linearly top-to-bottom, left-to-right, so a running $6000
; pointer is advanced one byte per pixel and the bank is bumped every 8 KB.
;
; Build:
;   ca65 --cpu 65c02 -o mandelbrot_fb.o mandelbrot_fb.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/mandelbrot_fb.rom mandelbrot_fb.o
;
; Upload:
;   python tools/upload_monitor_hex.py roms/mandelbrot_fb.rom \
;       --split-rom --port COM15 --baud 115200 --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Math coprocessor ($88B0..$88BF), 8.24 fixed-point ---
MUL         = $88B0
MUL_A       = MUL+0         ; W operand A (32-bit signed)
MUL_B       = MUL+4         ; W operand B
MUL_RES     = MUL+8         ; R result = (A*B) >> SHIFT
MUL_SHIFT   = MUL+12        ; W shift amount

; --- Framebuffer ---
FB_WIN      = $6000         ; CPU framebuffer window (8 KB, banked)
FB_MODE     = $10           ; MODE: bit4 = fb display on, bank 0

; --- Mandelbrot view (8.24 fixed-point) ---
; Step 1/80 on both axes keeps pixels square: 320/80 = 4.0 wide
; (real -2.5..+1.5), 200/80 = 2.5 tall (imag -1.25..+1.25).
X_LEFT      = $FD800000     ; -2.5
CI_START    = $FEC00000     ; -1.25
SX_STEP     = $00033333     ; 1/80 * 2^24 ~= 209715
SY_STEP     = $00033333     ; 1/80 * 2^24
ESCAPE_INT  = $04           ; |z|^2 >= 4.0  -> integer byte (bits 31-24) >= 4
MAX_ITER    = 32

; ============================================================
.segment "ZEROPAGE"

ZR:         .res 4          ; z real        (8.24)
ZI:         .res 4          ; z imaginary
CR:         .res 4          ; c real
CI:         .res 4          ; c imaginary
ZR2:        .res 4          ; zr^2
ZI2:        .res 4          ; zi^2
PROD:       .res 4          ; scratch product
SUM:        .res 4          ; zr^2 + zi^2
ITER:       .res 1          ; iteration counter
PY:         .res 1          ; pixel Y (0-199)
CXLO:       .res 1          ; pixel X within row, low
CXHI:       .res 1          ; pixel X within row, high (0..319)
PHYSLO:     .res 1          ; framebuffer window pointer ($6000-$7FFF)
PHYSHI:     .res 1
BANK:       .res 1          ; current 8 KB bank (0-7)

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

; dst = (opA * opB) >> SHIFT, signed, via the coprocessor.
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

    ; --- Coprocessor: 8.24 (SHIFT = 24) ---
    lda #24
    sta MUL_SHIFT

    ; --- Enable 320x200 framebuffer mode, bank 0 ---
    lda #FB_MODE
    sta VIC_MODE

    ; --- Framebuffer window pointer = $6000, bank 0 ---
    lda #<FB_WIN
    sta PHYSLO
    lda #>FB_WIN
    sta PHYSHI
    lda #0
    sta BANK

    ; --- Initialize outer loop ---
    LD32I CI, CI_START
    lda #0
    sta PY

; ============================================================
; Main loop: for PY = 0 to 199
; ============================================================
row_loop:
    LD32I CR, X_LEFT
    lda #0
    sta CXLO
    sta CXHI

; --- for CX = 0 to 319 (one pixel = one RGB332 byte) ---
pixel_loop:
    ; --- z = 0, iterate z = z^2 + c ---
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

    ; SUM = ZR2 + ZI2 ; escape if |z|^2 >= 4.0
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
    jmp escaped             ; overflow into sign
:
    lda SUM+3
    cmp #ESCAPE_INT
    bcc :+
    jmp escaped
:

    ; ZI = 2 * ZR * ZI + CI
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

    ; ZR = ZR2 - ZI2 + CR
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
    beq in_set
    jmp iter_loop

in_set:
    lda #$00                ; inside the set -> black
    jmp put_pixel

escaped:
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (0..MAX_ITER-1)
    tax
    lda color_table,x

put_pixel:
    ; A = RGB332 colour; write at the running framebuffer pointer
    ldy #0
    sta (PHYSLO),y

    ; --- Advance pointer, switch bank every 8 KB ---
    inc PHYSLO
    bne adv_done
    inc PHYSHI
    lda PHYSHI
    cmp #$80
    bne adv_done
    lda #>FB_WIN
    sta PHYSHI
    inc BANK
    lda BANK
    asl
    asl
    asl
    asl
    asl                     ; bank << 5 -> bits 5-7
    ora #FB_MODE
    sta VIC_MODE
adv_done:

    ; --- Advance CR by SX_STEP ---
    clc
    lda CR+0
    adc #<SX_STEP
    sta CR+0
    lda CR+1
    adc #>SX_STEP
    sta CR+1
    lda CR+2
    adc #^SX_STEP
    sta CR+2
    lda CR+3
    adc #>(SX_STEP >> 16)
    sta CR+3

    ; --- Next column (until 320) ---
    inc CXLO
    bne :+
    inc CXHI
:
    lda CXHI
    cmp #>320
    bne cont_px
    lda CXLO
    cmp #<320
    beq row_done
cont_px:
    jmp pixel_loop
row_done:

    ; --- Advance CI by SY_STEP ---
    clc
    lda CI+0
    adc #<SY_STEP
    sta CI+0
    lda CI+1
    adc #>SY_STEP
    sta CI+1
    lda CI+2
    adc #^SY_STEP
    sta CI+2
    lda CI+3
    adc #>(SY_STEP >> 16)
    sta CI+3

    ; --- Next row ---
    inc PY
    lda PY
    cmp #200
    bcs done
    jmp row_loop

; ============================================================
done:
wait_key:
    lda UART_SR
    and #UART_RDRF
    beq wait_key
    lda UART_DATA
    lda #$00
    sta VIC_MODE            ; back to text mode
halt:
    jmp halt

; ============================================================
.segment "RODATA"

; Iteration count -> RGB332 (RRRGGGBB), 32 entries.
; Fast escape (outer) = dark blue; near the set = warm/white.
color_table:
    .byte $01, $02, $03, $07, $0B, $0F, $0E, $1E
    .byte $1C, $3C, $5C, $7C, $9C, $BC, $DC, $FC
    .byte $F8, $F4, $F0, $EC, $E8, $E4, $E0, $C0
    .byte $A0, $A2, $A3, $C3, $E3, $EB, $F7, $FF

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
