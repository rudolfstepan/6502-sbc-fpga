; ============================================================
; C64 standalone PRG image viewer for sw/ich_image_* data.
;
; Build:
;   make c64-ich-image-prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/ich_image.prg --port COM15
;   RUN
;
; The image uses the existing optimised hires conversion, repacked into native
; C64 bitmap memory order:
;   ich_image_c64_bmp.bin  8000 bytes, bitmap at $2000
;   ich_image_c64_scr.bin  1000 bytes, screen colour nibbles at $0400
; ============================================================

BITMAP_BASE = $2000
SCREEN_BASE = $0400
CODE_START  = $0810

VIC_D011 = $D011
VIC_D016 = $D016
VIC_D018 = $D018
VIC_D020 = $D020
VIC_D021 = $D021
CIA2_DDRA = $DD02
CIA2_PRA  = $DD00

.include "ich_image_bg.inc"

.segment "LOADADDR"
    .word $0801

.segment "ZEROPAGE"
SRC: .res 2
DST: .res 2
CNT: .res 2
TMP: .res 1

.segment "STARTUP"
    ; BASIC line: 10 SYS 2064
basic:
    .word next_line
    .word 10
    .byte $9E
    .byte "2064"
    .byte 0
next_line:
    .word 0
    .res 3

.segment "CODE"
start:
    sei
    lda #$37
    sta $01

    lda #$00
    sta VIC_D020
    lda #IMG_BGCOL
    sta VIC_D021

    ; VIC bank 0 ($0000-$3FFF), screen=$0400, bitmap=$2000.
    lda CIA2_DDRA
    ora #$03
    sta CIA2_DDRA
    lda CIA2_PRA
    and #$FC
    ora #$03
    sta CIA2_PRA

    jsr copy_bitmap
    jsr copy_screen

    lda #$18        ; screen $0400, bitmap $2000
    sta VIC_D018
    lda #$08        ; 40 columns, hires bitmap
    sta VIC_D016
    lda #$3B        ; bitmap mode + display enable + 25 rows
    sta VIC_D011
    cli

hold:
    jmp hold

copy_bitmap:
    lda #<bitmap_data
    sta SRC
    lda #>bitmap_data
    sta SRC+1
    lda #<BITMAP_BASE
    sta DST
    lda #>BITMAP_BASE
    sta DST+1
    lda #<8000
    sta CNT
    lda #>8000
    sta CNT+1
    jmp copy_block

copy_screen:
    lda #<screen_data
    sta SRC
    lda #>screen_data
    sta SRC+1
    lda #<SCREEN_BASE
    sta DST
    lda #>SCREEN_BASE
    sta DST+1
    lda #<1000
    sta CNT
    lda #>1000
    sta CNT+1
    jmp copy_block

copy_block:
    lda CNT
    ora CNT+1
    beq copy_done
    ldy #0
    lda (SRC),y
    sta (DST),y
    jsr inc_src_dst_dec_count
    jmp copy_block
copy_done:
    rts

inc_src_dst_dec_count:
    inc SRC
    bne :+
    inc SRC+1
:
    inc DST
    bne :+
    inc DST+1
:
    lda CNT
    bne :+
    dec CNT+1
:
    dec CNT
    rts

.segment "RODATA"
screen_data:
    .incbin "ich_image_c64_scr.bin"
bitmap_data:
    .incbin "ich_image_c64_bmp.bin"
