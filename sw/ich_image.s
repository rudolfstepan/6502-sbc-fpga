; ============================================================
; ich.png -> 320x200 hires bitmap (bitmap_mode, VIC bit0), 2 colours per
; 8x8 cell.  Standalone split-map ROM: program + data at $A000, vectors $FFFA.
;
; The 8000-byte linear bitmap (addr = y*40 + x/8, MSB = leftmost pixel) goes to
; the $6000 framebuffer window; the 1000-byte colour RAM (low nibble = fg,
; high nibble = bg) goes to $8400.  $9005 bit0 = 1 makes the cell background
; come from the colour-RAM high nibble (true 2-colour cells, C64 hires model).
;
; Pixel data is produced by tools/img2hires.py (incbin'd below).
;
; Build:
;   ca65 --cpu 65c02 -o ich_image.o ich_image.s
;   ld65 -C ich_image.cfg -o ../roms/ich_image.rom ich_image.o
; Upload:
;   python tools/upload_monitor_hex.py roms/ich_image.rom \
;       --split-rom --port COM15 --baud 115200 --run
; ============================================================

VIC_MODE      = $9000        ; bit0 = bitmap on
VIC_TEXT_ATTR = $9005        ; bit0 = cell_bg_mode (per-cell bg from $8400 hi nibble)
VIC_BORDER    = $D020
VIC_BG        = $D021
BMP_BASE      = $6000        ; framebuffer window (bank 0, first 8000 bytes shown)
COL_BASE      = $8400        ; colour RAM (40x25)

; Global background colour ($D021) the converter optimised for.  Each cell has
; ONE foreground (the $8400 low nibble); every bit=0 pixel shows this one global
; background -- so the image is dithered between per-cell fg and this colour.
.include "ich_image_bg.inc"

.segment "ZEROPAGE"
SRC: .res 2
DST: .res 2
CNT: .res 2

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    lda #$00                 ; black border
    sta VIC_BORDER
    lda #IMG_BGCOL           ; global screen background the image is dithered on
    sta VIC_BG
    lda #$01                 ; per-cell bg enable (harmless: hi nibble also = bg)
    sta VIC_TEXT_ATTR

    ; --- bitmap: 8000 bytes ROM -> $6000 ---
    lda #<bmp_data
    sta SRC
    lda #>bmp_data
    sta SRC+1
    lda #<BMP_BASE
    sta DST
    lda #>BMP_BASE
    sta DST+1
    lda #<8000
    sta CNT
    lda #>8000
    sta CNT+1
    jsr copy_block

    ; --- colour RAM: 1000 bytes ROM -> $8400 ---
    lda #<col_data
    sta SRC
    lda #>col_data
    sta SRC+1
    lda #<COL_BASE
    sta DST
    lda #>COL_BASE
    sta DST+1
    lda #<1000
    sta CNT
    lda #>1000
    sta CNT+1
    jsr copy_block

    lda #$01                 ; bitmap mode on
    sta VIC_MODE
halt:
    jmp halt

; copy CNT bytes from (SRC) to (DST); CNT decremented to 0
copy_block:
    ldy #0
cb_loop:
    lda CNT
    ora CNT+1
    beq cb_done
    lda (SRC),y
    sta (DST),y
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
    jmp cb_loop
cb_done:
    rts

.segment "RODATA"
bmp_data: .incbin "ich_image_bmp.bin"
col_data: .incbin "ich_image_col.bin"

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
