; Native C64 math coprocessor smoke test PRG.
;
; Build:
;   make c64-math-copro-test-prg
;
; Upload:
;   python tools/c64_uart_prg_loader.py roms/math_copro_test.prg --port COM15
;   RUN
;
; Register window: $DF00-$DF0F (C64 I/O2 expansion area).

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

SCREEN   = $0400
COLORRAM = $D800

PORTDDR  = $00
CPUPORT  = $01

MATH_BASE = $DF00
MATH_A0   = MATH_BASE + $0
MATH_A1   = MATH_BASE + $1
MATH_A2   = MATH_BASE + $2
MATH_A3   = MATH_BASE + $3
MATH_B0   = MATH_BASE + $4
MATH_B1   = MATH_BASE + $5
MATH_B2   = MATH_BASE + $6
MATH_B3   = MATH_BASE + $7
MATH_R0   = MATH_BASE + $8
MATH_R1   = MATH_BASE + $9
MATH_R2   = MATH_BASE + $A
MATH_R3   = MATH_BASE + $B
MATH_SH   = MATH_BASE + $C

VIC_D011 = $D011
VIC_D016 = $D016
VIC_D018 = $D018
VIC_D020 = $D020
VIC_D021 = $D021

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
SRC:    .res 2
DST:    .res 2
ERRS:   .res 1

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"
.macro PRINT where, what
        lda #<((where))
        sta DST
        lda #>((where))
        sta DST+1
        lda #<((what))
        sta SRC
        lda #>((what))
        sta SRC+1
        jsr print
.endmacro

start:
        sei
        cld

        lda #$37
        sta CPUPORT
        lda #$2F
        sta PORTDDR

        lda #$1B
        sta VIC_D011
        lda #$08
        sta VIC_D016
        lda #$15
        sta VIC_D018
        lda #$00
        sta VIC_D020
        sta VIC_D021

        jsr clear_screen
        PRINT SCREEN + 1*40 + 4, txt_title
        PRINT SCREEN + 3*40 + 0, txt_map
        PRINT SCREEN + 5*40 + 0, txt_case1
        PRINT SCREEN + 7*40 + 0, txt_case2
        PRINT SCREEN + 9*40 + 0, txt_case3

        lda #0
        sta ERRS

        ; 8.24: 2.0 * 3.0 = 6.0
        lda #24
        sta MATH_SH
        jsr load_a_02000000
        jsr load_b_03000000
        jsr settle
        lda #<(SCREEN + 5*40 + 30)
        sta DST
        lda #>(SCREEN + 5*40 + 30)
        sta DST+1
        lda #$00
        ldx #$00
        ldy #$00
        jsr expect_r012
        lda #$06
        jsr expect_r3
        jsr mark_case

        ; 8.24: -2.0 * -2.0 = 4.0
        jsr load_a_fe000000
        jsr load_b_fe000000
        jsr settle
        lda #<(SCREEN + 7*40 + 30)
        sta DST
        lda #>(SCREEN + 7*40 + 30)
        sta DST+1
        lda #$00
        ldx #$00
        ldy #$00
        jsr expect_r012
        lda #$04
        jsr expect_r3
        jsr mark_case

        ; Q12: 1.0 * 1.0 = 1.0
        lda #12
        sta MATH_SH
        jsr load_a_00001000
        jsr load_b_00001000
        jsr settle
        lda #<(SCREEN + 9*40 + 30)
        sta DST
        lda #>(SCREEN + 9*40 + 30)
        sta DST+1
        lda #$00
        ldx #$10
        ldy #$00
        jsr expect_r012
        lda #$00
        jsr expect_r3
        jsr mark_case

        lda ERRS
        beq @pass
        PRINT SCREEN + 12*40 + 8, txt_fail
        jmp done
@pass:
        PRINT SCREEN + 12*40 + 8, txt_pass

done:
        cli
        rts

; A=expected R0, X=expected R1, Y=expected R2.
expect_r012:
        cmp MATH_R0
        beq @r1
        inc ERRS
@r1:
        txa
        cmp MATH_R1
        beq @r2
        inc ERRS
@r2:
        tya
        cmp MATH_R2
        beq @done
        inc ERRS
@done:
        rts

; A=expected R3.
expect_r3:
        cmp MATH_R3
        beq @done
        inc ERRS
@done:
        rts

mark_case:
        lda ERRS
        beq @ok
        lda #<txt_bad_at_dst
        sta SRC
        lda #>txt_bad_at_dst
        sta SRC+1
        jsr print
        rts
@ok:
        lda #<txt_ok_at_dst
        sta SRC
        lda #>txt_ok_at_dst
        sta SRC+1
        jsr print
        rts

settle:
        ldx #8
@lp:
        dex
        bne @lp
        rts

load_a_02000000:
        lda #$00
        sta MATH_A0
        sta MATH_A1
        sta MATH_A2
        lda #$02
        sta MATH_A3
        rts

load_b_03000000:
        lda #$00
        sta MATH_B0
        sta MATH_B1
        sta MATH_B2
        lda #$03
        sta MATH_B3
        rts

load_a_fe000000:
        lda #$00
        sta MATH_A0
        sta MATH_A1
        sta MATH_A2
        lda #$FE
        sta MATH_A3
        rts

load_b_fe000000:
        lda #$00
        sta MATH_B0
        sta MATH_B1
        sta MATH_B2
        lda #$FE
        sta MATH_B3
        rts

load_a_00001000:
        lda #$00
        sta MATH_A0
        lda #$10
        sta MATH_A1
        lda #$00
        sta MATH_A2
        sta MATH_A3
        rts

load_b_00001000:
        lda #$00
        sta MATH_B0
        lda #$10
        sta MATH_B1
        lda #$00
        sta MATH_B2
        sta MATH_B3
        rts

clear_screen:
        ldx #$00
@lp:
        lda #$20
        sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        lda #$01
        sta COLORRAM+$000,x
        sta COLORRAM+$100,x
        sta COLORRAM+$200,x
        sta COLORRAM+$300,x
        inx
        bne @lp
        rts

print:
        ldy #$00
@lp:
        lda (SRC),y
        beq @done
        cmp #$40
        bcc @store
        cmp #$60
        bcs @store
        and #$3F
@store:
        sta (DST),y
        iny
        bne @lp
@done:
        rts

txt_title: .byte "C64 MATH COPRO TEST",0
txt_map:   .byte "REGISTER WINDOW: $DF00-$DF0F",0
txt_case1: .byte "8.24  2.0 *  3.0 = 6.0",0
txt_case2: .byte "8.24 -2.0 * -2.0 = 4.0",0
txt_case3: .byte "Q12   1.0 *  1.0 = 1.0",0
txt_ok_at_dst:  .byte "OK",0
txt_bad_at_dst: .byte "BAD",0
txt_pass: .byte "ALL TESTS PASS",0
txt_fail: .byte "MATH COPRO FAIL",0
