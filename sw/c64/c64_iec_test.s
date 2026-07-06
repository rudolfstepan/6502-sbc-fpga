; C64 CIA2/IEC test ROM.
;
; 8 KiB KERNAL-slot replacement linked with sw/c64diag.cfg. It boots directly
; from reset and checks CIA2 port A readback while keeping PA0/PA1 at %11 so
; the VIC remains in bank 0 and the screen at $0400 stays visible.

.setcpu "6502"

SCREEN    = $0400
COLORRAM  = $D800
VIC_BORD  = $D020
VIC_BG    = $D021
VIC_D011  = $D011
VIC_D016  = $D016
VIC_D018  = $D018
CIA2_PRA  = $DD00
CIA2_DDRA = $DD02
PORTDDR   = $00
CPUPORT   = $01

.segment "ZEROPAGE"
SCRPTR: .res 2
STRPTR: .res 2
LINE:   .res 2
WRVAL:  .res 1
RDVAL:  .res 1
EXPVAL: .res 1
FAILS:  .res 1
TMP:    .res 1

.segment "CODE"

reset:
        sei
        cld
        ldx #$ff
        txs

        lda #$37
        sta CPUPORT
        lda #$2f
        sta PORTDDR

        lda #$00
        sta VIC_BORD
        sta VIC_BG
        lda #$1b
        sta VIC_D011
        lda #$08
        sta VIC_D016
        lda #$14
        sta VIC_D018

        lda #$3f
        sta CIA2_DDRA
        lda #$3f
        sta CIA2_PRA

        jsr clrscr

        lda #<SCREEN
        sta LINE
        sta SCRPTR
        lda #>SCREEN
        sta LINE+1
        sta SCRPTR+1

        lda #<txt_title
        ldy #>txt_title
        jsr puts
        jsr newline
        lda #<txt_sub
        ldy #>txt_sub
        jsr puts
        jsr newline
        jsr newline
        lda #<txt_head
        ldy #>txt_head
        jsr puts
        jsr newline

        lda #$00
        sta FAILS
        ldx #$00

test_loop:
        lda patterns,x
        cmp #$ff
        beq done_tests
        sta WRVAL

        ; Exercise CIA2 PA while preserving VIC bank bits PA0/PA1 = 1.
        lda #$3f
        sta CIA2_DDRA
        lda WRVAL
        sta CIA2_PRA
        nop
        nop
        lda CIA2_PRA
        sta RDVAL

        ; Release IEC-like outputs and keep VIC bank 0 before touching screen.
        lda #$3f
        sta CIA2_PRA

        lda WRVAL
        and #$3f
        sta EXPVAL
        lda WRVAL
        and #$10
        beq @no_clk_in
        lda EXPVAL
        ora #$40
        sta EXPVAL
@no_clk_in:
        lda WRVAL
        and #$20
        beq @no_data_in
        lda EXPVAL
        ora #$80
        sta EXPVAL
@no_data_in:

        lda #<txt_wr
        ldy #>txt_wr
        jsr puts
        lda WRVAL
        jsr puthex
        lda #<txt_rd
        ldy #>txt_rd
        jsr puts
        lda RDVAL
        jsr puthex
        lda #<txt_ex
        ldy #>txt_ex
        jsr puts
        lda EXPVAL
        jsr puthex
        lda #$20
        jsr putc

        lda RDVAL
        cmp EXPVAL
        beq pass
        inc FAILS
        lda #<txt_fail
        ldy #>txt_fail
        jsr puts
        jmp row_done
pass:
        lda #<txt_pass
        ldy #>txt_pass
        jsr puts
row_done:
        jsr newline
        inx
        jmp test_loop

done_tests:
        jsr newline
        lda #<txt_fails
        ldy #>txt_fails
        jsr puts
        lda FAILS
        jsr puthex
        jsr newline
        lda #<txt_loop
        ldy #>txt_loop
        jsr puts

heartbeat:
        inc VIC_BORD
        lda #$3f
        sta CIA2_DDRA
        sta CIA2_PRA
        ldx #$00
delay1:
        ldy #$00
delay2:
        dey
        bne delay2
        dex
        bne delay1
        jmp heartbeat

clrscr:
        ldx #$00
@lp:
        lda #$20
        sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        lda #$01
        sta COLORRAM+$000,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne @lp
        rts

newline:
        lda LINE
        clc
        adc #40
        sta LINE
        sta SCRPTR
        lda LINE+1
        adc #0
        sta LINE+1
        sta SCRPTR+1
        rts

puts:
        sta STRPTR
        sty STRPTR+1
        ldy #$00
@lp:
        lda (STRPTR),y
        beq @done
        jsr putc
        iny
        bne @lp
@done:
        rts

putc:
        sta TMP
        tya
        pha
        lda TMP
        ldy #$00
        cmp #$40
        bcc @store
        cmp #$60
        bcs @store
        sec
        sbc #$40
@store:
        sta (SCRPTR),y
        inc SCRPTR
        bne @done
        inc SCRPTR+1
@done:
        pla
        tay
        rts

puthex:
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr hexdig
        jsr putc
        pla
        and #$0f
        jsr hexdig
        jsr putc
        rts

hexdig:
        cmp #10
        bcc @digit
        sec
        sbc #9
        rts
@digit:
        clc
        adc #$30
        rts

nmi:
        rti

irq:
        rti

.segment "RODATA"
txt_title: .byte "CIA2 IEC TEST ROM",0
txt_sub:   .byte "PORT A READBACK, VIC BANK HELD AT 0",0
txt_head:  .byte "WRITE  READ  EXPECT STATUS",0
txt_wr:    .byte "$",0
txt_rd:    .byte "    $",0
txt_ex:    .byte "    $",0
txt_pass:  .byte "PASS",0
txt_fail:  .byte "FAIL",0
txt_fails: .byte "FAILS: $",0
txt_loop:  .byte "BORDER CYCLES = CPU STILL RUNS",0

; PA0/PA1 stay high (%11) so VIC bank 0 remains selected. Bits PA3/PA4/PA5
; cover ATN/CLK/DATA-style activity for the experimental IEC model.
patterns:
        .byte $03,$0b,$13,$1b,$23,$2b,$33,$3b,$ff

.segment "VECTORS"
        .word nmi
        .word reset
        .word irq
