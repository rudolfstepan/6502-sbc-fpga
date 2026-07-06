; Native C64 Mandelbrot demo.
;
; Build:
;   make c64-mandelbrot-prg          ; CPU-only: roms/c64/prg/mandelbrot.prg
;   make c64-mandelbrot-copro-prg    ; $DEB0:    roms/c64/prg/mandelbrot-copo.prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/c64/prg/mandelbrot.prg --port COM15
;   RUN
;
; The existing SBC Mandelbrot demo uses a custom RGB222 framebuffer. This C64
; variant keeps the same 8.24 fixed-point view but renders into a real VIC-II
; multicolour bitmap at $2000.  Define USE_COPRO=1 to use the C64 DDR math
; coprocessor window at $DEB0-$DEBF.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

PORTDDR  = $00
CPUPORT  = $01

SCREEN   = $0400
BITMAP   = $2000
COLORRAM = $D800

.ifdef USE_COPRO
; Math coprocessor at I/O1: $DEB0-$DEBF.
MUL       = $DEB0
MUL_A     = MUL+0
MUL_B     = MUL+4
MUL_RES   = MUL+8
MUL_SHIFT = MUL+12
.endif

VIC_D011 = $D011
VIC_D016 = $D016
VIC_D018 = $D018
VIC_D019 = $D019
VIC_D01A = $D01A
VIC_D020 = $D020
VIC_D021 = $D021

CIA1_PRA  = $DC00
CIA1_PRB  = $DC01
CIA1_DDRA = $DC02
CIA1_DDRB = $DC03
CIA1_ICR  = $DC0D
CIA2_PRA  = $DD00
CIA2_DDRA = $DD02
CIA2_ICR  = $DD0D

; 160x200 C64 multicolour bitmap.  Four 2-bit pixels are packed per byte.
WIDTH_PIXELS = 160
HEIGHT_ROWS  = 200
BYTES_PER_ROW = 40

; 8.24 Mandelbrot view.  160 * 3/128 = 3.75 wide, 200 * 1/80 = 2.5 tall.
X_LEFT      = $FD600000     ; -2.625
CI_START    = $FEC00000     ; -1.25
SX_STEP     = $00060000     ; 3/128
SY_STEP     = $00033333     ; 1/80, rounded down in 8.24
ESCAPE_INT  = $04
MAX_ITER    = 32

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
ZR:       .res 4
ZI:       .res 4
CR:       .res 4
CI:       .res 4
ZR2:      .res 4
ZI2:      .res 4
PROD:     .res 4
SUM:      .res 4
ROWLO:    .res 1
ROWHI:    .res 1
BMPLO:    .res 1
BMPHI:    .res 1
ITER:     .res 1
PIXEL:    .res 1
PIXBYTE:  .res 1
PACKCNT:  .res 1
GROUP:    .res 1
PY:       .res 1
PTRLO:    .res 1
PTRHI:    .res 1
MULA:     .res 4
MULB:     .res 4
MCAND:    .res 8
ACC64:    .res 8
MSIGN:    .res 1
MCOUNT:   .res 1

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"

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
.ifdef USE_COPRO
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
        nop
        nop
        nop
        nop
        lda MUL_RES+0
        sta dst+0
        lda MUL_RES+1
        sta dst+1
        lda MUL_RES+2
        sta dst+2
        lda MUL_RES+3
        sta dst+3
.else
        lda opA+0
        sta MULA+0
        lda opA+1
        sta MULA+1
        lda opA+2
        sta MULA+2
        lda opA+3
        sta MULA+3
        lda opB+0
        sta MULB+0
        lda opB+1
        sta MULB+1
        lda opB+2
        sta MULB+2
        lda opB+3
        sta MULB+3
        jsr mul32_sw
        lda PROD+0
        sta dst+0
        lda PROD+1
        sta dst+1
        lda PROD+2
        sta dst+2
        lda PROD+3
        sta dst+3
.endif
.endmacro

start:
        sei
        cld

        lda #$37
        sta CPUPORT
        lda #$2F
        sta PORTDDR

        lda #$7F
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR
        lda #$00
        sta VIC_D01A
        lda #$FF
        sta VIC_D019

        ; VIC bank 0 ($0000-$3FFF), bitmap $2000, screen $0400.
        lda #$03
        sta CIA2_DDRA
        sta CIA2_PRA

        lda #$06                  ; blue/cyan border: setup alive
        sta VIC_D020
        lda #$00
        sta VIC_D021

.ifdef USE_COPRO
        lda #24
        sta MUL_SHIFT

        jsr math_selftest
        bcc math_ok
        lda #$02                  ; red border: $DEB0 self-test failed
        sta VIC_D020
math_fail:
        jmp math_fail

math_ok:
.endif
        jsr clear_bitmap
        jsr init_bitmap_colours

        lda #$18                  ; multicolour bitmap, 40 columns
        sta VIC_D016
        lda #$18                  ; screen $0400, bitmap $2000
        sta VIC_D018
        lda #$3B                  ; bitmap mode, DEN on while rendering
        sta VIC_D011

        LD32I CI, CI_START
        lda #<BITMAP
        sta ROWLO
        lda #>BITMAP
        sta ROWHI
        lda #0
        sta PY

row_loop:
        lda PY                    ; visible progress while rows are rendered
        and #$07
        ora #$08
        sta VIC_D020

        LD32I CR, X_LEFT

        lda ROWLO
        sta BMPLO
        lda ROWHI
        sta BMPHI

        lda #0
        sta GROUP

group_loop:
        lda #0
        sta PIXBYTE
        lda #4
        sta PACKCNT

pixel_pack_loop:
        jsr calc_pixel

        lda PIXBYTE
        asl
        asl
        ora PIXEL
        sta PIXBYTE

        ADD32I CR, SX_STEP

        dec PACKCNT
        bne pixel_pack_loop

        lda PIXBYTE
        jsr store_bitmap_byte

        inc GROUP
        lda GROUP
        cmp #BYTES_PER_ROW
        bne group_loop

        ADD32I CI, SY_STEP

        inc PY
        lda PY
        cmp #HEIGHT_ROWS
        beq render_done
        jsr advance_row_pointer
        jmp row_loop

render_done:
        lda #$3B                  ; show the finished bitmap
        sta VIC_D011
        lda #$05                  ; green border means done
        sta VIC_D020
halt:
        jmp halt

.ifdef USE_COPRO
; Carry clear = $DEB0 math coprocessor passed.  Carry set = readback failed.
math_selftest:
        lda #24
        sta MUL_SHIFT

        lda #$00                  ; A = 1.0 in 8.24 = $01000000
        sta MUL_A+0
        sta MUL_A+1
        sta MUL_A+2
        lda #$01
        sta MUL_A+3

        lda #$00                  ; B = 1.0 in 8.24
        sta MUL_B+0
        sta MUL_B+1
        sta MUL_B+2
        lda #$01
        sta MUL_B+3
        nop
        nop
        nop
        nop

        lda MUL_RES+0
        ora MUL_RES+1
        ora MUL_RES+2
        bne @fail
        lda MUL_RES+3
        cmp #$01
        bne @fail
        clc
        rts
@fail:
        sec
        rts
.endif

; Compute one Mandelbrot sample.  Result is a 2-bit multicolour value in PIXEL.
calc_pixel:
        lda #0
        sta PIXEL
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
        rts

escaped:
        lda #MAX_ITER
        sec
        sbc ITER
        tax
        lda colour_table,x
        sta PIXEL
        rts

; Signed 8.24 multiply:
;   MULA = operand A, MULB = operand B
;   PROD = (MULA * MULB) >> 24
; Uses unsigned shift/add on absolute values, then negates the full 64-bit
; product before extracting bytes 3..6 when the result should be negative.
mul32_sw:
        lda MULA+3
        eor MULB+3
        and #$80
        sta MSIGN

        lda MULA+3
        bpl :+
        jsr neg_mula
:
        lda MULB+3
        bpl :+
        jsr neg_mulb
:
        lda #0
        ldx #7
@clr:
        sta ACC64,x
        sta MCAND,x
        dex
        bpl @clr

        lda MULB+0
        sta MCAND+0
        lda MULB+1
        sta MCAND+1
        lda MULB+2
        sta MCAND+2
        lda MULB+3
        sta MCAND+3

        lda #32
        sta MCOUNT
@loop:
        lda MULA+0
        and #1
        beq @skip_add
        clc
        ldx #0
@add:
        lda ACC64,x
        adc MCAND,x
        sta ACC64,x
        inx
        cpx #8
        bne @add
@skip_add:
        lsr MULA+3
        ror MULA+2
        ror MULA+1
        ror MULA+0

        asl MCAND+0
        rol MCAND+1
        rol MCAND+2
        rol MCAND+3
        rol MCAND+4
        rol MCAND+5
        rol MCAND+6
        rol MCAND+7

        dec MCOUNT
        bne @loop

        lda MSIGN
        beq @positive
        jsr neg_acc64
@positive:
        lda ACC64+3
        sta PROD+0
        lda ACC64+4
        sta PROD+1
        lda ACC64+5
        sta PROD+2
        lda ACC64+6
        sta PROD+3
        rts

neg_mula:
        sec
        lda #0
        sbc MULA+0
        sta MULA+0
        lda #0
        sbc MULA+1
        sta MULA+1
        lda #0
        sbc MULA+2
        sta MULA+2
        lda #0
        sbc MULA+3
        sta MULA+3
        rts

neg_mulb:
        sec
        lda #0
        sbc MULB+0
        sta MULB+0
        lda #0
        sbc MULB+1
        sta MULB+1
        lda #0
        sbc MULB+2
        sta MULB+2
        lda #0
        sbc MULB+3
        sta MULB+3
        rts

neg_acc64:
        sec
        lda #0
        sbc ACC64+0
        sta ACC64+0
        lda #0
        sbc ACC64+1
        sta ACC64+1
        lda #0
        sbc ACC64+2
        sta ACC64+2
        lda #0
        sbc ACC64+3
        sta ACC64+3
        lda #0
        sbc ACC64+4
        sta ACC64+4
        lda #0
        sbc ACC64+5
        sta ACC64+5
        lda #0
        sbc ACC64+6
        sta ACC64+6
        lda #0
        sbc ACC64+7
        sta ACC64+7
        rts

store_bitmap_byte:
        ldy #0
        sta (BMPLO),y
        clc
        lda BMPLO
        adc #8
        sta BMPLO
        bcc :+
        inc BMPHI
:
        rts

advance_row_pointer:
        lda PY
        and #$07
        beq @next_char_row
        clc
        lda ROWLO
        adc #1
        sta ROWLO
        bcc :+
        inc ROWHI
:
        rts

@next_char_row:
        clc
        lda ROWLO
        adc #$39                  ; 313 bytes: $2007 -> $2140
        sta ROWLO
        lda ROWHI
        adc #$01
        sta ROWHI
        rts

clear_bitmap:
        lda #<BITMAP
        sta PTRLO
        lda #>BITMAP
        sta PTRHI
        ldx #$20                  ; $2000-$3FFF
        lda #0
@page:
        ldy #0
@byte:
        sta (PTRLO),y
        iny
        bne @byte
        inc PTRHI
        dex
        bne @page
        rts

init_bitmap_colours:
        ldx #0
@lp:
        lda #$5E                  ; 01=green, 10=light blue
        sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x

        lda #$01                  ; 11=white
        sta COLORRAM+$000,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne @lp
        rts

.segment "RODATA"
colour_table:
        .byte 1,1,1,1,2,2,2,2
        .byte 3,3,3,2,2,1,1,2
        .byte 3,3,2,1,2,3,2,1
        .byte 1,2,2,3,3,2,1,3
