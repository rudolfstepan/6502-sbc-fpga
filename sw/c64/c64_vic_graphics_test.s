; Native C64 VIC-II graphics test PRG.
;
; Build:
;   make c64-graphics-test-prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/test.prg --port COM15
;   RUN
;
; The program cycles through text, hires bitmap, multicolour bitmap, ECM text,
; and multicolour text. Press any key for the next page.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN   = $0400
COLORRAM = $D800
BITMAP   = $2000

PORTDDR  = $00
CPUPORT  = $01

VIC_D011 = $D011
VIC_D016 = $D016
VIC_D018 = $D018
VIC_D020 = $D020
VIC_D021 = $D021
VIC_D022 = $D022
VIC_D023 = $D023
VIC_D024 = $D024

CIA1_PRA  = $DC00
CIA1_PRB  = $DC01
CIA1_DDRA = $DC02
CIA1_DDRB = $DC03
CIA2_PRA  = $DD00
CIA2_DDRA = $DD02

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
SRC:    .res 2
DST:    .res 2
TMP:    .res 1

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

        lda #$FF
        sta CIA1_DDRA
        lda #$00
        sta CIA1_DDRB
        sta CIA1_PRA              ; all keyboard columns low

        lda #$03                  ; VIC bank 0 (CIA2 bits are inverted)
        sta CIA2_DDRA
        sta CIA2_PRA

main_loop:
        jsr show_text
        jsr wait_key
        jsr show_hires_bitmap
        jsr wait_key
        jsr show_multicolor_bitmap
        jsr wait_key
        jsr show_ecm_text
        jsr wait_key
        jsr show_multicolor_text
        jsr wait_key
        jmp main_loop

; ------------------------------------------------------------
; Wait until all keys are released, then wait for any key press.
wait_key:
@release:
        lda CIA1_PRB
        cmp #$FF
        bne @release
@press:
        lda CIA1_PRB
        cmp #$FF
        beq @press
        ldx #$40                  ; small debounce delay
@deb:
        dex
        bne @deb
        rts

; ------------------------------------------------------------
show_text:
        jsr text_mode
        lda #$0E
        sta VIC_D020
        lda #$06
        sta VIC_D021
        jsr clear_screen

        PRINT SCREEN + 0*40 + 5, txt_title
        PRINT SCREEN + 2*40 + 2, txt_text
        PRINT SCREEN + 4*40 + 2, txt_next
        PRINT SCREEN + 7*40 + 2, txt_palette

        ldx #$00
@bars:
        txa
        and #$0F
        sta COLORRAM + 9*40 + 12,x
        lda #$A0                  ; shifted space/full-ish block in chargen
        sta SCREEN + 9*40 + 12,x
        inx
        cpx #$10
        bne @bars
        rts

show_hires_bitmap:
        jsr bitmap_common
        lda #$00
        sta VIC_D020
        sta VIC_D021
        lda #$08                  ; hires bitmap: MCM=0, CSEL=1
        sta VIC_D016
        lda #$18                  ; screen $0400, bitmap $2000
        sta VIC_D018
        lda #$3B                  ; DEN/RSEL + BMM
        sta VIC_D011
        rts

show_multicolor_bitmap:
        jsr bitmap_common
        lda #$00
        sta VIC_D020
        sta VIC_D021
        lda #$18                  ; MCM=1, CSEL=1
        sta VIC_D016
        lda #$18                  ; screen $0400, bitmap $2000
        sta VIC_D018
        lda #$3B                  ; DEN/RSEL + BMM
        sta VIC_D011
        rts

show_ecm_text:
        jsr text_mode
        lda #$0B
        sta VIC_D020
        lda #$00
        sta VIC_D021
        lda #$02
        sta VIC_D022
        lda #$05
        sta VIC_D023
        lda #$06
        sta VIC_D024
        jsr clear_screen

        PRINT SCREEN + 0*40 + 8, txt_ecm
        PRINT SCREEN + 2*40 + 2, txt_next

        ldx #$00
@ecm:
        txa
        and #$03
        tay
        lda ecm_codes,y
        sta SCREEN + 6*40,x
        sta SCREEN + 7*40,x
        sta SCREEN + 8*40,x
        sta SCREEN + 9*40,x
        lda #$01
        sta COLORRAM + 6*40,x
        sta COLORRAM + 7*40,x
        sta COLORRAM + 8*40,x
        sta COLORRAM + 9*40,x
        inx
        cpx #40
        bne @ecm

        lda #$5B                  ; ECM + DEN/RSEL
        sta VIC_D011
        rts

show_multicolor_text:
        jsr text_mode
        lda #$0C
        sta VIC_D020
        lda #$00
        sta VIC_D021
        lda #$02
        sta VIC_D022
        lda #$05
        sta VIC_D023
        jsr clear_screen

        PRINT SCREEN + 0*40 + 5, txt_mctext
        PRINT SCREEN + 2*40 + 2, txt_next

        ldx #$00
@mc:
        txa
        and #$0F
        tay
        lda mc_chars,y
        sta SCREEN + 6*40,x
        sta SCREEN + 7*40,x
        sta SCREEN + 8*40,x
        lda mc_colors,y
        sta COLORRAM + 6*40,x
        sta COLORRAM + 7*40,x
        sta COLORRAM + 8*40,x
        inx
        cpx #40
        bne @mc

        lda #$18                  ; multicolour text
        sta VIC_D016
        rts

; ------------------------------------------------------------
text_mode:
        lda #$1B
        sta VIC_D011
        lda #$08
        sta VIC_D016
        lda #$15                  ; screen $0400, chargen default
        sta VIC_D018
        rts

bitmap_common:
        jsr fill_bitmap
        jsr fill_bitmap_attrs
        rts

fill_bitmap:
        lda #<BITMAP
        sta DST
        lda #>BITMAP
        sta DST+1
        ldx #$20                  ; $2000-$3FFF
@page:
        ldy #$00
@byte:
        tya
        eor DST+1
        and #$11
        beq @mcpat
        lda #$AA                  ; hires: alternating pixels
        bne @store
@mcpat:
        lda #$1B                  ; multicolour pairs 00,01,10,11
@store:
        sta (DST),y
        iny
        bne @byte
        inc DST+1
        dex
        bne @page
        rts

fill_bitmap_attrs:
        ldx #$00
@lp:
        txa
        and #$0F
        sta TMP
        txa
        lsr a
        lsr a
        lsr a
        lsr a
        asl a
        asl a
        asl a
        asl a
        ora TMP
        sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x

        txa
        and #$0F
        sta COLORRAM+$000,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne @lp
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
txt_title:   .byte "C64 VIC-II GRAPHICS TEST", 0
txt_text:    .byte "TEXT MODE AND 16 COLOUR RAM CELLS", 0
txt_palette: .byte "PALETTE:", 0
txt_next:    .byte "PRESS ANY KEY FOR NEXT MODE", 0
txt_ecm:     .byte "ECM TEXT BACKGROUNDS", 0
txt_mctext:  .byte "MULTICOLOUR TEXT MODE", 0

ecm_codes:   .byte $01, $41, $81, $C1
mc_chars:    .byte 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
mc_colors:   .byte $8E,$8A,$8D,$87,$85,$83,$8C,$8F
             .byte $8E,$8A,$8D,$87,$85,$83,$8C,$8F
