; Native C64 CLI/no-IRQ diagnostic.
;
; Build:
;   make c64-cli-noirq-diag-prg
;
; This test masks/acks CIA1, CIA2 and VIC IRQ sources, then executes CLI and
; stays in its own loop. If this runs, CLI itself and the CPU IRQ input high
; state are fine; the remaining suspect is an active IRQ source or RTI path.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN     = $0400
COLOR_RAM  = $D800
BORDER     = $D020
BG_COLOR   = $D021
VIC_IRQ    = $D019
VIC_IRQEN  = $D01A
CIA1_ICR   = $DC0D
CIA2_ICR   = $DD0D
ZP_SRC     = $FB
ZP_DST     = $FD

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
tmp:    .res 1

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"
start:
        sei
        cld

        lda #$7F                  ; clear all CIA ICR mask bits
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR              ; acknowledge pending CIA IRQ flags
        lda CIA2_ICR
        lda #$00
        sta VIC_IRQEN             ; disable VIC IRQ sources
        lda #$FF
        sta VIC_IRQ               ; acknowledge pending VIC flags

        jsr clear_screen
        lda #<title
        ldy #>title
        ldx #2
        jsr print_line
        lda #<line_masked
        ldy #>line_masked
        ldx #4
        jsr print_line
        lda #<line_cli
        ldy #>line_cli
        ldx #6
        jsr print_line
        lda #<line_count
        ldy #>line_count
        ldx #22
        jsr print_line

        cli

main_loop:
        jsr delay
        inc count_lo
        bne no_carry
        inc count_hi
no_carry:
        lda count_lo
        and #$0F
        sta BORDER

        lda count_hi
        jsr put_hex_high
        sta SCREEN + 22 * 40 + 13
        lda count_hi
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 14
        lda count_lo
        jsr put_hex_high
        sta SCREEN + 22 * 40 + 15
        lda count_lo
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 16
        jmp main_loop

delay:
        ldx #$30
delay_outer:
        ldy #$00
delay_inner:
        dey
        bne delay_inner
        dex
        bne delay_outer
        rts

put_hex_high:
        lsr
        lsr
        lsr
        lsr
nibble_to_screen:
        and #$0F
        cmp #$0A
        bcc hex_digit
        adc #$06
hex_digit:
        adc #$30
        jsr ascii_to_screen
        rts

clear_screen:
        lda #$20
        ldx #$00
clear_screen_loop:
        sta SCREEN,x
        sta SCREEN+$0100,x
        sta SCREEN+$0200,x
        cpx #$E8
        bcs clear_screen_skip_page3
        sta SCREEN+$0300,x
clear_screen_skip_page3:
        inx
        bne clear_screen_loop

        lda #$0E
        ldx #$00
clear_color_loop:
        sta COLOR_RAM,x
        sta COLOR_RAM+$0100,x
        sta COLOR_RAM+$0200,x
        cpx #$E8
        bcs clear_color_skip_page3
        sta COLOR_RAM+$0300,x
clear_color_skip_page3:
        inx
        bne clear_color_loop
        lda #$00
        sta BG_COLOR
        rts

; A/Y = zero-terminated ASCII text, X = screen row.
print_line:
        sta ZP_SRC
        sty ZP_SRC+1
        txa
        jsr row_to_screen
        ldy #$00
print_line_loop:
        lda (ZP_SRC),y
        beq print_line_done
        jsr ascii_to_screen
        sta (ZP_DST),y
        iny
        bne print_line_loop
print_line_done:
        rts

row_to_screen:
        sta tmp
        lda #<SCREEN
        sta ZP_DST
        lda #>SCREEN
        sta ZP_DST+1
row_loop:
        lda tmp
        beq row_done
        clc
        lda ZP_DST
        adc #40
        sta ZP_DST
        lda ZP_DST+1
        adc #0
        sta ZP_DST+1
        dec tmp
        jmp row_loop
row_done:
        rts

ascii_to_screen:
        cmp #'A'
        bcc ascii_done
        cmp #'Z' + 1
        bcs ascii_done
        sec
        sbc #$40
ascii_done:
        rts

.segment "RODATA"
title:
        .byte "C64 CLI NOIRQ DIAG", 0
line_masked:
        .byte "CIA1 CIA2 AND VIC IRQ MASKED", 0
line_cli:
        .byte "CLI EXECUTED - LOOP SHOULD RUN", 0
line_count:
        .byte "LOOP COUNT $0000", 0

.segment "CODE"
count_lo:
        .res 1
count_hi:
        .res 1
