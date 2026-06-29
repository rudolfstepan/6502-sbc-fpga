; Native C64 no-drive hang diagnostic.
;
; Build:
;   make c64-hang-diag-prg
;
; Workflow:
;   1. Upload roms/hang_diag.prg with tools/c64_uart_prg_loader.py.
;   2. Type RUN on the C64.
;   3. The program returns to BASIC READY and leaves an IRQ heartbeat running.
;      If the machine hangs, the heartbeat counter and border color stop.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN     = $0400
COLOR_RAM  = $D800
BORDER     = $D020
BG_COLOR   = $D021
IRQ_VEC    = $0314
ILOAD      = $0330
KLOAD_JMP  = $FFD5
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
        sta beat_lo
        sta beat_hi

        lda IRQ_VEC
        cmp #<irq_hook
        bne save_irq_vector
        lda IRQ_VEC+1
        cmp #>irq_hook
        beq irq_vector_saved
save_irq_vector:
        lda IRQ_VEC
        sta old_irq
        lda IRQ_VEC+1
        sta old_irq+1
irq_vector_saved:

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
        rts

irq_hook:
        cld

        inc beat_lo
        bne beat_no_carry
        inc beat_hi
beat_no_carry:
        lda beat_lo
        and #$0F
        sta BORDER

        lda beat_hi
        jsr irq_put_hex
        sta SCREEN + 22 * 40 + 17
        lda beat_hi
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 18
        lda beat_lo
        jsr irq_put_hex
        sta SCREEN + 22 * 40 + 19
        lda beat_lo
        and #$0F
        jsr nibble_to_screen
        sta SCREEN + 22 * 40 + 20

        jmp (old_irq)

irq_put_hex:
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
        lda #<line_kload
        ldy #>line_kload
        ldx #10
        jsr print_line
        lda KLOAD_JMP
        jsr print_hex_at_cursor
        lda KLOAD_JMP+1
        jsr print_hex_at_cursor
        lda KLOAD_JMP+2
        jsr print_hex_at_cursor
        lda #<line_iload
        ldy #>line_iload
        ldx #12
        jsr print_line
        lda ILOAD+1
        jsr print_hex_at_cursor
        lda ILOAD
        jsr print_hex_at_cursor
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
        sty cursor_col
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

print_hex_at_cursor:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr print_nibble_at_cursor
        pla
        and #$0F
print_nibble_at_cursor:
        cmp #$0A
        bcc print_hex_digit
        adc #$06
print_hex_digit:
        adc #$30
        jsr ascii_to_screen
        ldy cursor_col
        sta (ZP_DST),y
        inc cursor_col
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
        .byte "C64 NO DRIVE HANG DIAG", 0
line_no_drive:
        .byte "NO UART  NO IEC  NO LOAD COMMAND", 0
line_ready:
        .byte "RETURNS TO BASIC READY AFTER RUN", 0
line_irq:
        .byte "IRQ HEARTBEAT SHOULD KEEP COUNTING", 0
line_kload:
        .byte "KERNAL FFD5 BYTES: $", 0
line_iload:
        .byte "LOAD VECTOR 0330:  $", 0
line_heartbeat:
        .byte "HEARTBEAT COUNT $0000", 0

.segment "CODE"
old_irq:
        .res 2
beat_lo:
        .res 1
beat_hi:
        .res 1
cursor_col:
        .res 1
