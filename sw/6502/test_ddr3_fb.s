; ============================================================
; DDR3 framebuffer test — 8 vertical colour bars, 320x200 8bpp RGB332
;
; Proves the whole new video path end to end:
;   * CPU pixel writes into the banked $6000-$7FFF window
;   * $9000 bit 4 = DDR3 320x200 8bpp mode, bits 7:5 = 8 KiB bank (8 banks)
;   * vic_fb_ddr3 scanline prefetch + streaming to the VIC
;   * RGB332 -> RGB decode in vic_vga
;
; Expect 8 clean vertical bars, each 40 source px (80 display px) wide:
;   red  green  blue  yellow  cyan  magenta  white  grey
; painting in from the top as the framebuffer fills. A stable, correct pattern
; means the DDR3 display path is good; black/flicker/garbage means it is not.
;
; Build (split-map ROM, run at $A000):
;   ca65 --cpu 65c02 -o test_ddr3_fb.o test_ddr3_fb.s
;   ld65 -C test_ddr3_fb.cfg -o ../roms/test_ddr3_fb.rom test_ddr3_fb.o
; Upload:
;   python tools/upload_monitor_hex.py roms/test_ddr3_fb.rom --split-rom --run
; ============================================================

VIC_MODE  = $9000       ; bit4 = DDR3 320x200 8bpp, bits7:5 = 8 KiB bank
FB_WIN    = $6000       ; banked framebuffer window ($6000-$7FFF = 8192 bytes)
UART_DATA = $8810
UART_SR   = $8811
UART_RDRF = $08

LINES     = 200         ; source scanlines
NBARS     = 8
BARW      = 40          ; 8 * 40 = 320 px per line

.segment "ZEROPAGE"
PTR:    .res 2          ; running pointer into the $6000 window
BANK:   .res 1          ; current 8 KiB bank 0..7
ROWS:   .res 1          ; scanlines left
BARX:   .res 1          ; bar index 0..7
PXCNT:  .res 1          ; pixels left in the current bar
COLOR:  .res 1          ; current bar colour byte

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    ; DDR3 mode, bank 0, window pointer at $6000
    lda #$10
    sta VIC_MODE
    lda #<FB_WIN
    sta PTR
    lda #>FB_WIN
    sta PTR+1
    lda #0
    sta BANK

    ldy #0              ; constant index for (PTR),y stores
    lda #LINES
    sta ROWS
row_loop:
    lda #0
    sta BARX
bar_loop:
    ldx BARX
    lda BARS,x
    sta COLOR
    lda #BARW
    sta PXCNT
px_loop:
    lda COLOR
    sta (PTR),y         ; write one pixel byte to the framebuffer

    ; advance the window pointer; hop to the next bank when it passes $7FFF
    inc PTR
    bne no_carry
    inc PTR+1
    lda PTR+1
    cmp #$80
    bne no_carry
    lda #>FB_WIN        ; wrap the window back to $6000 ...
    sta PTR+1
    inc BANK            ; ... and select the next 8 KiB bank
    lda BANK
    asl a
    asl a
    asl a
    asl a
    asl a               ; bank << 5 -> bits 7:5
    ora #$10            ; keep bit 4 (DDR3 mode) set
    sta VIC_MODE
no_carry:
    dec PXCNT
    bne px_loop

    inc BARX
    lda BARX
    cmp #NBARS
    bne bar_loop

    dec ROWS
    bne row_loop

    ; pattern complete — wait for any UART key, then return to text mode
wait_key:
    lda UART_SR
    and #UART_RDRF
    beq wait_key
    lda UART_DATA
    lda #$00
    sta VIC_MODE
halt:
    jmp halt

.segment "RODATA"
; RGB332 bar colours: RRRGGGBB
BARS:
    .byte $E0           ; 0 red
    .byte $1C           ; 1 green
    .byte $03           ; 2 blue
    .byte $FC           ; 3 yellow
    .byte $1F           ; 4 cyan
    .byte $E3           ; 5 magenta
    .byte $FF           ; 6 white
    .byte $49           ; 7 grey

.segment "VECTORS"
    .word RESET         ; $FFFA NMI
    .word RESET         ; $FFFC RESET
    .word RESET         ; $FFFE IRQ
