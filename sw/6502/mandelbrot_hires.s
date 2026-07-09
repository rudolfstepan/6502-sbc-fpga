; ============================================================
; Mandelbrot Set — 640x400, 256 colours (RGB332) from DDR3 hi-res mode
; Coprocessor edition: the hardware math coprocessor ($88B0) does the signed
; 8.24 fixed-point multiply (four writes + four reads instead of shift-add fpmul).
;
; Ported from the 320x200 copro version to the 640x400 hi-res framebuffer:
;   * $9000 bit 5 = DDR3 640x400 8bpp mode (bit 4 clear)
;   * $9006 = full 5-bit framebuffer bank (0..31); the 256000-byte frame spans
;     32x 8 KiB banks reached through the banked $6000-$7FFF window
; Same complex-plane view as the 320x200 version, sampled twice as densely
; (SX_STEP/SY_STEP halved). The 8.24 escape maths and the MUL32 coprocessor
; macro are unchanged; PX/PY are 16-bit because 400 rows do not fit in a byte.
;
; Build (split-map application at $A000, vectors at $FFFA):
;   ca65 --cpu 65c02 -o mandelbrot_hires.o mandelbrot_hires.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../../roms/6502/mandelbrot_hires.bin mandelbrot_hires.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/mandelbrot_hires.bin --split-rom --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000         ; bit5 = DDR3 640x400 8bpp hi-res (bit4 clear)
VIC_FB_BANK = $9006         ; 5-bit framebuffer bank 0..31
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

; --- Mandelbrot constants (8.24 fixed-point), sampled at 640x400 ---
; View: real -2.625..+1.125 (width 3.75), imag -1.25..+1.25 (height 2.5).
X_LEFT      = $FD600000     ; -2.625 in 8.24
CI_START    = $FEC00000     ; -1.25  in 8.24
SX_STEP     = $00018000     ; 3.75/640 * 2^24 = 98304
SY_STEP     = $0001999A     ; 2.5/400  * 2^24 = 104858
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
PY:     .res 2              ; pixel Y (0-399, 16-bit)
PX:     .res 2              ; pixel X (0-639, 16-bit)
BMPLO:  .res 1              ; framebuffer window pointer low
BMPHI:  .res 1              ; framebuffer window pointer high
BANK:   .res 1             ; current 8 KiB bank 0..31

.ifdef ZOOM_ANIM
BUFFER      = $0200
BUFFER2     = $0300
SRC_BANK    = CR+0
DST_BANK    = CR+1
SRCLO       = BMPLO
SRCHI       = BMPHI
DSTLO       = PX+0
DSTHI       = PX+1
ROWCNT      = PY+0
PIXCOL      = ITER
SRCBUF      = $1000
.endif

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

    ; --- Enable DDR3 640x400 8bpp hi-res mode, bank 0, pointer at $6000 ---
    lda #$20
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
    sta PY+0
    sta PY+1

; ============================================================
; Main loop: for PY = 0 to 399
; ============================================================
row_loop:
    LD32I CR, X_LEFT
    lda #0
    sta PX+0
    sta PX+1

; --- for PX = 0 to 639 ---
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
    lda #>FB_WIN            ; wrap the window back to $6000 ...
    sta BMPHI
    inc BANK               ; ... and select the next 8 KiB bank via $9006
    lda BANK
    sta VIC_FB_BANK        ; hi-res bank goes to $9006, $9000 stays $20
no_carry:

    ; --- Advance CR by SX_STEP ---
    ADD32I CR, SX_STEP

    ; --- PX++ ; loop while PX < 640 ---
    inc PX+0
    bne px_chk
    inc PX+1
px_chk:
    lda PX+1
    cmp #>640              ; 640 = $0280
    bne px_more
    lda PX+0
    cmp #<640
    bne px_more
    jmp row_done
px_more:
    jmp pixel_loop

row_done:
    ; --- Advance CI by SY_STEP ---
    ADD32I CI, SY_STEP

    ; --- PY++ ; loop while PY < 400 ---
    inc PY+0
    bne py_chk
    inc PY+1
py_chk:
    lda PY+1
    cmp #>400              ; 400 = $0190
    bne next_row
    lda PY+0
    cmp #<400
    bne next_row
    jmp done
next_row:
    jmp row_loop

done:
.ifdef ZOOM_ANIM
    jsr save_center_to_ram
    jsr zoom_animation
.endif

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

.ifdef ZOOM_ANIM
; ============================================================
; Zoom animation support
;
; The Mandelbrot image is calculated once.  A 160x100 centre tile is copied into
; normal RAM below $6000 and treated as the immutable source.  Every zoom frame
; re-reads that clean RAM tile and writes a fresh 640x400 hi-res image.  The VIC
; stays in hi-res mode for the whole animation, so line-buffer fetches cannot see
; mode/bank flicker from a temporary legacy-framebuffer source.
; ============================================================

save_center_to_ram:
    lda #11
    sta SRC_BANK
    lda #$F0
    sta SRCLO
    lda #$77
    sta SRCHI
    lda #<SRCBUF
    sta DSTLO
    lda #>SRCBUF
    sta DSTHI
    lda #100
    sta ROWCNT
@row:
    lda #$20
    sta VIC_MODE
    lda SRC_BANK
    sta VIC_FB_BANK
    jsr read_hires_160
    jsr add_src_480
    jsr write_ram_row160
    dec ROWCNT
    bne @row
    lda #$20
    sta VIC_MODE
    lda #0
    sta VIC_FB_BANK
    rts

zoom_animation:
@loop:
    jsr zoom4_ram
    lda #8
    jsr delay_units
    jsr zoom8_ram
    lda #12
    jsr delay_units
    jsr zoom16_ram
    lda #14
    jsr delay_units
    jmp @loop

delay_units:
    sta PIXCOL
@outer:
    ldx #$00
@mid:
    ldy #$00
@inner:
    dey
    bne @inner
    dex
    bne @mid
    dec PIXCOL
    bne @outer
    rts

zoom4_ram:
    lda #<SRCBUF
    sta SRCLO
    lda #>SRCBUF
    sta SRCHI
    jsr reset_hires_dest
    lda #100
    sta ROWCNT
@row:
    jsr read_ram_160
    jsr write_row4
    jsr write_row4
    jsr write_row4
    jsr write_row4
    dec ROWCNT
    bne @row
    lda #0
    sta VIC_FB_BANK
    rts

zoom8_ram:
    lda #<$1FC8
    sta SRCLO
    lda #>$1FC8
    sta SRCHI
    jsr reset_hires_dest
    lda #50
    sta ROWCNT
@row:
    jsr read_ram_80
    jsr add_ram_src_80
    jsr write_row8
    jsr write_row8
    jsr write_row8
    jsr write_row8
    jsr write_row8
    jsr write_row8
    jsr write_row8
    jsr write_row8
    dec ROWCNT
    bne @row
    lda #0
    sta VIC_FB_BANK
    rts

zoom16_ram:
    lda #<$275C
    sta SRCLO
    lda #>$275C
    sta SRCHI
    jsr reset_hires_dest
    lda #25
    sta ROWCNT
@row:
    jsr read_ram_40
    jsr add_ram_src_120
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    jsr write_row16
    dec ROWCNT
    bne @row
    lda #0
    sta VIC_FB_BANK
    rts

reset_hires_dest:
    lda #$20
    sta VIC_MODE
    lda #0
    sta DST_BANK
    sta DSTLO
    lda #>FB_WIN
    sta DSTHI
    sta VIC_FB_BANK
    rts

read_hires_160:
    lda SRC_BANK
    sta VIC_FB_BANK
    ldy #0
@a:
    lda (SRCLO),y
    sta BUFFER,y
    jsr inc_src_ptr
    iny
    cpy #160
    bne @a
    rts

read_ram_160:
    ldy #0
@a:
    lda (SRCLO),y
    sta BUFFER,y
    jsr inc_ram_src_ptr
    iny
    cpy #160
    bne @a
    rts

read_ram_80:
    ldy #0
@a:
    lda (SRCLO),y
    sta BUFFER,y
    jsr inc_ram_src_ptr
    iny
    cpy #80
    bne @a
    rts

read_ram_40:
    ldy #0
@a:
    lda (SRCLO),y
    sta BUFFER,y
    jsr inc_ram_src_ptr
    iny
    cpy #40
    bne @a
    rts

write_row2:
    ldx #0
@a:
    lda BUFFER,x
    sta PIXCOL
    jsr write_pix2
    inx
    bne @a
    ldx #0
@b:
    lda BUFFER2,x
    sta PIXCOL
    jsr write_pix2
    inx
    cpx #64
    bne @b
    rts

write_pix2:
    lda PIXCOL
    jsr write_dest_byte
    lda PIXCOL
    jmp write_dest_byte

write_row4:
    ldx #0
@a:
    lda BUFFER,x
    sta PIXCOL
    jsr write_pix4
    inx
    cpx #160
    bne @a
    rts

write_row8:
    ldx #0
@a:
    lda BUFFER,x
    sta PIXCOL
    jsr write_pix8
    inx
    cpx #80
    bne @a
    rts

write_row16:
    ldx #0
@a:
    lda BUFFER,x
    sta PIXCOL
    jsr write_pix16
    inx
    cpx #40
    bne @a
    rts

write_pix4:
    jsr write_pix2
    jmp write_pix2

write_pix8:
    jsr write_pix4
    jmp write_pix4

write_pix16:
    jsr write_pix8
    jmp write_pix8

write_dest_byte:
    ldy #0
    sta (DSTLO),y
    inc DSTLO
    bne @done
    inc DSTHI
    lda DSTHI
    cmp #$80
    bne @done
    lda #>FB_WIN
    sta DSTHI
    inc DST_BANK
    lda DST_BANK
    sta VIC_FB_BANK
@done:
    rts

write_ram_row160:
    ldx #0
@a:
    lda BUFFER,x
    jsr write_ram_byte
    inx
    cpx #160
    bne @a
    rts

write_ram_byte:
    ldy #0
    sta (DSTLO),y
    inc DSTLO
    bne :+
    inc DSTHI
:
    rts

inc_src_ptr:
    inc SRCLO
    bne @done
    inc SRCHI
    lda SRCHI
    cmp #$80
    bne @done
    lda #>FB_WIN
    sta SRCHI
    inc SRC_BANK
    lda SRC_BANK
    sta VIC_FB_BANK
@done:
    rts

inc_ram_src_ptr:
    inc SRCLO
    bne :+
    inc SRCHI
:
    rts

add_src_480:
    clc
    lda SRCLO
    adc #<$01E0
    sta SRCLO
    lda SRCHI
    adc #>$01E0
    sta SRCHI
    cmp #$80
    bcc @done
    sec
    sbc #$20
    sta SRCHI
    inc SRC_BANK
@done:
    rts

add_ram_src_80:
    clc
    lda SRCLO
    adc #<$0050
    sta SRCLO
    lda SRCHI
    adc #>$0050
    sta SRCHI
    rts

add_ram_src_120:
    clc
    lda SRCLO
    adc #<$0078
    sta SRCLO
    lda SRCHI
    adc #>$0078
    sta SRCHI
    rts
.endif

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
