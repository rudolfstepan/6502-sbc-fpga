; ============================================================
; CIA-1 Timer A self-test (UART report)
;
; Exercises the new CIA-1 ($DC00-$DC0F) Timer A:
;   A) the counter decrements while running,
;   B) underflow latches the ICR TA flag, and reading ICR clears it,
;   C) the underflow IRQ actually reaches the CPU (own IRQ handler runs).
;
; Prints PASS/FAIL for each over UART. Run on a build that includes cia6526.
;
; Build:
;   ca65 --cpu 65c02 -o cia_test.o cia_test.s
;   ld65 -C mandelbrot_bitmap.cfg -o ../roms/cia_test.rom cia_test.o
; ============================================================

CIA_TALO = $DC04
CIA_TAHI = $DC05
CIA_ICR  = $DC0D
CIA_CRA  = $DC0E

UART_DATA = $8810
UART_SR   = $8811
UART_TDRE = $10

.segment "ZEROPAGE"
IRQCNT: .res 1
R1:     .res 1
SPTR:   .res 2

.segment "CODE"
RESET:
    sei
    cld
    ldx #$FF
    txs
    lda #0
    sta IRQCNT

    ldx #<msg_hdr
    ldy #>msg_hdr
    jsr putstr

    ; ---- Test A: counter decrements ----
    lda #$00
    sta CIA_CRA            ; stop
    lda #$FF
    sta CIA_TALO           ; latch lo
    lda #$FF
    sta CIA_TAHI           ; latch hi -> reloads counter to $FFFF (stopped)
    lda #$01
    sta CIA_CRA            ; start, continuous
    lda CIA_TALO           ; r1 = low byte
    sta R1
    ldy #30
da: dey
    bne da                 ; ~few us delay (counter drops a few, no wrap)
    lda CIA_TALO           ; r2
    cmp R1                 ; A(r2) - R1 ; carry clear if r2 < R1
    bcs a_fail
    ldx #<msg_a_ok
    ldy #>msg_a_ok
    jsr putstr
    jmp testB
a_fail:
    ldx #<msg_a_fail
    ldy #>msg_a_fail
    jsr putstr

testB:
    ; ---- Test B: underflow sets ICR bit0; read clears it ----
    lda #$00
    sta CIA_CRA            ; stop
    lda #$40
    sta CIA_TALO
    lda #$00
    sta CIA_TAHI           ; counter = $0040 (64 PHI2 ticks)
    lda CIA_ICR            ; clear any stale flag
    lda #$01
    sta CIA_CRA            ; start, continuous
    ldx #0
    ldy #0
pb: lda CIA_ICR
    and #$01
    bne b_got
    iny
    bne pb
    inx
    bne pb                 ; ~16k polls timeout
    ldx #<msg_b_fail
    ldy #>msg_b_fail
    jsr putstr
    jmp testC
b_got:
    lda #$00
    sta CIA_CRA            ; stop so no new underflow
    lda CIA_ICR            ; read clears
    and #$01
    bne b_fail             ; still set -> read did not clear
    ldx #<msg_b_ok
    ldy #>msg_b_ok
    jsr putstr
    jmp testC
b_fail:
    ldx #<msg_b_fail
    ldy #>msg_b_fail
    jsr putstr

testC:
    ; ---- Test C: real CPU IRQ from Timer A underflow ----
    lda #$00
    sta CIA_CRA
    lda #0
    sta IRQCNT
    lda #$00
    sta CIA_TALO
    lda #$02
    sta CIA_TAHI           ; counter = $0200 (512 ticks)
    lda CIA_ICR            ; clear stale
    lda #$81
    sta CIA_ICR            ; enable TA interrupt (bit7 set + bit0)
    lda #$01
    sta CIA_CRA            ; start, continuous
    cli                    ; allow IRQs
    ldx #0
    ldy #0
wc: iny
    bne wc
    inx
    cpx #$20
    bne wc                 ; wait a while (several underflows)
    sei
    lda IRQCNT
    bne c_ok
    ldx #<msg_c_fail
    ldy #>msg_c_fail
    jsr putstr
    jmp done
c_ok:
    ldx #<msg_c_ok
    ldy #>msg_c_ok
    jsr putstr
    ; print IRQ count
    ldx #<msg_cnt
    ldy #>msg_cnt
    jsr putstr
    lda IRQCNT
    jsr puthex
    lda #$0D
    jsr putc

done:
    lda #$00
    sta CIA_CRA
    ldx #<msg_done
    ldy #>msg_done
    jsr putstr
halt:
    jmp halt

; ---- IRQ handler: ack CIA (read ICR) and count ----
irq_handler:
    pha
    lda CIA_ICR            ; clears the interrupt
    inc IRQCNT
    pla
    rti

; ---- UART helpers ----
putc:
    pha
pw: lda UART_SR
    and #UART_TDRE
    beq pw
    pla
    sta UART_DATA
    rts

puthex:
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
msg_hdr:    .byte $0D, "CIA TIMER A TEST", $0D, $00
msg_a_ok:   .byte "A countdown   OK", $0D, $00
msg_a_fail: .byte "A countdown FAIL", $0D, $00
msg_b_ok:   .byte "B icr/clear   OK", $0D, $00
msg_b_fail: .byte "B icr/clear FAIL", $0D, $00
msg_c_ok:   .byte "C cpu irq     OK", $0D, $00
msg_c_fail: .byte "C cpu irq   FAIL", $0D, $00
msg_cnt:    .byte "IRQCNT=", $00
msg_done:   .byte "DONE", $0D, $00

.segment "VECTORS"
    .word irq_handler      ; $FFFA NMI
    .word RESET            ; $FFFC RESET
    .word irq_handler      ; $FFFE IRQ
