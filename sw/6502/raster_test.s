; ============================================================
; VIC-II raster register self-test ($D011/$D012) — UART report
;
; Verifies the new live raster read-back that lets raster-synchronised SID
; players (e.g. Commando) busy-wait on $D012 instead of hanging on a constant
; open-bus value:
;   A) $D012 is not stuck — it changes over time,
;   B) an equality wait (LDA $D012 / CMP #t / BNE) terminates (the Commando
;      mechanism), with a timeout so a broken build reports FAIL instead of
;      hanging,
;   C) $D011 bit 7 (raster bit 8) is seen both 0 and 1 over a frame, proving the
;      full line range is exposed.
;
; Build:
;   ca65 --cpu 65c02 -o raster_test.o raster_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/raster_test.rom raster_test.o
; ============================================================

UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10

D011      = $D011          ; VIC-II control 1 (bit 7 = raster bit 8 on read)
D012      = $D012          ; VIC-II raster line (low 8 bits)
TARGET    = $20            ; raster line to wait for in test B

.segment "ZEROPAGE"
FIRST:  .res 1             ; first $D012 sample
SEEN0:  .res 1             ; $D011 bit7 seen as 0
SEEN1:  .res 1             ; $D011 bit7 seen as 1
TO0:    .res 1             ; 24-bit timeout counter
TO1:    .res 1
TO2:    .res 1
SPTR:   .res 2

.segment "CODE"
RESET:
    sei
    cld
    ldx #$FF
    txs

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; ---- A) $D012 changes ----
    lda D012
    sta FIRST
    ldx #0                 ; 65536-iteration window
    ldy #0
a_loop:
    lda D012
    cmp FIRST
    bne a_ok               ; saw a different line -> not stuck
    inx
    bne a_loop
    iny
    bne a_loop
    ; fell through -> stuck
    ldx #<msg_a_fail
    ldy #>msg_a_fail
    jsr putstr
    jmp test_b
a_ok:
    ldx #<msg_a_ok
    ldy #>msg_a_ok
    jsr putstr

    ; ---- B) equality wait terminates (timeout-guarded) ----
test_b:
    lda #$FF
    sta TO0
    sta TO1
    lda #$08               ; ~ up to 0x08FFFF reads before giving up
    sta TO2
b_loop:
    lda D012
    cmp #TARGET
    beq b_ok
    dec TO0
    bne b_loop
    dec TO1
    bne b_loop
    dec TO2
    bne b_loop
    ldx #<msg_b_fail
    ldy #>msg_b_fail
    jsr putstr
    jmp test_c
b_ok:
    ldx #<msg_b_ok
    ldy #>msg_b_ok
    jsr putstr

    ; ---- C) $D011 bit 7 toggles (raster bit 8) ----
test_c:
    lda #0
    sta SEEN0
    sta SEEN1
    ldx #0
    ldy #0
c_loop:
    lda D011
    asl a                  ; bit7 -> carry
    bcs c_set
    lda #1
    sta SEEN0
    bra c_next
c_set:
    lda #1
    sta SEEN1
c_next:
    lda SEEN0
    and SEEN1
    bne c_ok               ; both seen
    inx
    bne c_loop
    iny
    bne c_loop
    ldx #<msg_c_fail
    ldy #>msg_c_fail
    jsr putstr
    jmp done
c_ok:
    ldx #<msg_c_ok
    ldy #>msg_c_ok
    jsr putstr

done:
    ldx #<msg_done
    ldy #>msg_done
    jsr putstr
halt:
    jmp halt

; ---- UART helpers ----
putc:
    pha
pw: lda UART_SR
    and #UART_TDRE
    beq pw
    pla
    sta UART_DATA
    rts
putstr:
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
msg_hdr:    .byte $0D, "RASTER $D012 TEST", $0D, $00
msg_a_ok:   .byte "A $D012 change OK", $0D, $00
msg_a_fail: .byte "A $D012 STUCK FAIL", $0D, $00
msg_b_ok:   .byte "B eq-wait OK", $0D, $00
msg_b_fail: .byte "B eq-wait TIMEOUT", $0D, $00
msg_c_ok:   .byte "C $D011 bit7 OK", $0D, $00
msg_c_fail: .byte "C $D011 bit7 FAIL", $0D, $00
msg_done:   .byte "DONE", $0D, $00

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
