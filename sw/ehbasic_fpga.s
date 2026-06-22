; ============================================================
; EhBASIC V2.22 — FPGA UART port
; ROM segment: $D000-$FFFF (12 KB), placed inside the 16 KB
; shadow ROM ($C000-$FFFF) that the UART monitor loads.
;
; I/O model:
;   VEC_IN  ($E2 ZP BRAM) -> KERNAL_CHRIN_NB ($C009)
;                            reads UART RDRF first, falls back to VIA CA1
;   VEC_OUT ($E4 ZP BRAM) -> KERNAL_CHROUT ($C003)
;                            writes to VIC VRAM (VGA) AND mirrors to UART
;                            preserves X, Y; handles $0D->newline, drops $0A
;
; Vectors are in ZP BRAM, NOT page-2 SDRAM.  JMP (VEC_OUT) reads from
; ZP BRAM (single-cycle, no wait states) — avoids SDRAM timing window.
;
; RAM available to BASIC: $0200-$3FFF (~15.5 KB)
;   Ram_top is patched to $4000 by build_fpga_ehbasic.py
;   $0000-$3FFF is on-chip 16 KB BRAM (single-cycle, reliable); $4000-$7FFF is
;   DDR3 and intentionally kept out of BASIC's reach until the bridge is fixed.
;   (above $7FFF: VIC VRAM $8000, VIA $8800, UART $8810, etc.)
;
; Disk commands LOAD/SAVE use the second SD card (data disk).
; C64-compatible disk format:
;   Sector 0: BAM (Block Allocation Map) — simple: just sector counts
;   Sector 1: Directory — single file entry (C64 style, 32 bytes)
;   Sector 2+: Program data (raw BASIC memory, Smeml to Svarl)
;
; C64 Directory entry (32 bytes):
;   +0   file type/status ($82 = PRG, bit 7 = not closed)
;   +1-2 starting sector (LE, 16-bit)
;   +3   track (always 1 for us, SD sectors are linear)
;   +4-19 filename (16 bytes, space-padded)
;   +20+ rest unused
;
; Usage: POKE 236,n does nothing. Just SAVE/LOAD.
;
; Diagnostic sequence on UART at startup (visible in terminal):
;   *     kernel CLRSCR alive
;   A     CLRSCR returned
;   R     all ZP BRAM vectors written
;   S     vector setup complete, about to enter final boot checks
;   H     final boot check reached
;   U     entering EhBASIC LAB_COLD
;
; Build:
;   python tools/build_fpga_ehbasic.py
; Upload + run:
;   python tools/upload_monitor_hex.py tools/roms/fpga_ehbasic_16kb.rom \
;       --port COM15 --baud 230400 --address 0xC000 --run --verbose
; ============================================================

; Kernel jump table (kernel ROM relocated to $F000-$FFFF)
KERNAL_CHROUT   = $F003     ; write char A to VIC + mirror to UART
KERNAL_CHRIN    = $F006     ; blocking read + echo (uppercase)
KERNAL_CHRIN_NB = $F009     ; non-blocking: A=char, C=1 ready
KERNAL_CLRSCR   = $F00C     ; clear VIC screen, home cursor
KERNAL_PENDING_CHAR = $02F7
KERNAL_PENDING_FLAG = $02F8

; UART hardware registers
UART_DATA   = $8810         ; write = TX byte, read = RX byte
UART_SR     = $8811         ; bit4 = TDRE (TX ready), bit3 = RDRF (RX data)
UART_TDRE   = $10
UART_RDRF   = $08

; EhBASIC I/O vectors — defined in basic.asm (patched by build_fpga_ehbasic.py
; to ZP BRAM instead of page-2 SDRAM, to avoid T65 JMP-indirect timing bug).
; EhBASIC marks $E2-$EE as "unused"; kernel uses only $F2-$F7.
; VEC_CC=$EA  VEC_IN=$E2  VEC_OUT=$E4  VEC_LD=$E6  VEC_SV=$E8  (after patch)

; IRQ_vec stays at $020D so basic.asm's Ibuffs=IRQ_vec+$14=$0221 (SDRAM
; input buffer) stays correct.  The actual interrupt VECTORS point to
; IRQ_CODE / NMI_CODE which live in ROM — no SDRAM copy needed.
IRQ_vec     = $020D
NMI_FLAG_ZP = $DC
IRQ_FLAG_ZP = $DF

; ============================================================
.segment "EHBASIC"

; ============================================================
; Fixed entry jump table at the very start of EhBASIC ($A000).
; The kernel ROM owns the $FFFA vectors and points them here, so these
; three addresses must stay fixed:
;   $A000 RESET, $A003 IRQ, $A006 NMI.
; ============================================================
ENTRY_TABLE:
    jmp RESET_ENTRY             ; $A000  <- kernel RESET vector
    jmp IRQ_CODE               ; $A003  <- kernel IRQ vector
    jmp NMI_CODE               ; $A006  <- kernel NMI vector

; ============================================================
; RESET_ENTRY — CPU reset lands at $A000 (jmp here).  The kernel is a
; callable library only; it does no boot setup itself.
; ============================================================
RESET_ENTRY:
    sei
    ldx #$FF
    txs                         ; re-init stack (harmless if kernel did it)

    jsr KERNAL_CLRSCR           ; clear VIC screen, sends '*' on UART

    ; Diag A: CLRSCR returned
    lda #'A'
    jsr EHB_UART_CHROUT

    ; Install EhBASIC I/O vectors in ZP BRAM ($E2-$E9).
    ; ZP writes go to FPGA BRAM — single cycle, no wait states.
    ; LAB_COLD only touches $0200-$0204 (PG2_TABS), so these survive
    ; across EhBASIC cold/warm starts.
    lda #<KERNAL_CHRIN_NB
    sta VEC_IN
    lda #>KERNAL_CHRIN_NB
    sta VEC_IN+1

    lda #<KERNAL_CHROUT
    sta VEC_OUT
    lda #>KERNAL_CHROUT
    sta VEC_OUT+1

    lda #<EHB_DISK_LOAD
    sta VEC_LD
    lda #>EHB_DISK_LOAD
    sta VEC_LD+1

    lda #<EHB_DISK_SAVE
    sta VEC_SV
    lda #>EHB_DISK_SAVE
    sta VEC_SV+1

    ; VEC_CC ($EA ZP BRAM) — CTRL-C check called from BASIC inner loop.
    ; Same T65 JMP-indirect timing fix as VEC_IN/OUT/LD/SV.
    ; The wrapper keeps ordinary input bytes pending so STOP polling
    ; cannot consume them before the line editor sees them.
    lda #<EHB_CTRLC
    sta VEC_CC
    lda #>EHB_CTRLC
    sta VEC_CC+1

    ; Diag R: all ZP vector writes done
    lda #'R'
    jsr EHB_UART_CHROUT

    ; Diag S+H: UART-only startup markers. Keep these off VEC_OUT so the
    ; first visible EhBASIC screen starts cleanly at the home position.
    lda #'S'
    jsr EHB_UART_CHROUT
    lda #'H'
    jsr EHB_UART_CHROUT
    lda #'U'
    jsr EHB_UART_CHROUT

    jsr print_boot_banner

    jmp LAB_COLD                ; EhBASIC cold start (never returns)

print_boot_banner:
    ldx #0
boot_banner_loop:
    lda boot_banner,x
    beq boot_banner_done
    jsr KERNAL_CHROUT
    inx
    bne boot_banner_loop
boot_banner_done:
    rts

boot_banner:
    .byte $0D
    .byte " **** 6502 SBC BASIC V2 ****", $0D
    .byte " TANG PRIMER 20K FPGA SYSTEM", $0D
    .byte " 6502 CPU  HDMI  UART  SD DISK", $0D
    .byte 0

; ============================================================
; IRQ / NMI handlers — live in ROM (shadow BRAM), not SDRAM.
; $FFFE points here directly; no SDRAM copy needed.
; Update IrqBase/NmiBase (ZP $DF/$DC) flags for EhBASIC's ON IRQ/NMI.
; ============================================================
IRQ_CODE:
    pha
    lda IRQ_FLAG_ZP
    lsr a
    ora IRQ_FLAG_ZP
    sta IRQ_FLAG_ZP
    pla
    rti

NMI_CODE:
    pha
    lda NMI_FLAG_ZP
    lsr a
    ora NMI_FLAG_ZP
    sta NMI_FLAG_ZP
    pla
    rti
IRQ_NMI_CODE_END:   ; (kept for size reference only)

; ============================================================
; SD Disk Controller hardware registers ($8824-$882F)
; ============================================================
DISK_CMD    = $8824
DISK_STATUS = $8825
DISK_SECT0  = $8826
DISK_SECT1  = $8827
DISK_SECT2  = $8828
DISK_SECT3  = $8829
DISK_DATA   = $882A
DISK_DPTRL  = $882B
DISK_DPTRH  = $882C

DISK_DST_L  = $F2       ; ZP temp: destination address
DISK_DST_H  = $F3
DISK_END_L  = $02F0     ; temp: end address
DISK_END_H  = $02F1

; ============================================================
; EHB_DISK_LOAD — Load from sector 2 (512 bytes max)
; ============================================================
EHB_DISK_LOAD:
    lda DISK_STATUS
    and #$80
    bne @ok
    jmp disk_not_ready
@ok:
    lda #2
    sta DISK_SECT0
    stz DISK_SECT1
    stz DISK_SECT2
    stz DISK_SECT3
    jsr disk_cmd_read
    bcc @rd
    jmp disk_error
@rd:
    stz DISK_DPTRL
    stz DISK_DPTRH
    lda DISK_DATA
    sta DISK_END_L
    lda DISK_DATA
    sta DISK_END_H

    lda Smeml
    sta DISK_DST_L
    lda Smemh
    sta DISK_DST_H

    ldy #0
@loop:
    lda DISK_DATA
    sta (DISK_DST_L),y
    iny
    cpy DISK_END_L
    bcc @loop
    beq @check_hi
    bcs @done

@check_hi:
    lda DISK_DST_H
    cmp Smemh
    bne @done
    jmp @done

@done:
    lda DISK_END_L
    clc
    adc Smeml
    sta Svarl
    lda DISK_END_H
    adc Smemh
    sta Svarh

    ldx #0
@msg:
    lda msg_loaded,x
    beq @warm
    jsr KERNAL_CHROUT
    inx
    bne @msg
@warm:
    jmp LAB_WARM

; ============================================================
; EHB_DISK_SAVE — Save to sector 2 (512 bytes max)
; ============================================================
EHB_DISK_SAVE:
    lda DISK_STATUS
    and #$80
    bne @ok
    jmp disk_not_ready
@ok:
    sec
    lda Svarl
    sbc Smeml
    sta DISK_END_L
    lda Svarh
    sbc Smemh
    sta DISK_END_H

    lda #2
    sta DISK_SECT0
    stz DISK_SECT1
    stz DISK_SECT2
    stz DISK_SECT3

    stz DISK_DPTRL
    stz DISK_DPTRH
    lda DISK_END_L
    sta DISK_DATA
    lda DISK_END_H
    sta DISK_DATA

    lda Smeml
    sta DISK_DST_L
    lda Smemh
    sta DISK_DST_H

    ldy #0
@loop:
    lda (DISK_DST_L),y
    sta DISK_DATA
    iny
    cpy DISK_END_L
    bcc @loop
    beq @flush
    bcs @flush

@flush:
    jsr disk_cmd_write
    bcc @done
    jmp disk_error

@done:
    ldx #0
@msg:
    lda msg_saved,x
    beq @done2
    jsr KERNAL_CHROUT
    inx
    bne @msg
@done2:
    rts

; ============================================================
; Helper: read/write SD sector
; ============================================================
disk_cmd_read:
    stz DISK_DPTRL
    stz DISK_DPTRH
    lda #$01
    sta DISK_CMD
@wait:
    lda DISK_STATUS
    lsr a
    bcs @wait
    lda DISK_STATUS
    and #$02
    beq @ok
    sec
    rts
@ok:
    clc
    rts

disk_cmd_write:
    lda #$02
    sta DISK_CMD
@wait:
    lda DISK_STATUS
    lsr a
    bcs @wait
    lda DISK_STATUS
    and #$02
    beq @ok
    sec
    rts
@ok:
    clc
    rts

disk_not_ready:
    ldx #0
@lp:
    lda msg_not_ready,x
    beq @dn
    jsr KERNAL_CHROUT
    inx
    bne @lp
@dn:
    rts

disk_error:
    ldx #0
@lp:
    lda msg_disk_err,x
    beq @dn
    jsr KERNAL_CHROUT
    inx
    bne @lp
@dn:
    rts

msg_not_ready:
    .byte $0D, "?SD CARD NOT READY", $0D, $00
msg_disk_err:
    .byte $0D, "?DISK I/O ERROR", $0D, $00
msg_loaded:
    .byte $0D, "LOADED", $0D, $00
msg_saved:
    .byte $0D, "SAVED", $0D, $00

; ============================================================
; EHB_CTRLC — EhBASIC STOP/Ctrl-C poll hook.
; The stock handler reads VEC_IN and consumes every non-Ctrl-C byte while
; BASIC is polling.  Put normal bytes back for the real input loop.
; ============================================================
EHB_CTRLC:
    lda KERNAL_PENDING_FLAG
    bne ehb_ctrlc_done
    jsr KERNAL_CHRIN_NB
    bcc ehb_ctrlc_done
    cmp #$03
    beq ehb_ctrlc_stop
    sta KERNAL_PENDING_CHAR
    lda #1
    sta KERNAL_PENDING_FLAG
ehb_ctrlc_done:
    rts
ehb_ctrlc_stop:
    lda #$03
    jmp LAB_1636

; ============================================================
; EHB_UART_CHROUT — direct UART TX, used as EhBASIC VEC_OUT.
; A = character.  $0D -> CR+LF;  $0A -> ignored.
; Polls TDRE (bit4 of UART_SR) before each byte.
; ============================================================
EHB_UART_CHROUT:
    cmp #$0A
    beq uc_done                 ; drop bare LF (CR already sends CR+LF)
    pha
    cmp #$0D
    bne uc_char
uc_cr_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_cr_wait
    lda #$0D
    sta UART_DATA
uc_lf_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_lf_wait
    lda #$0A
    sta UART_DATA
    pla
    rts
uc_char:
uc_char_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_char_wait
    pla
    sta UART_DATA
uc_done:
    rts

; ============================================================
; EhBASIC V2.22 source (patched by build_fpga_ehbasic.py)
; ============================================================
.include "basic.asm"

; ============================================================
; The 6502 interrupt vectors ($FFFA-$FFFF) now live in the KERNEL ROM
; ($F000-$FFFF) and point at the fixed ENTRY_TABLE above
; ($A000/$A003/$A006).  EhBASIC therefore no longer defines a VECTORS
; segment.
; ============================================================
