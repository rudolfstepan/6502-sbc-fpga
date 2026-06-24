; ============================================================
; 6502 SBC Kernel v1.1 (FPGA)
; ROM: $F000-$FFFF  (4KB).  Linked by sw/kernel.cfg; combined with EhBASIC
; into the 16 KB shadow ROM by tools/build_fpga_ehbasic.py.
;
; Fixed jump table at $F000 (kernel API for BASIC and apps):
;   $F000  JMP INIT        System init / RESET entry
;   $F003  JMP CHROUT      Output char  (A = char)
;   $F006  JMP CHRIN       Input char, blocking + echo  (returns A)
;   $F009  JMP CHRIN_NB    Input char, non-blocking  (A=char, C=1 if ready)
;   $F00C  JMP CLRSCR      Clear screen, home cursor
;   $F00F  JMP STROUT      Print null-terminated string (STRPTR_LO/HI ptr)
;   $F012  JMP NEWLINE     Print CR  ($0D)
;   $F015  JMP BASIC       Start BASIC ROM at $A000
;   $F018  JMP SETCURS     Set cursor  (X=col, Y=row)
;   $F01B  JMP SCROLL      Scroll screen up one line
;   $F01E  JMP DISK_MOUNT  Mount first .d64 on SD2  (C=0 ok)
;   $F021  JMP DISK_DIR    Print directory of the mounted image
;   $F024  JMP DISK_LOAD   Load PRG by name into BASIC memory (C=0 ok)
;   $F027  JMP DISK_SAVE   Reserved (write support; not yet implemented)
;
; The D64 GoDrive (FAT32 + D64 virtual disk) lives at $8824; see
; fpga/docs/D64_DRIVE.md.  The disk routines mirror fpga/sw/disk.s.
;
; EhBASIC owns almost all of zero page up to $FF. It marks $EB-$EE as unused.
;   $EB  STRPTR_LO  STROUT temporary pointer, low byte  (saved/restored)
;   $EC  CURSOR_X at rest; temporary screen pointer low byte inside CHROUT
;   $ED  CURSOR_Y at rest; temporary screen pointer high byte inside CHROUT
;   $EE  STRPTR_HI  STROUT temporary pointer, high byte (saved/restored)
;   $EF+ EhBASIC Decss (number-to-decimal buffer) — DO NOT USE in kernel
;
; Hardware:
;   VIC video RAM  $8000-$87FF  (40 x 25 = 1000 bytes)
;   VIA 6522       $8800-$880F  (keyboard on Port A / CA1)
; ============================================================

COLS        = 40
ROWS        = 25

VIC_BASE    = $8000
VIA_ORA     = $8801
VIA_DDRA    = $8803
VIA_IFR     = $880D
VIA_IER     = $880E
CA1_BIT     = $02

; ── D64 GoDrive register map (d64_subsystem at DEV_DISK $8824) ──────────────
DISK_STATUS  = $8824        ; R  bit0 BUSY bit1 DONE bit2 ERROR bit3 MOUNTED
DISK_COMMAND = $8825        ; W
DISK_TRACK   = $8826        ; RW (1-based)
DISK_SECTOR  = $8827        ; RW (0-based)
DISK_RESULT  = $8828        ; R  DISK_RESULT code
DISK_DATA    = $8829        ; R  sector-buffer port (read auto-increments)
DISK_PTR_LO  = $882A        ; RW buffer pointer 0..255

DCMD_READ    = $01
DCMD_MOUNT   = $03
STAT_BUSY    = $01
STAT_ERROR   = $04
STAT_MOUNTED = $08

VIC_GFX_MODE = $9000
VIC_CURSOR_X = $9001
VIC_CURSOR_Y = $9002

UART_DATA   = $8810         ; write = TX byte, read = RX byte
UART_SR     = $8811         ; bit 4 = TDRE (TX ready), bit 3 = RDRF (RX data)
UART_TDRE   = $10
UART_RDRF   = $08

; Cursor position is tracked in ZP BRAM and mirrored to the VIC cursor
; registers ($9001/$9002), where the text VIC draws a blinking cursor cell.
CURSOR_X    = $EC
CURSOR_Y    = $ED
SCRPTR_LO   = $EC
SCRPTR_HI   = $ED
; $EE is free (EhBASIC marks unused); $EF = EhBASIC Decss (number-to-string
; buffer) — DO NOT USE $EF or above for kernel vars: PRINT I writes $EF..$F4.
STRPTR_LO   = $EB
STRPTR_HI   = $EE

CMD_BUF     = $0200     ; command line buffer in page 2 (64 bytes)
CMD_MAX     = 38        ; max usable chars per command line

; Screen editor replay buffer.  Used by FPGA keyboard cursor editing: when
; Enter is pressed after moving the hardware cursor, the full screen line
; is read (C64-style), trailing spaces trimmed, and replayed to BASIC one
; character per CHRIN call.  CHROUT suppresses echo while POS < LEN so the
; line is not duplicated on screen.
SCREEN_REPLAY_BUF  = $02C0
SCREEN_EDIT_ACTIVE = $02F0
SCREEN_REPLAY_POS  = $02F1
SCREEN_REPLAY_LEN  = $02F2
SCREEN_REPLAY_CHAR = $02F3
SCREEN_SAVED_X     = $02F4
SCREEN_SAVED_Y     = $02F5
SCREEN_RETURN_CHAR = $02F6
SCREEN_PENDING_CHAR = $02F7
SCREEN_PENDING_FLAG = $02F8

VIC_TEXT_COLOR = $9003          ; foreground color register (0-15)
VIC_BG_COLOR   = $9004          ; background color register (0-15)
VIC_COLOR_BASE = $8400          ; color RAM: per-cell bg[7:4] | fg[3:0]

KEY_CRSR_DOWN  = $11
KEY_HOME       = $13
KEY_CRSR_RIGHT = $1D
KEY_CRSR_UP    = $91
KEY_CLEAR      = $93
KEY_CRSR_LEFT  = $9D
KEY_BACKSPACE  = $08

BASIC_ENTRY = $A000     ; BASIC ROM entry point (EhBASIC relocated to $A000-$CFFF)

; ============================================================
; JUMP TABLE  -- placed first so it lands exactly at $C000
; ============================================================
.segment "JUMPTAB"
    jmp INIT            ; $C000
    jmp CHROUT          ; $C003
    jmp CHRIN           ; $C006
    jmp CHRIN_NB        ; $C009
    jmp CLRSCR          ; $C00C
    jmp STROUT          ; $C00F
    jmp NEWLINE         ; $C012
    jmp BASIC           ; $C015
    jmp SETCURS         ; $F018
    jmp SCROLL          ; $F01B
    jmp DISK_MOUNT      ; $F01E
    jmp DISK_DIR        ; $F021
    jmp DISK_LOAD       ; $F024
    jmp DISK_SAVE       ; $F027
    jmp DISK_CALLADDR   ; $F02A  print "CALL nnnnn" for the last loaded PRG
NMI_HANDLER:
    rti                 ; NMI: ignore
IRQ_HANDLER:
    rti                 ; IRQ: ignore (kernel uses polling, not interrupts)

; ============================================================
; CODE
; ============================================================
.segment "CODE"

; ------------------------------------------------------------
; INIT -- system initialisation, entered on RESET
; ------------------------------------------------------------
.proc INIT
    ldx #$FF
    txs                     ; init stack pointer
    lda #$00
    sta VIA_DDRA            ; VIA Port A = all input (keyboard)
    lda #$01                ; white
    sta VIC_TEXT_COLOR
    lda #$00                ; black
    sta VIC_BG_COLOR
    jsr CLRSCR
    jsr show_welcome
    ; Auto-start BASIC (like C64)
    jmp BASIC               ; jump to BASIC ROM - never return
.endproc

; ------------------------------------------------------------
; CHROUT -- write character A to VIC screen at cursor position
; Preserves: X, Y registers (required for MS BASIC and kernel compatibility)
; ------------------------------------------------------------
.proc CHROUT
    ; Suppress echo while screen replay is active (POS < LEN).
    ; The final CR has POS == LEN so it passes through normally.
    pha
    lda SCREEN_REPLAY_POS
    cmp SCREEN_REPLAY_LEN
    pla
    bcs no_suppress
    rts
no_suppress:
    ; Save registers at entry
    pha                     ; save A
    txa
    pha                     ; save X
    tya
    pha                     ; save Y

    ; Get A back for comparison
    tsx
    lda $0103,x             ; peek at saved A (3 bytes down from SP)
    jsr uart_put            ; mirror to UART (preserves A, $0D -> CR+LF)

    cmp #$0D
    beq newline_cr
    cmp #$0A
    beq restore             ; ignore LF (0x0A) - only CR (0x0D) triggers newline
    cmp #$08
    beq backspace

    ; --- normal printable character ---
    ldx CURSOR_X
    ldy CURSOR_Y
    tya
    pha
    txa
    pha
    jsr calc_ptr_xy
    tsx
    lda $0105,x             ; get saved A below cursor scratch bytes
    jsr to_upper            ; lowercase ASCII overlaps PETSCII graphics
    ldy #0
    sta (SCRPTR_LO),y      ; write character
    jsr write_color_attr   ; write color to $8400+offset
    pla
    tax
    pla
    tay
    inx
    cpx #COLS
    bcc done
    ; fall through to newline
newline:
    ldx #0
    iny
    jmp newline_check
newline_cr:
    ldx #0
    ldy CURSOR_Y
    iny
newline_check:
    cpy #ROWS
    bcc done
    jsr SCROLL
    ldy #(ROWS-1)
    jmp done

backspace:
    ldx CURSOR_X
    beq restore
    dex
    ldy CURSOR_Y
    tya
    pha
    txa
    pha
    jsr calc_ptr_xy
    lda #$20
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    pla
    tax
    pla
    tay

done:
    stx CURSOR_X
    sty CURSOR_Y
    stx VIC_CURSOR_X
    sty VIC_CURSOR_Y
restore:
    ; Restore registers (reverse order)
    pla
    tay
    pla
    tax
    pla                     ; restore A
    rts
.endproc

; ------------------------------------------------------------
; CHRIN -- blocking keyboard read with echo; returns char in A
;          Converts lowercase a-z to uppercase A-Z
; ------------------------------------------------------------
.proc CHRIN
loop:
    jsr CHRIN_NB
    bcc loop
    pha
    lda SCREEN_REPLAY_CHAR
    beq echo
    lda #0
    sta SCREEN_REPLAY_CHAR
    pla
    jmp convert
echo:
    pla
    pha             ; save the character (CHROUT will clobber A)
    jsr CHROUT      ; echo
    pla             ; restore original character into A
convert:
    ; convert lowercase to uppercase (a-z -> A-Z)
    cmp #'a'
    bcc done
    cmp #'z'+1
    bcs done
    and #$DF        ; clear bit 5 -> uppercase
done:
    rts
.endproc

; ------------------------------------------------------------
; CHRIN_NB -- non-blocking keyboard read
;             A = char, C = 1 if a key was available
; ------------------------------------------------------------
.proc CHRIN_NB
    txa
    pha
    tya
    pha

    lda SCREEN_PENDING_FLAG
    beq no_pending
    lda #0
    sta SCREEN_PENDING_FLAG
    lda SCREEN_PENDING_CHAR
    jmp got_char

no_pending:
    jsr replay_next
    bcs got_char

    lda UART_SR             ; check UART RX first
    and #UART_RDRF
    beq try_via
    lda UART_DATA           ; read byte (clears RDRF)
    jsr handle_screen_key
    bcc nothing
    jsr to_upper
    jmp got_char
try_via:
    lda VIA_IFR
    and #CA1_BIT
    beq nothing
    lda VIA_ORA
    jsr handle_screen_key
    bcc nothing
    jsr to_upper
got_char:
    sta SCREEN_RETURN_CHAR
    pla
    tay
    pla
    tax
    lda SCREEN_RETURN_CHAR
    sec
    rts
nothing:
    pla
    tay
    pla
    tax
    clc
    rts
.endproc

; ------------------------------------------------------------
; replay_next -- return the next queued screen-editor character
;                C=1 and A=char if available, C=0 otherwise
; ------------------------------------------------------------
.proc replay_next
    ldx SCREEN_REPLAY_POS
    cpx SCREEN_REPLAY_LEN
    bcc have
    clc
    rts
have:
    lda SCREEN_REPLAY_BUF,x
    inx
    stx SCREEN_REPLAY_POS
    ldx #1
    stx SCREEN_REPLAY_CHAR
    sec
    rts
.endproc

; ------------------------------------------------------------
; handle_screen_key -- consume PETSCII-style screen editor keys
;                      C=0 consumed, C=1 pass A through to BASIC
; ------------------------------------------------------------
.proc handle_screen_key
    cmp #KEY_CRSR_LEFT
    beq cursor_left
    cmp #KEY_CRSR_RIGHT
    bne :+
    jmp cursor_right
:
    cmp #KEY_CRSR_UP
    bne :+
    jmp cursor_up
:
    cmp #KEY_CRSR_DOWN
    bne :+
    jmp cursor_down
:
    cmp #KEY_HOME
    bne :+
    jmp home
:
    cmp #KEY_CLEAR
    bne :+
    jmp clear
:
    cmp #KEY_BACKSPACE
    bne :+
    jmp edit_backspace
:
    cmp #$0D
    bne pass_key
    jmp enter
pass_key:
    ldx SCREEN_EDIT_ACTIVE
    bne edit_printable
    sec
    rts

edit_printable:
    cmp #$20
    bcc pass_printable
    jsr to_upper
    sta SCREEN_RETURN_CHAR
    ldx CURSOR_X
    ldy CURSOR_Y
    stx SCREEN_SAVED_X
    sty SCREEN_SAVED_Y
    jsr calc_ptr_xy
    lda SCREEN_RETURN_CHAR
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    inx
    cpx #COLS
    bcc edit_printable_moved
    ldx #0
    iny
    cpy #ROWS
    bcc edit_printable_moved
    ldx #(COLS-1)
    ldy #(ROWS-1)
edit_printable_moved:
    jsr SETCURS
    clc
    rts
pass_printable:
    sec
    rts

cursor_left:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpx #0
    bne left_dec
    cpy #0
    bne left_wrap
    jmp moved
left_wrap:
    ldx #(COLS-1)
    dey
    jmp moved
left_dec:
    dex
    jmp moved

cursor_right:
    ldx CURSOR_X
    ldy CURSOR_Y
    inx
    cpx #COLS
    bcc moved
    ldx #0
    iny
    cpy #ROWS
    bcc moved
    ldx #(COLS-1)
    ldy #(ROWS-1)
    jmp moved

cursor_up:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpy #0
    beq moved
    dey
    jmp moved

cursor_down:
    ldx CURSOR_X
    ldy CURSOR_Y
    iny
    cpy #ROWS
    bcc moved
    ldy #(ROWS-1)
    jmp moved

home:
    ldx #0
    ldy #0
    jmp moved

clear:
    jsr CLRSCR
    clc
    rts

edit_backspace:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpx #0
    bne backspace_left
    cpy #0
    beq edit_backspace_done
    ldx #(COLS-1)
    dey
    jmp backspace_erase
backspace_left:
    dex
backspace_erase:
    stx SCREEN_SAVED_X
    sty SCREEN_SAVED_Y
    jsr SETCURS
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    jsr calc_ptr_xy
    lda #$20
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    jsr SETCURS
    lda #1
    sta SCREEN_EDIT_ACTIVE
edit_backspace_done:
    clc
    rts

moved:
    jsr SETCURS
    lda #1
    sta SCREEN_EDIT_ACTIVE
    clc
    rts

enter:
    lda SCREEN_EDIT_ACTIVE
    bne replay_line
    lda #$0D
    sec
    rts
replay_line:
    jsr build_screen_replay
    rts
.endproc

; ------------------------------------------------------------
; build_screen_replay -- read full screen line, trim trailing spaces, add CR
;                        returns first queued char with C=1
; ------------------------------------------------------------
.proc build_screen_replay
    lda CURSOR_X
    sta SCREEN_SAVED_X
    lda CURSOR_Y
    sta SCREEN_SAVED_Y

    ldx #0
    ldy SCREEN_SAVED_Y
    jsr calc_ptr_xy

    ldy #0
copy:
    cpy #COLS
    beq copied
    lda (SCRPTR_LO),y
    sta SCREEN_REPLAY_BUF,y
    iny
    jmp copy
copied:
    sty SCREEN_REPLAY_LEN

trim:
    lda SCREEN_REPLAY_LEN
    beq add_cr
    tax
    dex
    lda SCREEN_REPLAY_BUF,x
    cmp #$20
    bne add_cr
    dec SCREEN_REPLAY_LEN
    jmp trim

add_cr:
    ldx SCREEN_REPLAY_LEN
    lda #$0D
    sta SCREEN_REPLAY_BUF,x
    inx
    stx SCREEN_REPLAY_LEN
    lda #0
    sta SCREEN_REPLAY_POS
    sta SCREEN_EDIT_ACTIVE

    ldx #0
    ldy SCREEN_SAVED_Y
    jsr SETCURS
    jsr replay_next
    rts
.endproc

; to_upper -- convert a-z to A-Z in A, leave everything else unchanged
.proc to_upper
    cmp #'a'
    bcc done
    cmp #'z'+1
    bcs done
    and #$DF
done:
    rts
.endproc

; ------------------------------------------------------------
; CLRSCR -- fill VIC RAM with spaces, reset cursor to (0,0)
; ------------------------------------------------------------
.proc CLRSCR
    ; Diagnostic: busy-wait for TDRE then send '*' to confirm kernel alive
    pha
clrscr_diag:
    lda UART_SR
    and #UART_TDRE
    beq clrscr_diag
    lda #'*'
    sta UART_DATA
    pla
    ; Fill character area ($8000-$83FF) with spaces
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    lda #$20                ; space character
    ldy #0
    ldx #4                  ; 4 x 256 = 1024 bytes
char_loop:
    sta (SCRPTR_LO),y
    iny
    bne char_loop
    inc SCRPTR_HI
    dex
    bne char_loop
    ; SCRPTR_HI is now $84 (start of color area)
    ; Fill color area ($8400-$87FF) with composed color byte
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    ldy #0
    ldx #4                  ; 4 x 256 = 1024 bytes
color_loop:
    sta (SCRPTR_LO),y
    iny
    bne color_loop
    inc SCRPTR_HI
    dex
    bne color_loop
    lda #0
    sta CURSOR_X
    sta CURSOR_Y
    sta VIC_CURSOR_X
    sta VIC_CURSOR_Y
    sta SCREEN_EDIT_ACTIVE
    sta SCREEN_REPLAY_POS
    sta SCREEN_REPLAY_LEN
    sta SCREEN_REPLAY_CHAR
    sta SCREEN_RETURN_CHAR
    sta SCREEN_PENDING_CHAR
    sta SCREEN_PENDING_FLAG
    rts
.endproc

; ------------------------------------------------------------
; STROUT -- print null-terminated string
;           A = string address low byte
;           Y = string address high byte
; Preserves: none
; Note: Compatible with MS BASIC calling convention
; ------------------------------------------------------------
.proc STROUT
    pha                     ; save argument low byte while preserving temp ptr
    lda STRPTR_LO
    pha
    lda STRPTR_HI
    pha
    tsx
    lda $0103,x             ; original A argument
    sta STRPTR_LO           ; store pointer
    sty STRPTR_HI
loop:
    ldy #0
    lda (STRPTR_LO),y       ; read current byte
    beq done
    jsr CHROUT
    inc STRPTR_LO           ; advance pointer
    bne loop
    inc STRPTR_HI
    jmp loop
done:
    pla
    sta STRPTR_HI
    pla
    sta STRPTR_LO
    pla                     ; discard saved argument low byte
    rts
.endproc

; ------------------------------------------------------------
; NEWLINE -- print a carriage-return character
; ------------------------------------------------------------
.proc NEWLINE
    lda #$0D
    jmp CHROUT
.endproc

; ------------------------------------------------------------
; BASIC -- hand control to BASIC ROM at $D000
; ------------------------------------------------------------
.proc BASIC
    jsr BASIC_ENTRY         ; JSR so BYE can return to kernel
    rts
.endproc

; ------------------------------------------------------------
; SETCURS -- set cursor position  (X = column, Y = row)
; ------------------------------------------------------------
.proc SETCURS
    cpx #COLS
    bcs done
    cpy #ROWS
    bcs done
    stx CURSOR_X
    sty CURSOR_Y
    stx VIC_CURSOR_X
    sty VIC_CURSOR_Y
done:
    rts
.endproc

; ------------------------------------------------------------
; SCROLL -- scroll the screen up one line, clear bottom row
; Preserves: A, X, Y (required by CHROUT compatibility)
; ------------------------------------------------------------
.proc SCROLL
    ; Save registers: SCROLL is in the public jump table ($C01B) so callers
    ; beyond CHROUT expect A/X/Y to be preserved. Without this, the clr loop
    ; exits with X=COLS=40, which CHROUT then stores into CURSOR_X, causing
    ; every subsequent character to immediately trigger another scroll.
    pha                     ; save A
    txa
    pha                     ; save X
    tya
    pha                     ; save Y

    ; Copy 24 * 40 = 960 bytes from row 1 to row 0 (character codes)
    ldx #0
copy0:
    lda VIC_BASE + COLS,x
    sta VIC_BASE,x
    inx
    bne copy0

copy1:
    lda VIC_BASE + COLS + $100,x
    sta VIC_BASE + $100,x
    inx
    bne copy1

copy2:
    lda VIC_BASE + COLS + $200,x
    sta VIC_BASE + $200,x
    inx
    bne copy2

copy3:
    lda VIC_BASE + COLS + $300,x
    sta VIC_BASE + $300,x
    inx
    cpx #192
    bne copy3

    ; clear last character row
    lda #$20
    ldx #0
clr:
    sta VIC_BASE + (ROWS-1)*COLS,x
    inx
    cpx #COLS
    bne clr

    ; Scroll color RAM ($8400-$87C0) — same pattern as character scroll
    ldx #0
ccopy0:
    lda VIC_COLOR_BASE + COLS,x
    sta VIC_COLOR_BASE,x
    inx
    bne ccopy0

ccopy1:
    lda VIC_COLOR_BASE + COLS + $100,x
    sta VIC_COLOR_BASE + $100,x
    inx
    bne ccopy1

ccopy2:
    lda VIC_COLOR_BASE + COLS + $200,x
    sta VIC_COLOR_BASE + $200,x
    inx
    bne ccopy2

ccopy3:
    lda VIC_COLOR_BASE + COLS + $300,x
    sta VIC_COLOR_BASE + $300,x
    inx
    cpx #192
    bne ccopy3

    ; clear last color row with composed color byte
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    ldx #0
cclr:
    sta VIC_COLOR_BASE + (ROWS-1)*COLS,x
    inx
    cpx #COLS
    bne cclr

    ; Restore registers in reverse order
    pla
    tay                     ; restore Y
    pla
    tax                     ; restore X
    pla                     ; restore A
    rts
.endproc

; ------------------------------------------------------------
; calc_ptr_xy -- set SCRPTR = VIC_BASE + Y*COLS + X
;             (internal helper, not in jump table)
; ------------------------------------------------------------
.proc calc_ptr_xy
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    cpy #0
    beq add_x
mul_loop:
    clc
    lda SCRPTR_LO
    adc #COLS
    sta SCRPTR_LO
    bcc no_carry
    inc SCRPTR_HI
no_carry:
    dey
    bne mul_loop
add_x:
    clc
    lda SCRPTR_LO
    txa
    adc SCRPTR_LO
    sta SCRPTR_LO
    bcc done
    inc SCRPTR_HI
done:
    rts
.endproc

; ------------------------------------------------------------
; write_color_attr -- write CUR_COLOR to color RAM at SCRPTR+$0400
;                     Y must be 0. Clobbers A, SCRPTR_HI.
; ------------------------------------------------------------
.proc write_color_attr
    lda SCRPTR_HI
    clc
    adc #$04
    sta SCRPTR_HI
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    sta (SCRPTR_LO),y
    rts
.endproc

; ------------------------------------------------------------
; show_welcome -- print the startup banner
; ------------------------------------------------------------
.proc show_welcome
    lda #<welcome_str
    ldy #>welcome_str
    jsr STROUT
    rts
.endproc

; ------------------------------------------------------------
; cmd_loop -- main kernel command interpreter (infinite loop)
; ------------------------------------------------------------
.proc cmd_loop
loop:
    lda #<prompt_str
    ldy #>prompt_str
    jsr STROUT
    jsr read_line
    jsr exec_cmd
    jmp loop
.endproc

; ------------------------------------------------------------
; read_line -- read keyboard input into CMD_BUF
;              max CMD_MAX chars, converts to uppercase
;              null-terminates the buffer
; ------------------------------------------------------------
.proc read_line
    ldx #0
loop:
    jsr CHRIN               ; blocking read + echo
    cmp #$0D
    beq done
    cmp #$08                ; backspace?
    beq backspace
    cpx #CMD_MAX            ; buffer full?
    bcs loop
    ; convert lowercase to uppercase
    cmp #'a'
    bcc store
    cmp #'z'+1
    bcs store
    and #$DF                ; clear bit 5 -> uppercase
store:
    sta CMD_BUF,x
    inx
    jmp loop
backspace:
    cpx #0
    beq loop
    dex
    jmp loop
done:
    lda #0
    sta CMD_BUF,x           ; null-terminate
    ; no extra NEWLINE here -- CHRIN already echoed the CR
    rts
.endproc

; ------------------------------------------------------------
; exec_cmd -- parse CMD_BUF and execute the command
; ------------------------------------------------------------
.proc exec_cmd
    lda CMD_BUF
    beq done                ; empty input -> ignore

    ; ---- BASIC ----
    ldx #0
cmp_basic:
    lda cmd_basic_str,x
    beq basic_end
    cmp CMD_BUF,x
    bne try_help
    inx
    jmp cmp_basic
basic_end:
    lda CMD_BUF,x
    bne try_help
    jsr BASIC               ; hand off to MS BASIC
    jmp done

    ; ---- HELP ----
try_help:
    ldx #0
cmp_help:
    lda cmd_help_str,x
    beq help_end
    cmp CMD_BUF,x
    bne try_cls
    inx
    jmp cmp_help
help_end:
    lda CMD_BUF,x
    bne try_cls
    lda #<help_str
    ldy #>help_str
    jsr STROUT
    jmp done

    ; ---- CLS ----
try_cls:
    ldx #0
cmp_cls:
    lda cmd_cls_str,x
    beq cls_end
    cmp CMD_BUF,x
    bne try_dir
    inx
    jmp cmp_cls
cls_end:
    lda CMD_BUF,x
    bne try_dir
    jsr CLRSCR
    jmp done

    ; ---- DIR ----
try_dir:
    ldx #0
cmp_dir:
    lda cmd_dir_str,x
    beq dir_end
    cmp CMD_BUF,x
    bne try_unknown
    inx
    jmp cmp_dir
dir_end:
    lda CMD_BUF,x
    bne try_unknown
    jsr DISK_MOUNT          ; ensure an image is mounted (idempotent)
    jsr DISK_DIR
    jmp done

    ; ---- unknown ----
try_unknown:
    lda #<unknown_str
    ldy #>unknown_str
    jsr STROUT
done:
    rts
.endproc

; ============================================================
; D64 GoDrive kernel routines (mirror fpga/sw/disk.s).  Read-only Version 1:
; MOUNT, READ_SECTOR, directory walk, find PRG by name, load PRG chain.
;
; Kernel-safe scratch (EhBASIC leaves these free; same window as the kernel's
; other temporaries documented in ehbasic_fpga.s, $F2-$F7 plus page 2):
DK_PTR   = $F2          ; 16-bit general pointer (name / load dest)
DK_DST   = $F4          ; 16-bit PRG load destination
DK_TMP   = $F6          ; scratch byte
DK_CNT   = $F7          ; payload byte counter
; Page-2 state (not touched by EhBASIC's line editor at command level):
DK_ENTRY    = $0340     ; 32-byte current directory entry
DK_DIRT     = $0360     ; current dir-sector track
DK_DIRS     = $0361     ; current dir-sector sector
DK_DIRIX    = $0362     ; entry index within sector (0..7)
DK_LDTRK    = $0363     ; load: next block track
DK_LDSEC    = $0364     ; load: next block sector
DK_STARTL   = $0365     ; PRG start (load) address
DK_STARTH   = $0366
DK_ENDL     = $0367     ; PRG end address (last+1)
DK_ENDH     = $0368
DK_NUML     = $037A     ; print_dec16 working value low
DK_NUMH     = $037B     ; print_dec16 working value high
DK_DIG      = $037C     ; print_dec16 current digit
DK_LEAD     = $037D     ; print_dec16 leading-zero suppression flag

; D64 directory entry offsets
DE_TYPE   = 0
DE_TRACK  = 1
DE_SECTOR = 2
DE_NAME   = 3
DE_SIZEL  = 30
DE_SIZEH  = 31
FT_TYPEMASK = $07
FT_PRG      = $02

; ------------------------------------------------------------
; DISK_MOUNT -- scan FAT32, mount first .d64.  C=0 ok, C=1 fail.
; ------------------------------------------------------------
.proc DISK_MOUNT
    lda #DCMD_MOUNT
    sta DISK_COMMAND
    jsr disk_wait
    lda DISK_STATUS
    and #STAT_ERROR
    bne fail
    lda DISK_STATUS
    and #STAT_MOUNTED
    beq fail
    clc
    rts
fail:
    sec
    rts
.endproc

; ------------------------------------------------------------
; disk_wait -- spin until BUSY clears.  Clobbers A.
; ------------------------------------------------------------
.proc disk_wait
loop:
    lda DISK_STATUS
    and #STAT_BUSY
    bne loop
    rts
.endproc

; ------------------------------------------------------------
; disk_read_sector -- A=track, X=sector -> buffer.  C=0 ok, C=1 error.
; ------------------------------------------------------------
.proc disk_read_sector
    sta DISK_TRACK
    stx DISK_SECTOR
    lda #DCMD_READ
    sta DISK_COMMAND
    jsr disk_wait
    lda DISK_STATUS
    and #STAT_ERROR
    bne err
    clc
    rts
err:
    sec
    rts
.endproc

; ------------------------------------------------------------
; DISK_DIR -- print the directory of the mounted image.
; ------------------------------------------------------------
.proc DISK_DIR
    lda DISK_STATUS
    and #STAT_MOUNTED
    bne ok
    lda #<dir_err_str
    ldy #>dir_err_str
    jmp STROUT
ok:
    lda #<dir_header
    ldy #>dir_header
    jsr STROUT
    ; header line:  0 "DISKNAME"   (disk name from BAM T18/S0 offset $90)
    lda #18
    ldx #0
    jsr disk_read_sector
    bcs skiphdr
    lda #'0'
    jsr CHROUT
    lda #' '
    jsr CHROUT
    lda #'"'
    jsr CHROUT
    lda #$90               ; disk name starts at BAM offset $90
    sta DISK_PTR_LO
    ldx #16
hname:
    lda DISK_DATA
    cmp #$A0
    beq hname_end
    jsr CHROUT
    dex
    bne hname
    jmp hname_q
hname_end:
    ; consume remaining buffer reads not needed; just close the quote
hname_q:
    lda #'"'
    jsr CHROUT
    lda #$0D
    jsr CHROUT
skiphdr:
    jsr dir_open
    bcs done
nextent:
    jsr dir_next
    bcs done
    jsr print_entry
    jmp nextent
done:
    rts
.endproc

; dir_open -- start at T18/S1, read first directory sector
.proc dir_open
    lda #18
    sta DK_DIRT
    lda #1
    sta DK_DIRS
    lda #0
    sta DK_DIRIX
    lda DK_DIRT
    ldx DK_DIRS
    jmp disk_read_sector
.endproc

; dir_next -- next non-deleted entry into DK_ENTRY.  C=0 entry, C=1 end.
.proc dir_next
scan:
    lda DK_DIRIX
    cmp #8
    bcc have
    ; follow chain: next track/sector at buffer[0],[1]
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; next track
    sta DK_TMP
    lda DISK_DATA          ; next sector
    tax
    lda DK_TMP
    beq atend              ; next track 0 -> end
    sta DK_DIRT
    stx DK_DIRS
    jsr disk_read_sector
    bcs atend
    lda #0
    sta DK_DIRIX
    jmp scan
have:
    ; buffer offset = 2 + index*32
    lda DK_DIRIX
    asl
    asl
    asl
    asl
    asl
    clc
    adc #2
    sta DISK_PTR_LO
    ldy #0
copy:
    lda DISK_DATA
    sta DK_ENTRY,y
    iny
    cpy #32
    bne copy
    inc DK_DIRIX
    lda DK_ENTRY+DE_TYPE
    beq scan               ; deleted/empty -> skip
    clc
    rts
atend:
    sec
    rts
.endproc

; entry_is_prg -- C=0 if DK_ENTRY is a PRG
.proc entry_is_prg
    lda DK_ENTRY+DE_TYPE
    and #FT_TYPEMASK
    cmp #FT_PRG
    bne no
    clc
    rts
no:
    sec
    rts
.endproc

; print_entry -- 1541-style line:  blocks  "NAME" PRG
.proc print_entry
    lda DK_ENTRY+DE_SIZEL
    sta DK_NUML
    lda DK_ENTRY+DE_SIZEH
    sta DK_NUMH
    jsr print_dec16        ; block count, decimal
    lda #' '
    jsr CHROUT
    lda #'"'
    jsr CHROUT
    ldy #0
nloop:
    lda DK_ENTRY+DE_NAME,y
    cmp #$A0
    beq ndone
    jsr CHROUT
    iny
    cpy #16
    bne nloop
ndone:
    lda #'"'
    jsr CHROUT
    lda #' '
    jsr CHROUT
    ; print the type label with direct CHROUT (STROUT's stack-peek arg path is
    ; unreliable when called nested here, which printed garbage for "PRG").
    jsr entry_is_prg
    bcs notprg
    lda #'P'
    jsr CHROUT
    lda #'R'
    jsr CHROUT
    lda #'G'
    jsr CHROUT
    jmp eol
notprg:
    lda #'?'
    jsr CHROUT
    lda #'?'
    jsr CHROUT
    lda #'?'
    jsr CHROUT
eol:
    lda #$0D
    jmp CHROUT
.endproc

; print_dec16 -- print DK_NUML/H (16-bit) as decimal, no leading zeros.
; Powers of ten 10000..1 in dec_lo/dec_hi.  X = place index, DK_DIG = digit,
; DK_LEAD = 0 while still suppressing leading zeros.
.proc print_dec16
    ldx #0
    lda #0
    sta DK_LEAD
place:
    lda #0
    sta DK_DIG
sub:
    lda DK_NUML            ; try NUM - tenpow
    sec
    sbc dec_lo,x
    tay
    lda DK_NUMH
    sbc dec_hi,x
    bcc next_place         ; NUM < tenpow -> place done
    sty DK_NUML            ; commit subtraction
    sta DK_NUMH
    inc DK_DIG
    jmp sub
next_place:
    lda DK_DIG
    bne emit               ; non-zero digit -> always print
    lda DK_LEAD
    beq skip               ; still leading and digit==0 -> suppress
emit:
    lda #1
    sta DK_LEAD            ; mark that we have started printing digits
    lda DK_DIG
    clc
    adc #'0'
    jsr CHROUT
skip:
    inx
    cpx #5                 ; 5 places: 10000,1000,100,10,1
    bne place
    ; if the whole number was zero, nothing printed -> print a single '0'
    lda DK_LEAD
    bne done
    lda #'0'
    jsr CHROUT
done:
    rts
.endproc

dec_lo: .byte <10000, <1000, <100, <10, <1
dec_hi: .byte >10000, >1000, >100, >10, >1

; print_hex -- print A as two hex digits
.proc print_hex
    pha
    lsr
    lsr
    lsr
    lsr
    jsr nyb
    pla
    and #$0F
nyb:
    and #$0F
    cmp #10
    bcc dig
    clc
    adc #'A'-10
    jmp CHROUT
dig:
    clc
    adc #'0'
    jmp CHROUT
.endproc

; ------------------------------------------------------------
; DISK_LOAD -- load a PRG by name into BASIC memory.
; Input: DK_PTR = pointer to uppercase name (null-terminated).
; Output: C=0 ok (DK_STARTL/H = load addr, DK_ENDL/H = end+1); C=1 fail.
; ------------------------------------------------------------
.proc DISK_LOAD
    jsr find_prg
    bcs nf
    lda DK_ENTRY+DE_TRACK
    ldx DK_ENTRY+DE_SECTOR
    jmp load_chain
nf:
    sec
    rts
.endproc

; find_prg -- scan directory for PRG matching (DK_PTR).  C=0 -> DK_ENTRY.
.proc find_prg
    jsr dir_open
    bcs nf
next:
    jsr dir_next
    bcs nf
    jsr entry_is_prg
    bcs next
    jsr cmp_name
    bcs next
    clc
    rts
nf:
    sec
    rts
.endproc

; cmp_name -- compare (DK_PTR) name vs DK_ENTRY name. C=0 match.
.proc cmp_name
    ldy #0
loop:
    lda (DK_PTR),y
    beq nend
    cmp DK_ENTRY+DE_NAME,y
    bne mism
    iny
    cpy #16
    bne loop
    clc
    rts
nend:
    cpy #16
    beq ok
    lda DK_ENTRY+DE_NAME,y
    cmp #$A0
    bne mism
ok:
    clc
    rts
mism:
    sec
    rts
.endproc

; load_chain -- load PRG chain from A=track, X=sector into embedded load addr.
.proc load_chain
    sta DK_LDTRK
    stx DK_LDSEC

    ; first block
    lda DK_LDTRK
    ldx DK_LDSEC
    jsr disk_read_sector
    bcc fb_ok
    jmp err
fb_ok:
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; buffer[0] next track
    sta DK_LDTRK
    lda DISK_DATA          ; buffer[1] next sector / last index
    sta DK_LDSEC
    lda DISK_DATA          ; buffer[2] load lo
    sta DK_DST
    sta DK_STARTL
    lda DISK_DATA          ; buffer[3] load hi
    sta DK_DST+1
    sta DK_STARTH

    lda DK_LDTRK
    bne first_full
    ; single block: count = last_index - 3
    lda DK_LDSEC
    sec
    sbc #3
    sta DK_CNT
    lda #4
    sta DISK_PTR_LO
    jsr copy_payload
    jmp done
first_full:
    lda #252               ; buffer[4..255]
    sta DK_CNT
    lda #4
    sta DISK_PTR_LO
    jsr copy_payload

chain:
    lda DK_LDTRK
    ldx DK_LDSEC
    jsr disk_read_sector
    bcc cb_ok
    jmp err
cb_ok:
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; next track
    sta DK_LDTRK
    lda DISK_DATA          ; next sector / last index
    sta DK_LDSEC
    lda DK_LDTRK
    bne block_full
    lda DK_LDSEC
    sec
    sbc #1
    sta DK_CNT
    lda #2
    sta DISK_PTR_LO
    jsr copy_payload
    jmp done
block_full:
    lda #254               ; buffer[2..255]
    sta DK_CNT
    lda #2
    sta DISK_PTR_LO
    jsr copy_payload
    jmp chain

done:
    lda DK_DST
    sta DK_ENDL
    lda DK_DST+1
    sta DK_ENDH
    clc
    rts
err:
    sec
    rts
.endproc

; copy_payload -- copy DK_CNT bytes from DATA port to (DK_DST), advancing it.
.proc copy_payload
    ldx DK_CNT
    beq fin
    ldy #0
loop:
    lda DISK_DATA
    sta (DK_DST),y
    inc DK_DST
    bne noc
    inc DK_DST+1
noc:
    dex
    bne loop
fin:
    rts
.endproc

; ------------------------------------------------------------
; DISK_SAVE -- reserved (write support not yet implemented).  C=1.
; ------------------------------------------------------------
.proc DISK_SAVE
    sec
    rts
.endproc

; ------------------------------------------------------------
; DISK_CALLADDR -- print " CALL nnnnn" + CR for the PRG just loaded.
; By convention every PRG built for this system has its entry point at its load
; address, so the run address is simply DK_START (the PRG's embedded load addr).
; ------------------------------------------------------------
.proc DISK_CALLADDR
    lda DK_STARTL
    sta DK_NUML
    lda DK_STARTH
    sta DK_NUMH
    ; print " CALL " with direct CHROUT (STROUT arg path is unreliable nested)
    lda #' '
    jsr CHROUT
    lda #'C'
    jsr CHROUT
    lda #'A'
    jsr CHROUT
    lda #'L'
    jsr CHROUT
    lda #'L'
    jsr CHROUT
    lda #' '
    jsr CHROUT
    jsr print_dec16
    lda #$0D
    jmp CHROUT
.endproc

; ------------------------------------------------------------
; uart_put -- send char in A to hardware UART ($8810)
;             $0D -> CR + LF;  $0A -> ignored (VIC handles it)
;             Preserves: A, X, Y
; ------------------------------------------------------------
.proc uart_put
    cmp #$0A                ; ignore LF
    beq up_done
    pha
    cmp #$0D                ; CR -> send CR then LF
    bne up_char
up_cr_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_cr_wait
    lda #$0D
    sta UART_DATA
up_lf_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_lf_wait
    lda #$0A
    sta UART_DATA
    pla
    rts
up_char:
up_char_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_char_wait
    pla
    sta UART_DATA
up_done:
    rts
.endproc

; ============================================================
; STRING DATA
; ============================================================
.segment "RODATA"

cmd_basic_str: .byte "BASIC", 0
cmd_help_str:  .byte "HELP",  0
cmd_cls_str:   .byte "CLS",   0
cmd_dir_str:   .byte "DIR",   0

dir_header:
    .byte $0D, " DIRECTORY:", $0D, 0

dir_err_str:
    .byte " ?NO DISK MOUNTED", $0D, 0

lbl_prg:    .byte "PRG ", 0
lbl_other:  .byte "??? ", 0

welcome_str:
    .byte $0D
    .byte " ***  6502 SBC - 32K RAM SYSTEM  ***", $0D
    .byte " KERNEL V1.0", $0D
    .byte $0D
    .byte 0

prompt_str:
    .byte "> ", 0

help_str:
    .byte $0D
    .byte " AVAILABLE COMMANDS:", $0D
    .byte "   BASIC  -  START BASIC ROM", $0D
    .byte "   DIR    -  SHOW DISK FILES", $0D
    .byte "   CLS    -  CLEAR SCREEN", $0D
    .byte "   HELP   -  SHOW THIS HELP", $0D
    .byte $0D
    .byte 0

unknown_str:
    .byte " ?UNKNOWN COMMAND", $0D
    .byte 0

; ============================================================
; 6502 hardware vectors at $FFFA-$FFFF.  The kernel ROM owns them and
; points reset/IRQ/NMI at EhBASIC's fixed entry table ($A000/$A003/$A006).
; ============================================================
.segment "VECTORS"
    .word $A006             ; $FFFA NMI   -> EhBASIC ENTRY_TABLE+6
    .word $A000             ; $FFFC RESET -> EhBASIC ENTRY_TABLE+0
    .word $A003             ; $FFFE IRQ   -> EhBASIC ENTRY_TABLE+3
