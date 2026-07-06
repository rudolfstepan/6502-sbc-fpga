; Native C64 VIC-II sprite test PRG.
;
; Build:
;   make c64-sprite-test-prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/sprite_test.prg --port COM15
;   RUN
;
; Shows four hardware sprites: hires, multicolour, expanded, and X-MSB.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN   = $0400
COLORRAM = $D800
SPR0     = $3000
SPR1     = $3040
SPR2     = $3080
SPR3     = $30C0

PORTDDR  = $00
CPUPORT  = $01

VIC_D000 = $D000
VIC_D001 = $D001
VIC_D002 = $D002
VIC_D003 = $D003
VIC_D004 = $D004
VIC_D005 = $D005
VIC_D006 = $D006
VIC_D007 = $D007
VIC_D010 = $D010
VIC_D011 = $D011
VIC_D015 = $D015
VIC_D016 = $D016
VIC_D017 = $D017
VIC_D018 = $D018
VIC_D01B = $D01B
VIC_D01C = $D01C
VIC_D01D = $D01D
VIC_D020 = $D020
VIC_D021 = $D021
VIC_D025 = $D025
VIC_D026 = $D026
VIC_D027 = $D027
VIC_D028 = $D028
VIC_D029 = $D029
VIC_D02A = $D02A

CIA2_PRA  = $DD00
CIA2_DDRA = $DD02

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
SRC:    .res 2
DST:    .res 2
XPOS:   .res 1
DIR:    .res 1
FRAME:  .res 1

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

        lda #$03                  ; VIC bank 0 (CIA2 bits are inverted)
        sta CIA2_DDRA
        sta CIA2_PRA

        jsr text_mode
        jsr clear_screen
        jsr draw_labels
        jsr make_sprites
        jsr setup_sprites

        lda #$30
        sta XPOS
        lda #$01
        sta DIR
        lda #$00
        sta FRAME

main_loop:
        jsr delay_tick
        jsr move_sprites
        jmp main_loop

delay_tick:
        ldx #$18
@outer:
        ldy #$00
@inner:
        dey
        bne @inner
        dex
        bne @outer
        rts

move_sprites:
        lda DIR
        bne @right
        dec XPOS
        lda XPOS
        cmp #$30
        bne @store
        lda #$01
        sta DIR
        bne @store
@right:
        inc XPOS
        lda XPOS
        cmp #$D8
        bne @store
        lda #$00
        sta DIR
@store:
        lda XPOS
        sta VIC_D000

        clc
        adc #$48
        sta VIC_D002

        lda #$F8
        sec
        sbc XPOS
        sta VIC_D004

        lda XPOS
        clc
        adc #$E0
        sta VIC_D006
        lda #%00001000            ; sprite 3 stays in the X-MSB range
        sta VIC_D010
        rts

text_mode:
        lda #$1B
        sta VIC_D011
        lda #$08
        sta VIC_D016
        lda #$15                  ; screen $0400, default CHARGEN
        sta VIC_D018
        lda #$00
        sta VIC_D020
        sta VIC_D021
        rts

setup_sprites:
        lda #$C0                  ; $3000 / 64
        sta SCREEN+$03F8
        lda #$C1
        sta SCREEN+$03F9
        lda #$C2
        sta SCREEN+$03FA
        lda #$C3
        sta SCREEN+$03FB

        lda XPOS
        sta VIC_D000
        lda #$46
        sta VIC_D001

        lda #$78
        sta VIC_D002
        lda #$72
        sta VIC_D003

        lda #$B8
        sta VIC_D004
        lda #$A0
        sta VIC_D005

        lda #$18                  ; X=280 via $D010 bit 3
        sta VIC_D006
        lda #$CE
        sta VIC_D007

        lda #%00001000            ; sprite 3 X MSB
        sta VIC_D010
        lda #%00001111            ; enable sprites 0-3
        sta VIC_D015
        lda #%00000100            ; sprite 2 Y-expanded
        sta VIC_D017
        lda #%00000010            ; sprite 1 multicolour
        sta VIC_D01C
        lda #%00000100            ; sprite 2 X-expanded
        sta VIC_D01D
        lda #$00                  ; all sprites in front of graphics
        sta VIC_D01B

        lda #$05                  ; shared multicolour 0 = green
        sta VIC_D025
        lda #$07                  ; shared multicolour 1 = yellow
        sta VIC_D026
        lda #$02                  ; sprite 0 red
        sta VIC_D027
        lda #$01                  ; sprite 1 white own colour
        sta VIC_D028
        lda #$06                  ; sprite 2 blue
        sta VIC_D029
        lda #$0A                  ; sprite 3 light red
        sta VIC_D02A
        rts

draw_labels:
        PRINT SCREEN + 0*40 + 8, txt_title
        PRINT SCREEN + 2*40 + 2, txt_hint
        PRINT SCREEN + 5*40 + 1, txt_hires
        PRINT SCREEN + 9*40 + 1, txt_multi
        PRINT SCREEN + 13*40 + 1, txt_expand
        PRINT SCREEN + 17*40 + 1, txt_xmsb

        ldx #$00
@bars:
        txa
        and #$0F
        sta COLORRAM + 21*40,x
        lda #$A0
        sta SCREEN + 21*40,x
        inx
        cpx #40
        bne @bars
        rts

clear_screen:
        ldx #$00
@lp:
        lda #$20
        sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        lda #$0E
        sta COLORRAM+$000,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne @lp
        rts

make_sprites:
        lda #<SPR0
        sta DST
        lda #>SPR0
        sta DST+1
        lda #<spr0_data
        sta SRC
        lda #>spr0_data
        sta SRC+1
        jsr copy_sprite

        lda #<SPR1
        sta DST
        lda #>SPR1
        sta DST+1
        lda #<spr1_data
        sta SRC
        lda #>spr1_data
        sta SRC+1
        jsr copy_sprite

        lda #<SPR2
        sta DST
        lda #>SPR2
        sta DST+1
        lda #<spr2_data
        sta SRC
        lda #>spr2_data
        sta SRC+1
        jsr copy_sprite

        lda #<SPR3
        sta DST
        lda #>SPR3
        sta DST+1
        lda #<spr3_data
        sta SRC
        lda #>spr3_data
        sta SRC+1
        jsr copy_sprite
        rts

copy_sprite:
        ldy #$00
@lp:
        lda (SRC),y
        sta (DST),y
        iny
        cpy #63
        bne @lp
        lda #$00
        sta (DST),y
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
txt_title:  .byte "C64 VIC-II SPRITE TEST", 0
txt_hint:   .byte "SPRITES MOVE VIA VIC X REGISTERS", 0
txt_hires:  .byte "HIRES SPRITE", 0
txt_multi:  .byte "MULTICOLOUR SPRITE", 0
txt_expand: .byte "EXPANDED SPRITE", 0
txt_xmsb:   .byte "X-MSB SPRITE", 0

spr0_data:
        .byte $00,$7E,$00,$01,$FF,$80,$03,$FF,$C0
        .byte $07,$E7,$E0,$0F,$C3,$F0,$1F,$81,$F8
        .byte $3F,$00,$FC,$7E,$00,$7E,$FC,$18,$3F
        .byte $FC,$18,$3F,$7E,$00,$7E,$3F,$00,$FC
        .byte $1F,$81,$F8,$0F,$C3,$F0,$07,$E7,$E0
        .byte $03,$FF,$C0,$01,$FF,$80,$00,$7E,$00
        .byte $00,$18,$00,$00,$3C,$00,$00,$18,$00

spr1_data:
        .byte $00,$55,$00,$01,$AA,$40,$06,$FF,$90
        .byte $1B,$AA,$E4,$6E,$FF,$B9,$BB,$AA,$EE
        .byte $EE,$FF,$BB,$BB,$AA,$EE,$EE,$FF,$BB
        .byte $BB,$AA,$EE,$EE,$FF,$BB,$BB,$AA,$EE
        .byte $6E,$FF,$B9,$1B,$AA,$E4,$06,$FF,$90
        .byte $01,$AA,$40,$00,$55,$00,$00,$14,$00
        .byte $00,$55,$00,$00,$14,$00,$00,$55,$00

spr2_data:
        .byte $FF,$FF,$FF,$80,$00,$01,$BF,$FF,$FD
        .byte $A0,$00,$05,$AF,$FF,$F5,$A8,$00,$15
        .byte $AB,$FF,$D5,$AA,$00,$55,$AA,$FF,$55
        .byte $AA,$3C,$55,$AA,$3C,$55,$AA,$FF,$55
        .byte $AA,$00,$55,$AB,$FF,$D5,$A8,$00,$15
        .byte $AF,$FF,$F5,$A0,$00,$05,$BF,$FF,$FD
        .byte $80,$00,$01,$FF,$FF,$FF,$00,$00,$00

spr3_data:
        .byte $18,$00,$18,$3C,$00,$3C,$7E,$00,$7E
        .byte $FF,$00,$FF,$DB,$81,$DB,$99,$C3,$99
        .byte $18,$E7,$18,$18,$7E,$18,$18,$3C,$18
        .byte $18,$18,$18,$3C,$18,$3C,$7E,$18,$7E
        .byte $FF,$18,$FF,$7E,$18,$7E,$3C,$18,$3C
        .byte $18,$18,$18,$18,$3C,$18,$18,$7E,$18
        .byte $18,$FF,$18,$18,$7E,$18,$18,$3C,$18
