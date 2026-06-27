; ============================================================
; Execute-from-$5000 test (UART report)
;
; The $4000-$5FFF data path already passes (sram_test). This checks that the CPU
; can FETCH AND RUN code from there (bram_byte_bridge with req/ack wait states),
; which is what SID tunes like Commando do (JSR $5012 / $5F80). It copies a tiny
; position-independent blob to $5000 and JSRs it; the blob prints "5K" and
; returns. Output "EXEC@5000: 5K RET" means execution from $5000 works.
;
; Build:
;   ca65 --cpu 65c02 -o sram_exec_test.o sram_exec_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/sram_exec_test.rom sram_exec_test.o
; ============================================================

UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10
TARGET    = $5000

.segment "ZEROPAGE"
SRC:  .res 2
DST:  .res 2
SPTR: .res 2

.segment "CODE"
RESET:
    sei
    cld
    ldx #$FF
    txs

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; copy exec_blob -> $5000
    lda #<exec_blob
    sta SRC
    lda #>exec_blob
    sta SRC+1
    lda #<TARGET
    sta DST
    lda #>TARGET
    sta DST+1
    ldy #0
cloop:
    lda (SRC),y
    sta (DST),y
    iny
    cpy #blob_len
    bne cloop

    ldx #<msg_exec
    ldy #>msg_exec
    jsr putstr

    jsr TARGET          ; <-- run code from $5000 (bram_byte_bridge)

    ldx #<msg_ret
    ldy #>msg_ret
    jsr putstr

halt:
    jmp halt

; position-independent blob (absolute JSRs only, no relative branches):
exec_blob:
    lda #'5'
    jsr putc
    lda #'K'
    jsr putc
    rts
exec_blob_end:
blob_len = exec_blob_end - exec_blob

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
msg_hdr:  .byte $0D, "EXEC-FROM-5000 TEST", $0D, $00
msg_exec: .byte "EXEC@5000: ", $00
msg_ret:  .byte " RET", $0D, "OK", $0D, $00

.segment "VECTORS"
    .word RESET
    .word RESET
    .word RESET
