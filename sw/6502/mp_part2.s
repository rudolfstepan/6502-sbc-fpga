; ============================================================
; Multi-part demo, PART 2: loaded and started by PART 1 via chainload.  Prints a
; confirmation and loops.  Loads at the same $2000 as PART 1 (it overwrote it).
; ============================================================
KCHROUT = $F003
KCLRSCR = $F00C

.segment "CODE"
start:
    jsr KCLRSCR
    lda #<msg
    ldy #>msg
    jsr print
@loop:
    jmp @loop                ; PART 2 is running; reset / KEY0 to exit

print:
    sta @p+1
    sty @p+2
    ldy #0
@p:
    lda $FFFF,y
    beq @done
    jsr KCHROUT
    iny
    bne @p
@done:
    rts

msg:
    .byte "MULTI-PART DEMO  ---  PART 2", $0D, $0D
    .byte "PART 2 IS NOW RUNNING!", $0D
    .byte "IT WAS AUTO-LOADED BY PART 1.", $0D, $0D
    .byte "MULTI-PART CHAIN LOADING WORKS.", $0D, 0
