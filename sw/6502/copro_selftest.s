; ============================================================
; Math coprocessor self-test ROM ($C000-$FFFF)
;
; Computes 2.0 * 3.0 in 8.24 fixed point on the memory-mapped
; coprocessor ($88B0) and checks the result is 6.0 ($06000000):
;   * fills the screen GREEN on success, RED on failure
;   * also prints "COPRO 2.0*3.0=<hex> OK/FAIL" over the UART,
;     so a failure shows exactly what the coprocessor returned
;     ($00000000 = returns zero, $FFFFFFFF = no response, ...).
;
; Build:
;   ca65 --cpu 65c02 -o copro_selftest.o copro_selftest.s
;   ld65 -C mandelbrot_bitmap.cfg -o copro_selftest.bin copro_selftest.o
; Upload:
;   python tools/upload_monitor_hex.py copro_selftest.bin \
;       --port COM15 --baud 230400 --address 0xC000 --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000
UART_DATA   = $8810
UART_SR     = $8811
UART_TDRE   = $10           ; status bit 4: transmit register empty

MUL         = $88B0
MUL_A       = MUL+0
MUL_B       = MUL+4
MUL_RES     = MUL+8
MUL_SHIFT   = MUL+12

BMP_BASE    = $9010
COL_BASE    = $8400

GREEN       = $55           ; both nibbles green (robust to fg/bg order)
RED         = $22           ; both nibbles red

.segment "ZEROPAGE"
PTR:    .res 2
COLOR:  .res 1
RES:    .res 4
TMPB:   .res 1

.macro PRINT addr
    lda #<addr
    sta PTR
    lda #>addr
    sta PTR+1
    jsr puts
.endmacro

; ============================================================
.segment "CODE"

RESET:
    sei
    ldx #$FF
    txs

    ; --- configure 8.24 (SHIFT = 24) ---
    lda #24
    sta MUL_SHIFT

    ; --- operand A = 2.0 = $02000000 ---
    lda #$00
    sta MUL_A+0
    lda #$00
    sta MUL_A+1
    lda #$00
    sta MUL_A+2
    lda #$02
    sta MUL_A+3
    ; --- operand B = 3.0 = $03000000 ---
    lda #$00
    sta MUL_B+0
    lda #$00
    sta MUL_B+1
    lda #$00
    sta MUL_B+2
    lda #$03
    sta MUL_B+3

    ; --- settle multiply+shift pipeline (generous for a diagnostic) ---
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    ; --- read 8.24 result ---
    lda MUL_RES+0
    sta RES+0
    lda MUL_RES+1
    sta RES+1
    lda MUL_RES+2
    sta RES+2
    lda MUL_RES+3
    sta RES+3

    ; --- UART: "COPRO 2.0*3.0=" + hex(RES3 RES2 RES1 RES0) ---
    PRINT msg_hdr
    lda RES+3
    jsr puthex
    lda RES+2
    jsr puthex
    lda RES+1
    jsr puthex
    lda RES+0
    jsr puthex

    ; --- compare to 6.0 = $06000000 ---
    lda RES+0
    bne fail
    lda RES+1
    bne fail
    lda RES+2
    bne fail
    lda RES+3
    cmp #$06
    bne fail

    ; pass
    lda #GREEN
    sta COLOR
    PRINT msg_ok
    jmp paint

fail:
    lda #RED
    sta COLOR
    PRINT msg_fail

paint:
    ; --- bitmap mode, fill bitmap with $FF, color RAM with COLOR ---
    lda #$01
    sta VIC_MODE

    lda #<BMP_BASE
    sta PTR
    lda #>BMP_BASE
    sta PTR+1
    lda #$FF
    ldy #0
    ldx #32
fill_bmp:
    sta (PTR),y
    iny
    bne fill_bmp
    inc PTR+1
    dex
    bne fill_bmp

    lda #<COL_BASE
    sta PTR
    lda #>COL_BASE
    sta PTR+1
    lda COLOR
    ldy #0
    ldx #4
fill_col:
    sta (PTR),y
    iny
    bne fill_col
    inc PTR+1
    dex
    bne fill_col

halt:
    jmp halt

; ============================================================
; UART helpers
; ============================================================

; putc: send the char in A
putc:
    sta TMPB
:
    lda UART_SR
    and #UART_TDRE
    beq :-
    lda TMPB
    sta UART_DATA
    rts

; puts: print zero-terminated string at PTR
puts:
    ldy #0
@loop:
    lda (PTR),y
    beq @done
    jsr putc
    iny
    bne @loop
@done:
    rts

; puthex: print the byte in A as two hex digits
puthex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr prnibble
    pla
    and #$0F
    jsr prnibble
    rts

; prnibble: print low nibble of A (0..15) as one hex char
prnibble:
    and #$0F
    cmp #10
    bcc @digit
    clc
    adc #('A' - 10)
    bne @send           ; always taken (letter is nonzero)
@digit:
    clc
    adc #'0'
@send:
    jsr putc
    rts

; ============================================================
.segment "RODATA"
msg_hdr:
    .byte "COPRO 2.0*3.0=", 0
msg_ok:
    .byte " OK (green)", $0D, $0A, 0
msg_fail:
    .byte " FAIL (red)", $0D, $0A, 0

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
