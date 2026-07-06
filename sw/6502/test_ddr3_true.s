; ============================================================
; DDR3 true-colour test — 320x200 16bpp RGB565, smooth 2D gradient
;
; Proves the 320x200 16bpp (mode bit 6) video path end to end:
;   * $9000 bit 6 = DDR3 320x200 16bpp RGB565 mode (bits 4,5 clear)
;   * $9006 = 5-bit framebuffer bank (0..15); 320*200*2 = 128000 bytes = 16 banks
;   * two bytes per pixel through the banked $6000-$7FFF window
;     (low = GGGBBBBB, high = RRRRRGGG)
;   * vic_fb_ddr3 16bpp fetch/pack + RGB565 -> DAC in vic_vga
;
; Pattern: red ramps left->right (R 0..31), green ramps top->bottom (G 0..63),
; blue = 0. A clean, smooth two-axis gradient with no visible banding means the
; RGB565 path is good.
;
; Build (split-map ROM, run at $A000):
;   ca65 --cpu 65c02 -o test_ddr3_true.o test_ddr3_true.s
;   ld65 -C test_ddr3_true.cfg -o ../../roms/6502/test_ddr3_true.rom test_ddr3_true.o
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/test_ddr3_true.rom --split-rom --run
; ============================================================

VIC_MODE    = $9000     ; bit6 = DDR3 320x200 16bpp RGB565
VIC_FB_BANK = $9006     ; 5-bit framebuffer bank 0..15
FB_WIN      = $6000     ; banked framebuffer window ($6000-$7FFF = 8192 bytes)
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

.segment "ZEROPAGE"
PTR:    .res 2          ; running pointer into the $6000 window
BANK:   .res 1          ; current 8 KiB bank 0..15
ROW:    .res 1          ; scanline 0..199
CNT:    .res 2          ; pixels left in the current row (16-bit, counts 320..1)
TEN:    .res 1          ; column-group counter: R++ every 10 columns
RVAL:   .res 1          ; red 0..31
GACC:   .res 2          ; green Bresenham accumulator (add 64/row, sub 200)
GVAL:   .res 1          ; green 0..63
GHI:    .res 1          ; G>>3 (into the high byte's low 3 bits)
LOWB:   .res 1          ; low byte for the row = (G&7)<<5 (B=0), constant per row
HITMP:  .res 1          ; high byte for the pixel = (R<<3)|GHI

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    ; 16bpp mode on (bit 6), bank 0, window pointer at $6000
    lda #$40
    sta VIC_MODE
    lda #0
    sta VIC_FB_BANK
    sta BANK
    sta ROW
    sta GACC+0
    sta GACC+1
    sta GVAL
    lda #<FB_WIN
    sta PTR
    lda #>FB_WIN
    sta PTR+1

row_loop:
    ; --- per-row green: GHI = G>>3 ; LOWB = (G&7)<<5 (blue = 0) ---
    lda GVAL
    lsr
    lsr
    lsr
    sta GHI
    lda GVAL
    and #$07
    asl
    asl
    asl
    asl
    asl
    sta LOWB

    ; reset column ramp: R = 0, next R++ in 10 columns, 320 pixels this row
    lda #0
    sta RVAL
    lda #10
    sta TEN
    lda #<320
    sta CNT+0
    lda #>320
    sta CNT+1

col_loop:
    ; high byte = (R<<3) | GHI
    lda RVAL
    asl
    asl
    asl
    ora GHI
    sta HITMP

    ; write the 16-bit pixel (low then high)
    ldy #0
    lda LOWB
    sta (PTR),y
    iny
    lda HITMP
    sta (PTR),y

    ; advance the window pointer by 2; hop to the next bank at $8000
    clc
    lda PTR
    adc #2
    sta PTR
    bcc chk_bank
    inc PTR+1
chk_bank:
    lda PTR+1
    cmp #$80
    bne no_hop
    lda #>FB_WIN
    sta PTR+1
    inc BANK
    lda BANK
    sta VIC_FB_BANK
no_hop:

    ; red ramp: R++ every 10 columns
    dec TEN
    bne col_next
    lda #10
    sta TEN
    inc RVAL

col_next:
    ; CNT-- ; loop while CNT != 0
    lda CNT+0
    sec
    sbc #1
    sta CNT+0
    lda CNT+1
    sbc #0
    sta CNT+1
    lda CNT+0
    ora CNT+1
    bne col_loop

    ; --- per-row green Bresenham: GACC += 64 ; if GACC >= 200: GACC -= 200, G++ ---
    clc
    lda GACC+0
    adc #64
    sta GACC+0
    lda GACC+1
    adc #0
    sta GACC+1
    ; compare GACC >= 200 ($00C8)
    lda GACC+1
    bne g_sub               ; high byte set -> definitely >= 200
    lda GACC+0
    cmp #200
    bcc g_done
g_sub:
    sec
    lda GACC+0
    sbc #200
    sta GACC+0
    lda GACC+1
    sbc #0
    sta GACC+1
    inc GVAL
g_done:

    ; next row
    inc ROW
    lda ROW
    cmp #200
    bcs done
    jmp row_loop

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
