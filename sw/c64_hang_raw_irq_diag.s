; Native C64 raw-CIA-IRQ hang diagnostic.
;
; Build:
;   make c64-hang-raw-irq-diag-prg
;
; This test installs a KERNAL CINV ($0314) IRQ heartbeat. The ROM IRQ entry has
; already pushed A, X and Y before calling CINV, so this handler must pull those
; three bytes before RTI. It acknowledges CIA1 itself and stays in its own main
; loop after RUN. Reset to exit.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN     = $0400
COLOR_RAM  = $D800
BORDER     = $D020
BG_COLOR   = $D021
CIA1_ICR   = $DC0D
IRQ_VEC    = $0314
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
        lda #$00
        sta main_lo
        sta main_hi
        sta beat_lo
        sta beat_hi

        jsr clear_screen
        jsr draw_static_text

        lda #<irq_hook
        sta IRQ_VEC
        lda #>irq_hook
        sta IRQ_VEC+1

        lda #$06
        sta BORDER
        lda #$00
        sta BG_COLOR
        cli

main_loop:
        jsr delay
        inc main_lo
        bne main_no_carry
        inc main_hi
main_no_carry:
        lda main_hi
        jsr irq_put_hex_high
        sta SCREEN + 20 * 40 + 14
        lda main_hi
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 20 * 40 + 15
        lda main_lo
        jsr irq_put_hex_high
        sta SCREEN + 20 * 40 + 16
        lda main_lo
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 20 * 40 + 17
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

irq_hook:
        cld

        lda CIA1_ICR              ; acknowledge CIA1 timer IRQ

        inc beat_lo
        bne beat_no_carry
        inc beat_hi
beat_no_carry:
        lda beat_lo
        and #$0F
        sta BORDER

        lda beat_hi
        jsr irq_put_hex_high
        sta SCREEN + 22 * 40 + 17
        lda beat_hi
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 18
        lda beat_lo
        jsr irq_put_hex_high
        sta SCREEN + 22 * 40 + 19
        lda beat_lo
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 20

        pla                       ; ROM IRQ entry saved Y, X, A before CINV.
        tay
        pla
        tax
        pla
        rti

irq_put_hex_high:
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
        rts

draw_static_text:
        lda #<title
        ldy #>title
        ldx #1
        jsr print_line
        lda #<line_no_drive
        ldy #>line_no_drive
        ldx #3
        jsr print_line
        lda #<line_ready
        ldy #>line_ready
        ldx #5
        jsr print_line
        lda #<line_irq
        ldy #>line_irq
        ldx #7
        jsr print_line
        lda #<line_reset
        ldy #>line_reset
        ldx #10
        jsr print_line
        lda #<line_main
        ldy #>line_main
        ldx #20
        jsr print_line
        lda #<line_heartbeat
        ldy #>line_heartbeat
        ldx #22
        jsr print_line
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
        .byte "C64 RAW IRQ HANG DIAG", 0
line_no_drive:
        .byte "NO UART  NO IEC  NO LOAD COMMAND", 0
line_ready:
        .byte "STAYS IN OWN LOOP AFTER RUN", 0
line_irq:
        .byte "CINV IRQ ACKS CIA1 THEN RTI", 0
line_reset:
        .byte "KEYBOARD IRQ OFF - RESET TO EXIT", 0
line_main:
        .byte "MAIN COUNT  $0000", 0
line_heartbeat:
        .byte "HEARTBEAT COUNT $0000", 0

.segment "CODE"
main_lo:
        .res 1
main_hi:
        .res 1
beat_lo:
        .res 1
beat_hi:
        .res 1
