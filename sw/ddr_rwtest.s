; ============================================================
; DDR3 framebuffer read/write self-test (UART report)
;
; Tests the CPU <-> DDR3 path through vic_fb_ddr3 directly, independent of the
; video display: write known bytes through the $6000 window, read them back, and
; report PASS/FAIL over UART. Isolates "DDR3 protocol/mask wrong" (this fails)
; from "display path wrong" (this passes but fb_test still black).
;
; Run on an FPGA build with FB_DDR3 enabled and DDR3 calibrated (LED3 on).
; No resynthesis needed -- just upload this ROM.
;
; Build:
;   ca65 --cpu 65c02 -o ddr_rwtest.o ddr_rwtest.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/ddr_rwtest.rom ddr_rwtest.o
; ============================================================

VIC_MODE  = $9000
UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10            ; TX ready
FB_WIN    = $6000
FB_MODE   = $10            ; fb display on, bank 0

.segment "ZEROPAGE"
ERRCNT:  .res 1
FIRSTA:  .res 1            ; first failing index
FIRSTG:  .res 1            ; got
FIRSTE:  .res 1            ; expected
GOTFAIL: .res 1
SPTR:    .res 2            ; putstr pointer

.segment "CODE"
RESET:
    sei
    ldx #$FF
    txs

    ; $6000 routes to DDR3 by address decode (no fb display needed); MODE bits
    ; 5-7 select the 8 KB bank. Leave fb display OFF so no line prefetch competes.
    lda #$00               ; bank 0, display off
    sta VIC_MODE

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; ---- Bank 0: write 0..255 then read back ----
    ldx #0
w0: txa
    sta FB_WIN,x
    inx
    bne w0

    lda #0
    sta ERRCNT
    sta GOTFAIL
    ldx #0
r0: txa                    ; A = expected (= x)
    cmp FB_WIN,x
    beq skip0
    inc ERRCNT
    lda GOTFAIL
    bne skip0              ; record only the first failure
    lda #1
    sta GOTFAIL
    stx FIRSTA
    txa
    sta FIRSTE
    lda FB_WIN,x
    sta FIRSTG
skip0:
    inx
    bne r0

    ldx #<msg_bank0
    ldy #>msg_bank0
    jsr putstr
    jsr report

    ; ---- Bank 1: write $A5 to offset 0, read back via bank 1 ----
    lda #$20               ; bank 1 (bits5-7 = 1), display off
    sta VIC_MODE
    lda #$A5
    sta FB_WIN+0
    lda #$5A
    sta FB_WIN+1
    lda FB_WIN+0
    cmp #$A5
    bne b1fail
    lda FB_WIN+1
    cmp #$5A
    bne b1fail
    ldx #<msg_b1ok
    ldy #>msg_b1ok
    jsr putstr
    jmp done
b1fail:
    ldx #<msg_b1fail
    ldy #>msg_b1fail
    jsr putstr
done:
    lda #$00
    sta VIC_MODE
halt:
    jmp halt

; report: print "ERRS=" + ERRCNT, and if any, first fail details
report:
    ldx #<msg_errs
    ldy #>msg_errs
    jsr putstr
    lda ERRCNT
    jsr puthex
    lda #$0D
    jsr putc
    lda ERRCNT
    beq rdone
    ldx #<msg_first
    ldy #>msg_first
    jsr putstr
    lda FIRSTA
    jsr puthex
    lda #' '
    jsr putc
    lda #'G'
    jsr putc
    lda FIRSTG
    jsr puthex
    lda #' '
    jsr putc
    lda #'E'
    jsr putc
    lda FIRSTE
    jsr puthex
    lda #$0D
    jsr putc
rdone:
    rts

; ---- UART helpers ----
putc:                      ; A = char (preserved-ish)
    pha
pw: lda UART_SR
    and #UART_TDRE
    beq pw
    pla
    sta UART_DATA
    rts

puthex:                    ; A = byte -> two hex digits
    pha
    lsr
    lsr
    lsr
    lsr
    jsr hexdig
    pla
    and #$0F
    jsr hexdig
    rts
hexdig:
    and #$0F
    cmp #10
    bcc :+
    clc
    adc #('A'-10-'0')
:   clc
    adc #'0'
    jmp putc

putstr:                    ; X=lo, Y=hi pointer to nul-terminated string
    stx SPTR
    sty SPTR+1
    ldy #0
ps: lda (SPTR),y
    beq psd
    jsr putc
    iny
    bne ps
psd:
    rts

.segment "RODATA"
msg_hdr:    .byte $0D, "DDR3 RW TEST", $0D, $00
msg_bank0:  .byte "BANK0 ", $00
msg_errs:   .byte "ERRS=", $00
msg_first:  .byte "FIRST@", $00
msg_b1ok:   .byte "BANK1 OK", $0D, $00
msg_b1fail: .byte "BANK1 FAIL", $0D, $00

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
