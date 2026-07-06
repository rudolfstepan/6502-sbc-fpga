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
VIC_TEXT_COLOR  = $9003     ; foreground colour for subsequent CHROUT cells
VIC_TEXT_ATTR   = $9005     ; text attributes: bit1 = 80-column mode
VIC_TEXT_80     = $02
VIC_BORDER      = $D020     ; VIC-II border colour  (C64 $D020)
VIC_BACKGROUND  = $D021     ; VIC-II global screen background (C64 $D021)
KERNAL_DISK_MOUNT = $F01E   ; mount first .d64 on SD2  (C=0 ok)
KERNAL_DISK_DIR   = $F021   ; print directory of the mounted image
KERNAL_DISK_LOAD  = $F024   ; load PRG by name; DK_PTR -> name; C=0 ok
KERNAL_DISK_CALLADDR = $F02A ; print " CALL nnnnn" for the last loaded PRG
KERNAL_DISK_MENU  = $F033   ; interactive .d64 select menu (C=0 mounted, C=1 not)
KERNAL_PENDING_CHAR = $02F7
KERNAL_PENDING_FLAG = $02F8

; Kernel disk-routine scratch (must match sw/kernel.s)
DK_PTR    = $F2             ; 16-bit name pointer used by KERNAL_DISK_LOAD
DK_STARTL = $0365           ; PRG load start address (filled by DISK_LOAD)
DK_STARTH = $0366
DK_ENDL   = $0367           ; PRG end address +1
DK_ENDH   = $0368
NAMEBUF   = $0369           ; up to 17 bytes: filename + null

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

    lda #VIC_TEXT_80
    sta VIC_TEXT_ATTR            ; 80x25 text before the screen is cleared

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

; Boot banner palette: green border, black screen, light-blue text/rules.
; Ends by leaving light-blue as the default BASIC text colour.
print_boot_banner:
    lda #$05                ; green border
    sta VIC_BORDER
    lda #$00                ; black background
    sta VIC_BACKGROUND

    lda #$0E                ; light blue
    ldx #<ban_rule
    ldy #>ban_rule
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_title
    ldy #>ban_title
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_sys
    ldy #>ban_sys
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_feat
    ldy #>ban_feat
    jsr banner_seg
    lda #$0E                ; light blue
    ldx #<ban_rule2
    ldy #>ban_rule2
    jsr banner_seg
    lda #$0E                ; light blue for BASIC text + prompt
    sta VIC_TEXT_COLOR
    rts

; banner_seg: A = colour, X/Y = lo/hi of a null-terminated string.
; The kernel STROUT is unreliable -- its pointer high byte ($EE) aliases nothing
; useful while the indirect load reads $EC, which is CHROUT's own screen-pointer
; scratch -- so we print the bytes ourselves.  CHROUT preserves A/X/Y and only
; clobbers $EC/$ED, so a transient ZP pointer in the disk scratch ($F2/$F3,
; unused until the first LOAD) survives the loop.
BANPTR = $F2
banner_seg:
    sta VIC_TEXT_COLOR
    stx BANPTR
    sty BANPTR+1
    ldy #0
banner_seg_loop:
    lda (BANPTR),y
    beq banner_seg_done
    jsr KERNAL_CHROUT
    iny
    bne banner_seg_loop     ; each banner string is < 256 bytes
banner_seg_done:
    rts

ban_rule:
    .byte $0D, " "
    .repeat 78
    .byte $60
    .endrepeat
    .byte $0D, 0
ban_title:
    .byte "  6502 SMART BUSINESS COMPUTER                         ENHANCED BASIC 2.22", $0D, 0
ban_sys:
    .byte "  VIDEO  80x25 TEXT       CPU  65C02/T65       OUTPUT  HDMI + UART", $0D, 0
ban_feat:
    .byte "  STORAGE  SD DISK        BASIC RAM  $0300-$3FFF        KERNEL  $F000", $0D, 0
ban_rule2:
    .byte " "
    .repeat 78
    .byte $60
    .endrepeat
    .byte $0D, 0

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
; EHB_DISK_LOAD — BASIC LOAD "NAME".  Thin wrapper: parse the filename from
; the BASIC line, then call the kernel disk loader ($F024), which mounts (via
; the kernel) and loads the PRG to its embedded load address.  Disk format,
; directory walk and PRG-chain following all live in the KERNEL, not here.
;
; EhBASIC reaches here via JMP (VEC_LD) from the LOAD token with the text
; cursor positioned after LOAD.  We evaluate the string expression, copy the
; (<=16 char) name to NAMEBUF, and hand a pointer to the kernel.
; ============================================================
LD_SRC = $F4               ; ZP temp pointer to the evaluated string

EHB_DISK_LOAD:
    ; ensure an image is mounted (kernel call; idempotent)
    jsr KERNAL_DISK_MOUNT
    bcc @mounted
    jmp disk_not_ready
@mounted:
    jsr LAB_EVEX            ; evaluate the "NAME" string expression
    jsr LAB_22B6            ; A=len, X=ptr lo, Y=ptr hi of the string
    stx LD_SRC
    sty LD_SRC+1
    cmp #17
    bcc @lenok
    lda #16                ; clamp to 16 chars
@lenok:
    tax                    ; X = length remaining to copy
    ldy #0
@copy:
    cpx #0
    beq @copydone
    lda (LD_SRC),y
    sta NAMEBUF,y
    iny
    dex
    jmp @copy
@copydone:
    lda #0
    sta NAMEBUF,y          ; null-terminate

    ; LOAD "!"  -> interactive .d64 select menu.  Lets the user pick which disk
    ; image to mount with the cursor keys, then prints its directory.  Returns to
    ; BASIC without touching the program in memory.
    lda NAMEBUF
    cmp #'!'
    bne @notmenu
    lda NAMEBUF+1          ; must be exactly "!" (single char)
    bne @notmenu
    jsr KERNAL_DISK_MENU
    bcs @menuend          ; cancelled / none / error -> just return
    jsr KERNAL_DISK_DIR   ; show the freshly mounted disk
@menuend:
    jmp LAB_WARM
@notmenu:

    ; LOAD "$"  -> print the directory (1541-style) and return to BASIC,
    ; without touching the program in memory.
    lda NAMEBUF
    cmp #'$'
    bne @loadfile
    lda NAMEBUF+1          ; must be exactly "$" (single char)
    bne @loadfile
    jsr KERNAL_DISK_DIR
    jmp LAB_WARM

@loadfile:
    lda #<NAMEBUF
    sta DK_PTR
    lda #>NAMEBUF
    sta DK_PTR+1
    jsr KERNAL_DISK_LOAD
    bcc @ok
    jmp disk_error
@ok:
    ldx #0
@msg:
    lda msg_loaded,x
    beq @calladdr
    jsr KERNAL_CHROUT
    inx
    bne @msg
@calladdr:
    jsr KERNAL_DISK_CALLADDR    ; append " CALL nnnnn" so the user can run it
@warm:
    jmp LAB_WARM

; ============================================================
; EHB_DISK_SAVE — Save to sector 2 (512 bytes max)
; ============================================================
; SAVE is not implemented yet (write support is the next step — it needs BAM
; allocation + directory write in the kernel).  Report it and return to BASIC.
EHB_DISK_SAVE:
    ldx #0
@msg:
    lda msg_nosave,x
    beq @done
    jsr KERNAL_CHROUT
    inx
    bne @msg
@done:
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
    .byte $0D, "?NO DISK MOUNTED", $0D, $00
msg_disk_err:
    .byte $0D, "?FILE NOT FOUND", $0D, $00
msg_loaded:
    .byte $0D, "LOADED", $00         ; DISK_CALLADDR appends " CALL nnnnn" + CR
msg_nosave:
    .byte $0D, "?SAVE NOT IMPLEMENTED", $0D, $00

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
