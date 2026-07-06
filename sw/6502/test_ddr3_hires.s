; ============================================================
; DDR3 hi-res framebuffer test — 640x400 8bpp RGB332, XOR texture
;
; Proves the new 640x400 (mode bit 5) video path end to end:
;   * $9000 bit 5 = DDR3 640x400 8bpp hi-res mode (bit 4 clear)
;   * $9006 = full 5-bit framebuffer bank (0..31); the 256000-byte frame spans
;     32x 8 KiB banks reached through the $6000-$7FFF window
;   * vic_fb_ddr3 runtime geometry (640 px/line, 400 lines, 1:1 display)
;   * RGB332 -> RGB decode in vic_vga
;
; The pattern is colour = (column low byte) XOR (row low byte). Every pixel gets
; a position-dependent value, so it exercises the whole framebuffer address space
; AND its single-pixel detail only resolves crisply when the path is truly 1:1 --
; a 2x-doubled 320x200 image could never show it. Expect a fine, colourful moiré
; texture painting in from the top; a stable, sharp pattern means the hi-res path
; is good, smeared/blocky/garbage means it is not.
;
; Build (split-map ROM, run at $A000):
;   ca65 --cpu 65c02 -o test_ddr3_hires.o test_ddr3_hires.s
;   ld65 -C test_ddr3_hires.cfg -o ../../roms/6502/test_ddr3_hires.rom test_ddr3_hires.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/test_ddr3_hires.rom --split-rom --run
; ============================================================

VIC_MODE    = $9000     ; bit5 = DDR3 640x400 8bpp hi-res (bit4 clear)
VIC_FB_BANK = $9006     ; 5-bit framebuffer bank 0..31
FB_WIN      = $6000     ; banked framebuffer window ($6000-$7FFF = 8192 bytes)
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

NBANKS      = 32        ; 32 * 8192 = 262144 bytes >= 256000 (640x400)

.segment "ZEROPAGE"
PTR:    .res 2          ; running pointer into the $6000 window
BANK:   .res 1          ; current 8 KiB bank 0..31
CXLO:   .res 1          ; pixel column, low byte  (0..639 = $0000..$027F)
CXHI:   .res 1          ; pixel column, high byte
YLO:    .res 1          ; pixel row, low byte (wraps every 256 rows; fine for XOR)

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    ; hi-res mode on (bit 5), bank 0, window pointer at $6000
    lda #$20
    sta VIC_MODE
    lda #0
    sta VIC_FB_BANK
    sta BANK
    sta CXLO
    sta CXHI
    sta YLO
    lda #<FB_WIN
    sta PTR
    lda #>FB_WIN
    sta PTR+1

    ldy #0              ; constant index for (PTR),y stores
fill_loop:
    ; colour = column_low XOR row_low  -> per-pixel RGB332 texture
    lda CXLO
    eor YLO
    sta (PTR),y

    ; advance the window pointer; hop to the next bank when it passes $7FFF
    inc PTR
    bne adv_col
    inc PTR+1
    lda PTR+1
    cmp #$80
    bne adv_col
    lda #>FB_WIN        ; wrap the window back to $6000 ...
    sta PTR+1
    inc BANK            ; ... and select the next 8 KiB bank
    lda BANK
    cmp #NBANKS
    beq done           ; all 32 banks written = whole 640x400 frame (+ pad)
    sta VIC_FB_BANK    ; bank goes to $9006 (NOT $9000) in hi-res mode
adv_col:
    ; column++ ; at 640 wrap to 0 and step to the next row
    inc CXLO
    bne chk_col
    inc CXHI
chk_col:
    lda CXHI
    cmp #$02           ; 640 = $0280
    bne fill_loop
    lda CXLO
    cmp #$80
    bne fill_loop
    lda #0             ; end of row: column back to 0, next row
    sta CXLO
    sta CXHI
    inc YLO
    jmp fill_loop

done:
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

.segment "VECTORS"
    .word RESET         ; $FFFA NMI
    .word RESET         ; $FFFC RESET
    .word RESET         ; $FFFE IRQ
