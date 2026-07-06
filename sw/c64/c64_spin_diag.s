; Native C64 absolute spin diagnostic.
;
; Build:
;   make c64-spin-diag-prg
;
; This is intentionally brutal: no IRQ setup, no KERNAL calls, no stack after
; entry, no zero-page pointers, no subroutines. It writes a few fixed screen
; cells and then loops forever while changing the border and one screen byte.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN     = $0400
BORDER     = $D020
BG_COLOR   = $D021

.segment "LOADADDR"
        .word LOAD_ADDR

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
        sta BG_COLOR
        lda #$06
        sta BORDER

        ; C64 SPIN DIAG
        lda #$03
        sta SCREEN+0
        lda #$36
        sta SCREEN+1
        lda #$34
        sta SCREEN+2
        lda #$20
        sta SCREEN+3
        lda #$13
        sta SCREEN+4
        lda #$10
        sta SCREEN+5
        lda #$09
        sta SCREEN+6
        lda #$0E
        sta SCREEN+7
        lda #$20
        sta SCREEN+8
        lda #$04
        sta SCREEN+9
        lda #$09
        sta SCREEN+10
        lda #$01
        sta SCREEN+11
        lda #$07
        sta SCREEN+12

        lda #$13                  ; S marker
        sta SCREEN+10*40

spin_loop:
        inc BORDER
        inc SCREEN+10*40
        jmp spin_loop
