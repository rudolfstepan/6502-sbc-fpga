; ============================================================
; Multi-part demo, PART 1 (the "intro"): print a banner, wait for a key, then
; load and run PART2 from the same D64.  Both parts load at $2000; chainload runs
; the load+jump from a $5F00 stub so PART2 can overwrite PART1 safely.
;
; Build as a RAM PRG (entry = load address $2000, CALL 8192), packed into a D64.
; ============================================================
KCHROUT = $F003              ; output char (A)
KCHRIN  = $F006              ; blocking input + echo
KCLRSCR = $F00C              ; clear screen

.segment "CODE"
start:
    jsr KCLRSCR
    lda #<msg
    ldy #>msg
    jsr print
    jsr KCHRIN               ; wait for any key
    lda #<part2name
    ldy #>part2name
    jsr chainload            ; load + run PART2 (no return on success)
    rts                      ; only if the load failed (stub falls back to BASIC)

; print: A/Y = lo/hi of a null-terminated string -> KCHROUT
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
    .byte "MULTI-PART DEMO  ---  PART 1", $0D, $0D
    .byte "THIS IS THE INTRO PART.", $0D
    .byte "PRESS A KEY TO LOAD PART 2...", $0D, 0

part2name:
    .byte "PART2", 0

.include "chainload.inc"
