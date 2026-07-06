; Native C64 RTI self-test diagnostic.
;
; Build:
;   make c64-rti-diag-prg
;
; No hardware IRQ is used here. The code disables interrupts, builds an RTI
; stack frame by hand, executes RTI, and expects to land in after_rti.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN     = $0400
COLOR_RAM  = $D800
BORDER     = $D020
BG_COLOR   = $D021
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
        jsr clear_screen

        lda #<title
        ldy #>title
        ldx #2
        jsr print_line
        lda #<line_fake
        ldy #>line_fake
        ldx #4
        jsr print_line
        lda #<line_count
        ldy #>line_count
        ldx #22
        jsr print_line

        lda #>after_rti            ; RTI pulls P, then PCL, then PCH.
        pha
        lda #<after_rti
        pha
        lda #$24                  ; IRQ disabled, decimal clear, bit 5 set.
        pha
        rti

bad_return:
        lda #<line_bad
        ldy #>line_bad
        ldx #10
        jsr print_line
        jmp bad_return

after_rti:
        inc count_lo
        bne no_carry
        inc count_hi
no_carry:
        lda count_lo
        and #$0F
        sta BORDER

        lda count_hi
        jsr put_hex_high
        sta SCREEN + 22 * 40 + 12
        lda count_hi
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 13
        lda count_lo
        jsr put_hex_high
        sta SCREEN + 22 * 40 + 14
        lda count_lo
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 15
        jmp after_rti

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
        .byte "C64 RTI DIAG", 0
line_fake:
        .byte "FAKE STACK FRAME THEN RTI", 0
line_bad:
        .byte "BAD RETURN AFTER RTI", 0
line_count:
        .byte "RTI COUNT $0000", 0

.segment "CODE"
count_lo:
        .res 1
count_hi:
        .res 1
