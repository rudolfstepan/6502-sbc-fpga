; ============================================================
; C64 native-core hardware diagnostic ROM
;
; Replaces the C64 KERNAL ($E000-$FFFF). Boots straight from reset, sets up
; the VIC screen directly, and runs a polled hardware self-test. Probes every
; subsystem the real KERNAL depends on, so a failing board reports exactly
; which block is broken instead of just "hangs".
;
;   BORDER cycles colour every loop  -> CPU heartbeat (frozen = CPU hung)
;   FRAME  (hex 16-bit)              -> loop running + screen writes OK
;   RAMERR (hex 16-bit, cumulative)  -> march-test mismatches across ALL
;                                       accessible RAM banks ($0800-$CFFF,
;                                       incl. RAM under BASIC) = main RAM
;                                       read/write under the VIC bus steal
;   PASSES (hex 16-bit)              -> completed full RAM sweeps
;   KEYROW (CIA1 $DC01)              -> keyboard matrix rows / CIA ports
;   IRQCNT (hex 16-bit)              -> CIA1 Timer-A interrupts actually
;                                       delivered to the CPU + ICR ack
;   CIAREG = PASS/FAIL               -> CIA1 + CIA2 register write/read-back
;
; The VIC powers up already configured (text mode, screen $0400, chargen,
; C64 colours); we only set the video bank (CIA2 PA) and write $0400 + $D800.
;
; Build: tools/build_c64_diag.py  (ca65 --cpu 6502 ; ld65 -C c64diag.cfg)
; ============================================================

SCREEN   = $0400
COLORRAM = $D800
VIC_BORD = $D020
VIC_BG   = $D021
CIA_PRA  = $DC00
CIA_PRB  = $DC01
CIA_DDRA = $DC02
CIA_DDRB = $DC03
CIA_TALO = $DC04
CIA_TAHI = $DC05
CIA_ICR  = $DC0D
CIA_CRA  = $DC0E
CIA2_PRA  = $DD00       ; VIC bank select (bits 0-1, inverted)
CIA2_DDRA = $DD02
CIA2_DDRB = $DD03
PORTDDR  = $00          ; 6510 processor-port direction register
CPUPORT  = $01          ; 6510 processor-port data (LORAM/HIRAM/CHAREN)

COL_FRAME = SCREEN + 4*40 + 8
COL_ERR   = SCREEN + 5*40 + 8
COL_PASS  = SCREEN + 6*40 + 8
COL_KEY   = SCREEN + 7*40 + 8
COL_IRQ   = SCREEN + 8*40 + 8
COL_CIA   = SCREEN + 9*40 + 8
COL_PHASE = SCREEN + 10*40 + 8   ; which test step is running (frozen char = hung here)
COL_RMW   = SCREEN + 11*40 + 8
COL_ROM   = SCREEN + 12*40 + 8
COL_IPC   = SCREEN + 13*40 + 8

.segment "ZEROPAGE"
SCRPTR:  .res 2          ; screen write pointer
STRPTR:  .res 2          ; source string pointer
PTR:     .res 2          ; RAM test pointer
PAT:     .res 1          ; RAM test pattern byte
STPG:    .res 1          ; RAM test start page
ENDPG:   .res 1          ; RAM test end page (exclusive)
ERRLO:   .res 1
ERRHI:   .res 1
FRLO:    .res 1
FRHI:    .res 1
PSLO:    .res 1
PSHI:    .res 1
IQLO:    .res 1          ; IRQ-delivery counter (set by the Timer-A IRQ handler)
IQHI:    .res 1
RMWXP:   .res 1          ; RMW test expected value
RMWEL:   .res 1          ; RMW mismatch counter (cumulative)
RMWEH:   .res 1
CKSUM:   .res 1          ; BASIC-ROM checksum (must be constant every pass)
IPCL:    .res 1          ; last IRQ-interrupted return address (from the stack)
IPCH:    .res 1

.segment "CODE"

; ---------------------------------------------------------------
RESET:
        sei
        cld
        ldx #$FF
        txs
        lda #$37
        sta CPUPORT             ; port data first (still gated by DDR=0 -> no effect yet)
        lda #$2F
        sta PORTDDR             ; NOW drive bits 0-5 -> LORAM/HIRAM/CHAREN = $37.
                                ; (Order matters: driving DDR while data=$00 would
                                ; bank out the KERNAL/diag at $E000 -> instant crash.)

        lda #$00
        sta VIC_BORD
        sta VIC_BG              ; black border/background
        sta ERRLO
        sta ERRHI
        sta FRLO
        sta FRHI
        sta PSLO
        sta PSHI
        sta IQLO
        sta IQHI
        sta RMWEL
        sta RMWEH
        sta RMWXP

        ; CIA1: port A = output (keyboard columns), port B = input (rows)
        lda #$FF
        sta CIA_DDRA
        lda #$00
        sta CIA_DDRB
        sta CIA_PRA             ; drive all columns low (any key pulls a row low)

        ; VIC video bank 0 ($0000-$3FFF) so it fetches the screen at $0400.
        ; CIA2 port A bits 0-1 select the bank, inverted: %11 -> bank 0.
        lda #$03
        sta CIA2_DDRA
        lda #$03
        sta CIA2_PRA

        ; IRQ-delivery test: CIA1 Timer A free-running ~60 Hz, IRQ enabled.
        lda #$00
        sta CIA_TALO
        lda #$40
        sta CIA_TAHI            ; TA latch = $4000 (~60 Hz at 1 MHz PHI2)
        lda #$81
        sta CIA_ICR             ; enable the Timer-A interrupt mask
        lda #$11
        sta CIA_CRA             ; START + force-load, continuous
        ; IRQ dispatch through a RAM vector, mirroring the KERNAL's JMP ($0314):
        lda #<irq_real
        sta $02FE
        lda #>irq_real
        sta $02FF
        cli                     ; allow IRQs to reach the CPU

        jsr clrscr
        jsr labels

; ---------------------------------------------------------------
main:
        inc VIC_BORD            ; <-- heartbeat: border cycles while CPU runs

        ; frame counter
        inc FRLO
        bne @nofh
        inc FRHI
@nofh:
        lda #<COL_FRAME
        sta SCRPTR
        lda #>COL_FRAME
        sta SCRPTR+1
        lda FRHI
        ldx FRLO
        jsr puthex16

        ; alternating march pattern $55 / $AA (by pass parity)
        lda PSLO
        lsr a
        lda #$55
        bcc @setpat
        lda #$AA
@setpat:
        sta PAT

        ; --- RAM test, all accessible banks (PHASE shows where a hang freezes) ---
        ; region 1: $0800-$9FFF (standard map)
        lda #$31                ; screen code '1'
        sta COL_PHASE
        lda #$08
        sta STPG
        lda #$A0
        sta ENDPG
        jsr ramtest

        ; region 2: $A000-$BFFF -- RAM *under* BASIC (LORAM=0 maps RAM here)
        lda #$32                ; '2'
        sta COL_PHASE
        lda #$36
        sta CPUPORT
        lda #$A0
        sta STPG
        lda #$C0
        sta ENDPG
        jsr ramtest
        lda #$37
        sta CPUPORT             ; restore BASIC/IO/KERNAL map

        ; region 3: $C000-$CFFF (always RAM)
        lda #$33                ; '3'
        sta COL_PHASE
        lda #$C0
        sta STPG
        lda #$D0
        sta ENDPG
        jsr ramtest

        lda #$04                ; 'D' = display/idle phase
        sta COL_PHASE

        ; pass counter
        inc PSLO
        bne @noph
        inc PSHI
@noph:

        ; RAM error count
        lda #<COL_ERR
        sta SCRPTR
        lda #>COL_ERR
        sta SCRPTR+1
        lda ERRHI
        ldx ERRLO
        jsr puthex16

        ; pass count
        lda #<COL_PASS
        sta SCRPTR
        lda #>COL_PASS
        sta SCRPTR+1
        lda PSHI
        ldx PSLO
        jsr puthex16

        ; keyboard rows (CIA1 PRB): all columns low -> a pressed key clears a bit
        lda #<COL_KEY
        sta SCRPTR
        lda #>COL_KEY
        sta SCRPTR+1
        lda CIA_PRB
        jsr puthex

        ; IRQ-delivery counter (bumped by the Timer-A IRQ handler)
        lda #<COL_IRQ
        sta SCRPTR
        lda #>COL_IRQ
        sta SCRPTR+1
        lda IQHI
        ldx IQLO
        jsr puthex16

        ; CIA register write/read-back test
        lda #$03                ; 'C'
        sta COL_PHASE
        jsr cia_test
        cmp #$01
        beq @cpass
        lda #<txt_fail
        sta STRPTR
        lda #>txt_fail
        sta STRPTR+1
        jmp @cput
@cpass:
        lda #<txt_pass
        sta STRPTR
        lda #>txt_pass
        sta STRPTR+1
@cput:
        lda #<COL_CIA
        sta SCRPTR
        lda #>COL_CIA
        sta SCRPTR+1
        jsr prstr

        ; RMW (read-modify-write) test under the VIC steal
        lda #$12                ; 'R'
        sta COL_PHASE
        jsr rmw_test
        lda #<COL_RMW
        sta SCRPTR
        lda #>COL_RMW
        sta SCRPTR+1
        lda RMWEH
        ldx RMWEL
        jsr puthex16

        ; BASIC-ROM read test: XOR-checksum $A000-$BFFF (the FP routines live here
        ; and execute from this BSRAM, which the diag itself never runs from). The
        ; value must be IDENTICAL every pass; if it flickers, ROM reads are marginal.
        lda #$72                ; 'B'... actually 'R' phase code reuse
        sta COL_PHASE
        jsr romcheck
        lda #<COL_ROM
        sta SCRPTR
        lda #>COL_ROM
        sta SCRPTR+1
        lda CKSUM
        jsr puthex

        ; last IRQ-interrupted return PC -- frozen at the hang it shows whether the
        ; IRQ ENTRY pushed a corrupt address ($A0xx/garbage) or stayed in the diag
        ; ($E0xx, so the corruption is in the RTI / T65 internal sequencing)
        lda #<COL_IPC
        sta SCRPTR
        lda #>COL_IPC
        sta SCRPTR+1
        lda IPCH
        ldx IPCL
        jsr puthex16

        jmp main

; ---------------------------------------------------------------
; romcheck: XOR-fold every byte of BASIC ROM ($A000-$BFFF) into CKSUM. Runs with
; the normal map ($01=$37, BASIC ROM visible). A clean ROM gives a constant value.
romcheck:
        lda #$00
        sta CKSUM
        lda #$00
        sta PTR
        lda #$A0
        sta PTR+1
@lp:
        ldy #$00
@pg:
        lda (PTR),y
        eor CKSUM
        sta CKSUM
        iny
        bne @pg
        inc PTR+1
        lda PTR+1
        cmp #$C0
        bne @lp
        rts

; ---------------------------------------------------------------
; RMW test: INC $0900 256 times -- it must return to its starting value (256
; wraps). A miscounted RMW (dropped or doubled increment when the VIC steal lands
; on the read or write-back cycle) leaves it off -> cumulative RMWEH:RMWEL.
rmw_test:
        lda $0900
        sta RMWXP
        ldx #$00
@lp:
        inc $0900
        inx
        bne @lp
        lda $0900
        cmp RMWXP
        beq @ok
        inc RMWEL
        bne @ok
        inc RMWEH
@ok:
        rts

; ---------------------------------------------------------------
; March test: write PAT across [STPG:00 .. ENDPG:00), read back, count mismatches
; into the cumulative ERRHI:ERRLO. STPG/ENDPG/PAT set by caller.
ramtest:
        lda STPG
        sta PTR+1
        lda #$00
        sta PTR
@wlp:
        ldy #$00
        lda PAT
@wpg:
        sta (PTR),y
        iny
        bne @wpg
        inc PTR+1
        lda PTR+1
        cmp ENDPG
        bne @wlp

        lda STPG
        sta PTR+1
        lda #$00
        sta PTR
@rlp:
        ldy #$00
@rpg:
        lda (PTR),y
        cmp PAT
        beq @ok
        inc ERRLO
        bne @ok
        inc ERRHI
@ok:
        iny
        bne @rpg
        inc PTR+1
        lda PTR+1
        cmp ENDPG
        bne @rlp
        rts

; ---------------------------------------------------------------
; CIA register write/read-back on CIA1 + CIA2 (DDRB). Returns A=1 PASS / 0 FAIL.
; DDRB reads back exactly what was written; restored to $00 afterwards.
cia_test:
        lda #$55
        sta CIA_DDRB
        lda CIA_DDRB
        cmp #$55
        bne @fail1
        lda #$AA
        sta CIA_DDRB
        lda CIA_DDRB
        cmp #$AA
        bne @fail1
        lda #$00
        sta CIA_DDRB            ; restore (keyboard rows = input)

        lda #$55
        sta CIA2_DDRB
        lda CIA2_DDRB
        cmp #$55
        bne @fail2
        lda #$AA
        sta CIA2_DDRB
        lda CIA2_DDRB
        cmp #$AA
        bne @fail2
        lda #$00
        sta CIA2_DDRB
        lda #$01
        rts
@fail1:
        lda #$00
        sta CIA_DDRB
        lda #$00
        rts
@fail2:
        lda #$00
        sta CIA2_DDRB
        lda #$00
        rts

; ---------------------------------------------------------------
; Clear screen to spaces and colour RAM to white.
clrscr:
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

; ---------------------------------------------------------------
; Print the static labels.
labels:
        lda #<(SCREEN+0*40)
        sta SCRPTR
        lda #>(SCREEN+0*40)
        sta SCRPTR+1
        lda #<txt_title
        sta STRPTR
        lda #>txt_title
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+2*40)
        sta SCRPTR
        lda #>(SCREEN+2*40)
        sta SCRPTR+1
        lda #<txt_hb
        sta STRPTR
        lda #>txt_hb
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+4*40)
        sta SCRPTR
        lda #>(SCREEN+4*40)
        sta SCRPTR+1
        lda #<txt_lf
        sta STRPTR
        lda #>txt_lf
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+5*40)
        sta SCRPTR
        lda #>(SCREEN+5*40)
        sta SCRPTR+1
        lda #<txt_le
        sta STRPTR
        lda #>txt_le
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+6*40)
        sta SCRPTR
        lda #>(SCREEN+6*40)
        sta SCRPTR+1
        lda #<txt_lp
        sta STRPTR
        lda #>txt_lp
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+7*40)
        sta SCRPTR
        lda #>(SCREEN+7*40)
        sta SCRPTR+1
        lda #<txt_lk
        sta STRPTR
        lda #>txt_lk
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+8*40)
        sta SCRPTR
        lda #>(SCREEN+8*40)
        sta SCRPTR+1
        lda #<txt_li
        sta STRPTR
        lda #>txt_li
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+9*40)
        sta SCRPTR
        lda #>(SCREEN+9*40)
        sta SCRPTR+1
        lda #<txt_lc
        sta STRPTR
        lda #>txt_lc
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+10*40)
        sta SCRPTR
        lda #>(SCREEN+10*40)
        sta SCRPTR+1
        lda #<txt_ph
        sta STRPTR
        lda #>txt_ph
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+11*40)
        sta SCRPTR
        lda #>(SCREEN+11*40)
        sta SCRPTR+1
        lda #<txt_rmw
        sta STRPTR
        lda #>txt_rmw
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+12*40)
        sta SCRPTR
        lda #>(SCREEN+12*40)
        sta SCRPTR+1
        lda #<txt_rom
        sta STRPTR
        lda #>txt_rom
        sta STRPTR+1
        jsr prstr

        lda #<(SCREEN+13*40)
        sta SCRPTR
        lda #>(SCREEN+13*40)
        sta SCRPTR+1
        lda #<txt_ipc
        sta STRPTR
        lda #>txt_ipc
        sta STRPTR+1
        jsr prstr
        rts

; ---------------------------------------------------------------
; prstr: write ASCII (STRPTR, null-terminated) as screen codes at SCRPTR.
prstr:
        ldy #$00
@lp:
        lda (STRPTR),y
        beq @done
        cmp #$40
        bcc @store
        sec
        sbc #$40                ; @,A-Z ($40-$5F) -> screen codes $00-$1F
@store:
        sta (SCRPTR),y
        iny
        bne @lp
@done:
        rts

; ---------------------------------------------------------------
; puthex16: A=high byte, X=low byte -> 4 hex screen codes at SCRPTR.
puthex16:
        jsr puthex
        lda SCRPTR
        clc
        adc #$02
        sta SCRPTR
        bcc @nc
        inc SCRPTR+1
@nc:
        txa
        jsr puthex
        rts

; puthex: A -> 2 hex screen codes at (SCRPTR)+0,+1.
puthex:
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr hexdig
        ldy #$00
        sta (SCRPTR),y
        pla
        and #$0F
        jsr hexdig
        ldy #$01
        sta (SCRPTR),y
        rts

hexdig:
        cmp #10
        bcc @dig
        sec
        sbc #9                  ; 10..15 -> 1..6 (screen codes for A..F)
        rts
@dig:
        clc
        adc #$30                ; 0..9 -> $30..$39
        rts

; ---------------------------------------------------------------
.segment "RODATA"
txt_title: .byte "C64 NATIVE DIAG", 0
txt_hb:    .byte "HEARTBEAT=BORDER CYCLES", 0
txt_lf:    .byte "FRAME :", 0
txt_le:    .byte "RAMERR:", 0
txt_lp:    .byte "PASSES:", 0
txt_lk:    .byte "KEYROW:", 0
txt_li:    .byte "IRQCNT:", 0
txt_lc:    .byte "CIAREG:", 0
txt_ph:    .byte "PHASE :", 0
txt_rmw:   .byte "RMWERR:", 0
txt_rom:   .byte "ROMCK :", 0
txt_ipc:   .byte "IRQPC :", 0
txt_pass:  .byte "PASS", 0
txt_fail:  .byte "FAIL", 0

; ---------------------------------------------------------------
.segment "VECTORS"
        .word nmi_h             ; $FFFA NMI  -> ignore
        .word RESET             ; $FFFC RESET
        .word irq_stub          ; $FFFE IRQ/BRK

.segment "CODE"
nmi_h:
        rti
irq_stub:
        jmp ($02FE)             ; indirect dispatch through a RAM vector (KERNAL-style)
irq_real:
        pha                     ; save A
        txa
        pha                     ; save X
        tsx
        lda $0104,x             ; interrupted PCL (stack: X,A,P,PCL,PCH)
        sta IPCL
        lda $0105,x             ; interrupted PCH
        sta IPCH
        inc IQLO
        bne @nc
        inc IQHI
@nc:
        lda CIA_ICR             ; acknowledge CIA1 (read-to-clear) so the IRQ drops
        pla
        tax                     ; restore X
        pla                     ; restore A
        rti
