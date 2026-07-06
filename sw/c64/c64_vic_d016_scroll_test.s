; Native C64 VIC-II $D016 fine-scroll/raster-split test PRG.
;
; Build:
;   make c64-d016-scroll-test-prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/d016_scroll_test.prg --port COM15
;   RUN
;
; The program keeps a static text screen and changes $D016 at three raster
; positions every frame.  TOP and MIDDLE write before their text bands and
; should scroll smoothly.  LOWER writes deliberately inside the band and should
; show a tear; that gives us a known-bad reference on the same screen.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN   = $0400
COLORRAM = $D800

PORTDDR  = $00
CPUPORT  = $01

VIC_D011 = $D011
VIC_D012 = $D012
VIC_D016 = $D016
VIC_D018 = $D018
VIC_D020 = $D020
VIC_D021 = $D021

CIA1_ICR = $DC0D
CIA2_PRA  = $DD00
CIA2_DDRA = $DD02
CIA2_ICR = $DD0D

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
SRC:    .res 2
DST:    .res 2
PHASE:  .res 1
TARGET: .res 1

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"
.macro PRINT where, what
        lda #<((where))
        sta DST
        lda #>((where))
        sta DST+1
        lda #<((what))
        sta SRC
        lda #>((what))
        sta SRC+1
        jsr print
.endmacro

start:
        sei
        cld

        lda #$37
        sta CPUPORT
        lda #$2F
        sta PORTDDR

        lda #$7F
        sta CIA1_ICR              ; disable CIA IRQ sources
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR

        lda #$03                  ; VIC bank 0 (CIA2 bits are inverted)
        sta CIA2_DDRA
        sta CIA2_PRA

        lda #$1B                  ; text mode, display enabled
        sta VIC_D011
        lda #$08                  ; CSEL=1, fine X=0
        sta VIC_D016
        lda #$15                  ; screen $0400, default chargen
        sta VIC_D018
        lda #$00
        sta VIC_D020
        sta VIC_D021

        jsr clear_screen
        jsr draw_text

        lda #$00
        sta PHASE

main:
        lda #250
        jsr wait_raster
        lda #40
        jsr wait_raster

        ; Top band: early write before screen row 3 starts (visible row ~74).
        lda #68
        jsr wait_raster
        lda PHASE
        jsr set_d016

        ; Middle band: early write before screen row 7 starts (visible row ~106).
        lda #100
        jsr wait_raster
        lda PHASE
        clc
        adc #3
        and #7
        jsr set_d016

        ; Lower band: deliberately late, inside row 11.  This one should tear.
        lda #142
        jsr wait_raster
        lda PHASE
        clc
        adc #6
        and #7
        jsr set_d016

        ; Restore default before the next frame wrap.
        lda #250
        jsr wait_raster
        lda #0
        jsr set_d016

        inc PHASE
        lda PHASE
        and #7
        sta PHASE
        jmp main

set_d016:
        and #7
        ora #$08                  ; keep CSEL=1
        sta VIC_D016
        rts

wait_raster:
        sta TARGET
@wait_high_clear:
        lda VIC_D011
        bmi @wait_high_clear      ; all test targets are below raster 256
@wait_line:
        lda VIC_D012
        cmp TARGET
        bne @wait_line
        rts

draw_text:
        PRINT SCREEN + 0*40 + 5, txt_title
        PRINT SCREEN + 1*40 + 1, txt_help

        PRINT SCREEN + 3*40 + 2, txt_top
        PRINT SCREEN + 4*40 + 0, txt_pattern_a
        PRINT SCREEN + 5*40 + 0, txt_pattern_b

        PRINT SCREEN + 7*40 + 2, txt_mid
        PRINT SCREEN + 8*40 + 0, txt_pattern_a
        PRINT SCREEN + 9*40 + 0, txt_pattern_b

        PRINT SCREEN + 11*40 + 2, txt_low
        PRINT SCREEN + 12*40 + 0, txt_pattern_a
        PRINT SCREEN + 13*40 + 0, txt_pattern_b

        ldx #$00
@colors:
        lda #$0D
        sta COLORRAM + 3*40,x
        sta COLORRAM + 4*40,x
        sta COLORRAM + 5*40,x
        lda #$0E
        sta COLORRAM + 7*40,x
        sta COLORRAM + 8*40,x
        sta COLORRAM + 9*40,x
        lda #$05
        sta COLORRAM + 11*40,x
        sta COLORRAM + 12*40,x
        sta COLORRAM + 13*40,x
        inx
        cpx #40
        bne @colors
        rts

clear_screen:
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

print:
        ldy #$00
@lp:
        lda (SRC),y
        beq @done
        cmp #$40
        bcc @store
        cmp #$60
        bcs @store
        sec
        sbc #$40
@store:
        sta (DST),y
        iny
        bne @lp
@done:
        rts

.segment "RODATA"
txt_title:     .byte "C64 VIC-II D016 SCROLL TEST", 0
txt_help:      .byte "TOP/MID SHOULD BE SMOOTH - LOWER SHOULD TEAR", 0
txt_top:       .byte "TOP EARLY WRITE - SHOULD BE SMOOTH", 0
txt_mid:       .byte "MIDDLE EARLY WRITE - SHOULD BE SMOOTH", 0
txt_low:       .byte "LOWER LATE WRITE - EXPECT TEAR", 0
txt_pattern_a: .byte "01234567 01234567 01234567 01234567 ", 0
txt_pattern_b: .byte "ABCDEFGH ABCDEFGH ABCDEFGH ABCDEFGH ", 0
