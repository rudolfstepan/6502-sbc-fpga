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
; The D64 GoDrive (FAT16 root scan in software + D64 virtual disk) lives at $8824; see
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
;   VIC video RAM  $8000-$87FF  (80 x 25 = 2000 bytes in text80 mode)
;   VIA 6522       $8800-$880F
;   PS/2 keyboard  $8820-$8823  (status/key/modifier/ascii)
; ============================================================

COLS        = 80
ROWS        = 25

VIC_BASE    = $8000
VIA_ORA     = $8801
VIA_DDRA    = $8803
VIA_IFR     = $880D
VIA_IER     = $880E
CA1_BIT     = $02

KBD_STATUS  = $8820         ; bit 0 = key_ready
KBD_ASCII   = $8823         ; read clears key_ready
KBD_READY   = $01

; ── D64 GoDrive register map (d64_subsystem at DEV_DISK $8824) ──────────────
DISK_STATUS  = $8824        ; R  bit0 BUSY bit1 DONE bit2 ERROR bit3 MOUNTED
DISK_COMMAND = $8825        ; W
DISK_TRACK   = $8826        ; RW (1-based)
DISK_SECTOR  = $8827        ; RW (0-based)
DISK_RESULT  = $8828        ; R  DISK_RESULT code
DISK_DATA    = $8829        ; R  sector-buffer port (read auto-increments)
DISK_PTR_LO  = $882A        ; RW buffer pointer 0..255
DISK_RAW_LBA0 = $882C       ; W  raw LBA byte 0 (LSB)
DISK_RAW_LBA1 = $882D       ; W  raw LBA byte 1
DISK_RAW_LBA2 = $882E       ; W  raw LBA byte 2
DISK_RAW_LBA3 = $882F       ; W  raw LBA byte 3 (MSB)

DCMD_READ    = $01
DCMD_MOUNT   = $03
CMD_RAW_READ = $05          ; debug: read raw card LBA into the sector buffer
CMD_MOUNT_LBA = $07         ; mount the LBA written to $882C-$882F
STAT_BUSY    = $01
STAT_ERROR   = $04
STAT_MOUNTED = $08

VIC_GFX_MODE = $9000
VIC_CURSOR_X = $9001
VIC_CURSOR_Y = $9002
VIC_TEXT_ATTR = $9005
VIC_TEXT_80   = $02

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
EHBASIC_INPUT_MAX = $7E ; patched EhBASIC Ibuffs capacity, must stay < $80

; Screen editor replay buffer.  Used by FPGA keyboard cursor editing: when
; Enter is pressed after moving the hardware cursor, the full screen line
; is read (C64-style), trailing spaces trimmed, and replayed to BASIC one
; character per CHRIN call.  CHROUT suppresses echo while POS < LEN so the
; line is not duplicated on screen.
SCREEN_EDIT_ACTIVE = $02F0
SCREEN_REPLAY_POS  = $02F1
SCREEN_REPLAY_LEN  = $02F2
SCREEN_REPLAY_CHAR = $02F3
SCREEN_SAVED_X     = $02F4
SCREEN_SAVED_Y     = $02F5
SCREEN_RETURN_CHAR = $02F6
SCREEN_PENDING_CHAR = $02F7
SCREEN_PENDING_FLAG = $02F8
; Count of leading backspaces still to feed BASIC before a screen-edit replay,
; so BASIC's own input buffer (which collected the originally-typed chars) is
; emptied first and the corrected line replaces it instead of appending to it.
SCREEN_FLUSH        = $02F9

VIC_TEXT_COLOR = $9003          ; foreground color register (0-15)
VIC_BG_COLOR   = $9004          ; background color register (0-15)
VIC_COLOR_BASE = $8400          ; 40-column color RAM (not used by 80-column kernel)

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
    jmp DISK_ENUM       ; $F02D  enumerate .d64 files -> FAT_* tables
    jmp DISK_MOUNT_LBA  ; $F030  mount table entry A's LBA
    jmp DISK_MENU       ; $F033  interactive .d64 select menu (arrow keys)
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
    lda #$0E                ; light blue
    sta VIC_TEXT_COLOR
    lda #$00                ; black
    sta VIC_BG_COLOR
    lda #VIC_TEXT_80        ; 80x25 text, global text/background colours
    sta VIC_TEXT_ATTR
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

    cmp #$0D
    beq newline_cr
    cmp #$0A
    beq restore             ; ignore LF (0x0A) - only CR (0x0D) triggers newline
    cmp #$07
    beq restore             ; ignore BEL (EhBASIC buffer-full beep), don't draw glyph
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

    lda KBD_STATUS
    and #KBD_READY
    beq try_via
    lda KBD_ASCII
    beq nothing
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
    ; First drain any pending backspaces: these clear BASIC's input buffer so the
    ; replayed line replaces the originally-typed (and possibly edited) text.
    lda SCREEN_FLUSH
    beq no_flush
    dec SCREEN_FLUSH
    ldx #1
    stx SCREEN_REPLAY_CHAR
    lda #$08               ; [BACKSPACE]: BASIC decrements its buffer index
    sec
    rts
no_flush:
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
    ; Empty BASIC's input buffer first: feed it EHBASIC_INPUT_MAX backspaces (its max line
    ; length).  Excess backspaces past an empty buffer are ignored by BASIC, so
    ; whatever it had collected is cleared before the corrected line replays.
    lda #EHBASIC_INPUT_MAX
    sta SCREEN_FLUSH

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
    ; Fill the active 80x25 character area ($8000-$87CF) with spaces.
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    ldx #ROWS
char_row:
    lda #$20                ; space character
    ldy #0
char_col:
    sta (SCRPTR_LO),y
    iny
    cpy #COLS
    bne char_col
    clc
    lda SCRPTR_LO
    adc #COLS
    sta SCRPTR_LO
    bcc char_next
    inc SCRPTR_HI
char_next:
    dex
    bne char_row
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
    sta SCREEN_FLUSH
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

    ; Copy rows 1..24 to rows 0..23.  The pointer-based loop works for the
    ; 80-column kernel and avoids hard-coded 256-byte page chunks.
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    lda #<(VIC_BASE + COLS)
    sta STRPTR_LO
    lda #>(VIC_BASE + COLS)
    sta STRPTR_HI
    ldx #(ROWS-1)
copy_row:
    ldy #0
copy_col:
    lda (STRPTR_LO),y
    sta (SCRPTR_LO),y
    iny
    cpy #COLS
    bne copy_col

    clc
    lda SCRPTR_LO
    adc #COLS
    sta SCRPTR_LO
    bcc dst_ok
    inc SCRPTR_HI
dst_ok:
    clc
    lda STRPTR_LO
    adc #COLS
    sta STRPTR_LO
    bcc src_ok
    inc STRPTR_HI
src_ok:
    dex
    bne copy_row

    ; clear last character row
    lda #<(VIC_BASE + (ROWS-1)*COLS)
    sta SCRPTR_LO
    lda #>(VIC_BASE + (ROWS-1)*COLS)
    sta SCRPTR_HI
    lda #$20
    ldy #0
clr:
    sta (SCRPTR_LO),y
    iny
    cpy #COLS
    bne clr

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
; write_color_attr -- no-op in the default 80-column kernel.
;                     80x25 uses all 2 KiB text VRAM for character codes.
; ------------------------------------------------------------
.proc write_color_attr
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
    bne not_empty
    jmp done                ; empty input -> ignore
not_empty:

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
DK_MOUNTLBA0 = $0369    ; currently mounted D64 image start LBA mirror
DK_MOUNTLBA1 = $036A    ; ($882C-$882F are write-only on the hardware side)
DK_MOUNTLBA2 = $036B
DK_MOUNTLBA3 = $036C
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
; DISK_MOUNT -- ensure an image is mounted.  Idempotent: if a disk is already
; mounted (e.g. one picked in the DISKS menu), leave it as-is; otherwise scan
; the FAT16 root and mount the first .d64.  C=0 ok, C=1 fail.
; ------------------------------------------------------------
.proc DISK_MOUNT
    lda DISK_STATUS
    and #STAT_MOUNTED
    bne already            ; something already mounted -> keep the menu's choice
    jsr DISK_ENUM
    bcs fail
    lda FAT_CNT
    beq fail
    lda #0
    jsr DISK_MOUNT_LBA
    lda DISK_STATUS
    and #STAT_ERROR
    bne fail
    lda DISK_STATUS
    and #STAT_MOUNTED
    beq fail
already:
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
; disk_read_sector -- A=track, X=sector -> 256-byte buffer. C=0 ok, C=1 error.
;
; Use the raw SD LBA path instead of the D64 READ_SECTOR engine.  The raw path
; is already needed for FAT16 enumeration and has proven reliable on hardware;
; it also avoids a lower-half read failure seen when loading T18/S1 from a
; packed .d64 through the drive engine.
; ------------------------------------------------------------
.proc disk_read_sector
    sta F32B+3             ; requested track
    stx F32B+2             ; requested sector
    lda #0
    sta F32B+0             ; 16-bit D64 sector index
    sta F32B+1

    lda F32B+3
    cmp #1
    bcs :+
    jmp err
:
    cmp #18
    bcc trk_1_17
    cmp #25
    bcc trk_18_24
    cmp #31
    bcc trk_25_30
    cmp #36
    bcc trk_31_35
    jmp err

trk_1_17:
    lda F32B+2
    cmp #21
    bcc :+
    jmp err
:
    lda F32B+3
    sec
    sbc #1
    tax
    jsr idx_mul21
    jmp add_sector

trk_18_24:
    lda F32B+2
    cmp #19
    bcc :+
    jmp err
:
    lda #<357
    sta F32B+0
    lda #>357
    sta F32B+1
    lda F32B+3
    sec
    sbc #18
    tax
    jsr idx_mul19
    jmp add_sector

trk_25_30:
    lda F32B+2
    cmp #18
    bcc :+
    jmp err
:
    lda #<490
    sta F32B+0
    lda #>490
    sta F32B+1
    lda F32B+3
    sec
    sbc #25
    tax
    jsr idx_mul18
    jmp add_sector

trk_31_35:
    lda F32B+2
    cmp #17
    bcc :+
    jmp err
:
    lda #<598
    sta F32B+0
    lda #>598
    sta F32B+1
    lda F32B+3
    sec
    sbc #31
    tax
    jsr idx_mul17

add_sector:
    clc
    lda F32B+0
    adc F32B+2
    sta F32B+0
    lda F32B+1
    adc #0
    sta F32B+1

    lda F32B+0
    and #1
    sta F32B+2             ; half selector: 0=lower, 1=upper
    lsr F32B+1             ; index /= 2 -> SD LBA delta
    ror F32B+0

    clc
    lda DK_MOUNTLBA0
    adc F32B+0
    sta F32A+0
    lda DK_MOUNTLBA1
    adc F32B+1
    sta F32A+1
    lda DK_MOUNTLBA2
    adc #0
    sta F32A+2
    lda DK_MOUNTLBA3
    adc #0
    sta F32A+3

    lda F32B+2
    beq lower
    jsr raw_read_lba_hi
    jmp chk
lower:
    jsr raw_read_lba
chk:
    lda DISK_STATUS
    and #STAT_ERROR
    bne err
    clc
    rts
err:
    sec
    rts

idx_mul21:
    cpx #0
    beq mul_done
@lp:
    clc
    lda F32B+0
    adc #21
    sta F32B+0
    lda F32B+1
    adc #0
    sta F32B+1
    dex
    bne @lp
mul_done:
    rts

idx_mul19:
    cpx #0
    beq mul_done
@lp:
    clc
    lda F32B+0
    adc #19
    sta F32B+0
    lda F32B+1
    adc #0
    sta F32B+1
    dex
    bne @lp
    rts

idx_mul18:
    cpx #0
    beq mul_done
@lp:
    clc
    lda F32B+0
    adc #18
    sta F32B+0
    lda F32B+1
    adc #0
    sta F32B+1
    dex
    bne @lp
    rts

idx_mul17:
    cpx #0
    beq mul_done
@lp:
    clc
    lda F32B+0
    adc #17
    sta F32B+0
    lda F32B+1
    adc #0
    sta F32B+1
    dex
    bne @lp
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
    ldx #4                 ; 4-space indent (match the file lines below)
hindent:
    lda #' '
    jsr CHROUT
    dex
    bne hindent
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

; print_entry -- directory line:  ____"NAME" PRG
; The line starts with a 4-space indent (no leading block count) so the user can
; position the cursor at the start, type LOAD over the spaces, and press Enter:
; the line becomes  LOAD"NAME" PRG  which BASIC loads (the trailing type is
; ignored by the LOAD hook).
.proc print_entry
    ldx #4                 ; 4-space indent = room to type "LOAD"
indent:
    lda #' '
    jsr CHROUT
    dex
    bne indent
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

; ============================================================
; FAT16 directory enumeration of .d64 files (for the D64 select menu).
;
; The 6502 reads the FAT16 root directory via the raw-sector read ($05) and
; computes each .d64 file's start LBA.  It then mounts a chosen LBA via
; CMD_MOUNT_LBA.  Normal disk access stays D64-only after mounting.
;
; Tables (page 3): up to FAT_MAX entries, name (12 bytes: 11 + nul) + 4-byte LBA.
; ============================================================
FAT_MAX     = 20

.segment "BSS"
SCREEN_REPLAY_BUF: .res COLS + 1
FAT_RES:    .res 2          ; reserved sectors
FAT_NFATS:  .res 1          ; number of FATs
FAT_SPF:    .res 4          ; sectors per FAT (low 16 bits used for FAT16)
FAT_SPC:    .res 1          ; sectors per cluster
FAT_ROOT:   .res 4          ; FAT16 root directory LBA
FAT_RSECT:  .res 2          ; FAT16 root directory sectors
FAT_DSTART: .res 4          ; data_start LBA (root_lba + root sectors)
FAT_PLBA:   .res 4          ; partition start LBA (0 for superfloppy)
FAT_CNT:    .res 1          ; number of .d64 files found
FAT_NAMES:  .res 12 * FAT_MAX   ; 8.3 names, nul-terminated
FAT_LBAS:   .res 4 * FAT_MAX    ; start LBA per file
; 32-bit scratch for the math
F32A:       .res 4
F32B:       .res 4
FAT_RLEFT:  .res 2          ; root sectors left while scanning
FAT_TMP:    .res 1
FAT_EIDX:   .res 1          ; scan_half entry index (X is clobbered by append_file)

.segment "CODE"

; raw_read_lba -- raw-read the card LBA in F32A (32-bit) into the sector buffer
; (lower 256 bytes).  Uses CMD_RAW_READ; DISK_TRACK selects the half (0=lower).
.proc raw_read_lba
    lda #0
    sta DISK_TRACK         ; lower half
    lda F32A+0
    sta DISK_RAW_LBA0
    lda F32A+1
    sta DISK_RAW_LBA1
    lda F32A+2
    sta DISK_RAW_LBA2
    lda F32A+3
    sta DISK_RAW_LBA3
    lda #CMD_RAW_READ
    sta DISK_COMMAND
    jmp disk_wait
.endproc

; raw_read_lba_hi -- same but the upper 256 bytes (DISK_TRACK=1).
.proc raw_read_lba_hi
    lda #1
    sta DISK_TRACK
    lda F32A+0
    sta DISK_RAW_LBA0
    lda F32A+1
    sta DISK_RAW_LBA1
    lda F32A+2
    sta DISK_RAW_LBA2
    lda F32A+3
    sta DISK_RAW_LBA3
    lda #CMD_RAW_READ
    sta DISK_COMMAND
    jmp disk_wait
.endproc

; ------------------------------------------------------------
; DISK_ENUM -- enumerate .d64 files into FAT_NAMES/FAT_LBAS, FAT_CNT = count.
; Returns C=0 on success (FAT_CNT may be 0), C=1 on a read/format error.
; ------------------------------------------------------------
.proc DISK_ENUM
    lda #0
    sta FAT_CNT
    sta FAT_PLBA+0
    sta FAT_PLBA+1
    sta FAT_PLBA+2
    sta FAT_PLBA+3

    ; --- read LBA 0: MBR or BPB? ---
    lda #0
    sta F32A+0
    sta F32A+1
    sta F32A+2
    sta F32A+3
    jsr raw_read_lba
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; byte 0
    cmp #$EB
    beq is_bpb
    cmp #$E9
    beq is_bpb

    ; --- MBR: require boot signature and a FAT16 partition type. ---
    lda #0
    sta F32A+0
    sta F32A+1
    sta F32A+2
    sta F32A+3
    jsr raw_read_lba_hi
    lda #$FE               ; 510-256
    sta DISK_PTR_LO
    lda DISK_DATA
    cmp #$55
    beq :+
    jmp scan_fail
:
    lda DISK_DATA
    cmp #$AA
    beq :+
    jmp scan_fail
:
    lda #$C2               ; 446 + 4 - 256: partition type
    sta DISK_PTR_LO
    lda DISK_DATA
    cmp #$04               ; FAT16 <32M
    beq mbr_part
    cmp #$06               ; FAT16
    beq mbr_part
    cmp #$0E               ; FAT16 LBA
    beq mbr_part
    jmp scan_fail
mbr_part:
    lda #$C6               ; 446 + 8 - 256: partition start LBA
    sta DISK_PTR_LO
    lda DISK_DATA
    sta FAT_PLBA+0
    lda DISK_DATA
    sta FAT_PLBA+1
    lda DISK_DATA
    sta FAT_PLBA+2
    lda DISK_DATA
    sta FAT_PLBA+3
    ; re-read the BPB at the partition start
    lda FAT_PLBA+0
    sta F32A+0
    lda FAT_PLBA+1
    sta F32A+1
    lda FAT_PLBA+2
    sta F32A+2
    lda FAT_PLBA+3
    sta F32A+3
    jsr raw_read_lba
is_bpb:
    ; --- parse BPB fields from the current buffer (lower half of BPB sector) ---
    lda #11
    sta DISK_PTR_LO
    lda DISK_DATA          ; bytes per sector low, must be 512 ($0200)
    cmp #0
    beq :+
    jmp scan_fail
:
    lda DISK_DATA
    cmp #2
    beq :+
    jmp scan_fail
:
    lda #13
    sta DISK_PTR_LO
    lda DISK_DATA          ; +13 spc
    bne :+
    jmp scan_fail
:
    sta FAT_SPC
    lda DISK_DATA          ; +14 reserved lo
    sta FAT_RES+0
    lda DISK_DATA          ; +15 reserved hi
    sta FAT_RES+1
    lda DISK_DATA          ; +16 num fats
    bne :+
    jmp scan_fail
:
    sta FAT_NFATS
    lda DISK_DATA          ; +17 root entries lo
    sta FAT_RSECT+0
    lda DISK_DATA          ; +18 root entries hi
    sta FAT_RSECT+1
    ldx #4                 ; root sectors = root entries / 16
root_shift:
    lsr FAT_RSECT+1
    ror FAT_RSECT+0
    dex
    bne root_shift
    lda FAT_RSECT+0
    ora FAT_RSECT+1
    bne :+
    jmp scan_fail
:
    ; FAT16 sectors-per-FAT at +22..23
    lda #22
    sta DISK_PTR_LO
    lda DISK_DATA
    sta FAT_SPF+0
    lda DISK_DATA
    sta FAT_SPF+1
    lda #0
    sta FAT_SPF+2
    sta FAT_SPF+3

    ; --- derive root_lba and data_start ---
    jsr calc_data_start

    ; scan FAT16's fixed root directory, 16 entries per sector
    lda FAT_ROOT+0
    sta F32A+0
    lda FAT_ROOT+1
    sta F32A+1
    lda FAT_ROOT+2
    sta F32A+2
    lda FAT_ROOT+3
    sta F32A+3
    lda FAT_RSECT+0
    sta FAT_RLEFT+0
    lda FAT_RSECT+1
    sta FAT_RLEFT+1

scan_sector:
    lda FAT_RLEFT+0
    ora FAT_RLEFT+1
    beq done_ok
    jsr raw_read_lba
    jsr scan_half_lower
    bcs done_ok            ; end-of-dir marker hit
    jsr raw_read_lba_hi
    jsr scan_half_upper
    bcs done_ok
    inc F32A+0
    bne :+
    inc F32A+1
    bne :+
    inc F32A+2
    bne :+
    inc F32A+3
:
    lda FAT_RLEFT+0
    bne :+
    dec FAT_RLEFT+1
:
    dec FAT_RLEFT+0
    jmp scan_sector
done_ok:
    clc
    rts
scan_fail:
    sec
    rts
.endproc

; calc_data_start -- FAT_ROOT = PLBA + RES + NFATS*SPF,
;                    FAT_DSTART = FAT_ROOT + FAT_RSECT
.proc calc_data_start
    ; F32A = nfats * spf (nfats is small, 1 or 2; just add spf nfats times)
    lda #0
    sta F32A+0
    sta F32A+1
    sta F32A+2
    sta F32A+3
    ldx FAT_NFATS
    beq added
addloop:
    clc
    lda F32A+0
    adc FAT_SPF+0
    sta F32A+0
    lda F32A+1
    adc FAT_SPF+1
    sta F32A+1
    lda F32A+2
    adc FAT_SPF+2
    sta F32A+2
    lda F32A+3
    adc FAT_SPF+3
    sta F32A+3
    dex
    bne addloop
added:
    ; FAT_ROOT = FAT_PLBA + FAT_RES(16-bit) + F32A
    clc
    lda FAT_PLBA+0
    adc FAT_RES+0
    sta FAT_ROOT+0
    lda FAT_PLBA+1
    adc FAT_RES+1
    sta FAT_ROOT+1
    lda FAT_PLBA+2
    adc #0
    sta FAT_ROOT+2
    lda FAT_PLBA+3
    adc #0
    sta FAT_ROOT+3
    clc
    lda FAT_ROOT+0
    adc F32A+0
    sta FAT_ROOT+0
    lda FAT_ROOT+1
    adc F32A+1
    sta FAT_ROOT+1
    lda FAT_ROOT+2
    adc F32A+2
    sta FAT_ROOT+2
    lda FAT_ROOT+3
    adc F32A+3
    sta FAT_ROOT+3

    ; FAT_DSTART = FAT_ROOT + root directory sectors (16-bit)
    clc
    lda FAT_ROOT+0
    adc FAT_RSECT+0
    sta FAT_DSTART+0
    lda FAT_ROOT+1
    adc FAT_RSECT+1
    sta FAT_DSTART+1
    lda FAT_ROOT+2
    adc #0
    sta FAT_DSTART+2
    lda FAT_ROOT+3
    adc #0
    sta FAT_DSTART+3
    rts
.endproc

; mul_f32b_spc -- F32B <<= log2(spc)  (spc is a power of two: 1,2,4,...,128)
.proc mul_f32b_spc
    lda FAT_SPC
shift:
    cmp #2
    bcc done                ; spc==1 -> nothing to shift
    asl F32B+0
    rol F32B+1
    rol F32B+2
    rol F32B+3
    lsr                     ; halve the remaining factor
    jmp shift
done:
    rts
.endproc

; scan_half_lower -- scan the 8 dir entries in the lower-half buffer (entries
; 0..7 of the sector, at buffer offsets i*32). Collect .d64 matches. C=1 if a
; $00 end-of-dir entry is seen.
; (CMD_RAW_READ fills raw_buf[0..255] with card bytes 0..255 of the LBA, with no
; offset, so FAT16 32-byte entries start at buffer offset 0.)
.proc scan_half_lower
    lda #0
    sta FAT_EIDX            ; entry index 0..7 (eval_entry->append_file clobbers X)
next:
    lda FAT_EIDX
    asl
    asl
    asl
    asl
    asl                     ; i*32
    sta DISK_PTR_LO
    jsr eval_entry
    bcs end_dir
    inc FAT_EIDX
    lda FAT_EIDX
    cmp #8
    bcc next
    clc                     ; not end; more entries possible in upper half
    rts
end_dir:
    sec
    rts
.endproc

; scan_half_upper -- entries 8..15 in the upper-half buffer (same offsets i*32;
; the buffer holds card bytes 256..511 of the LBA after a DISK_TRACK=1 raw read).
.proc scan_half_upper
    lda #0
    sta FAT_EIDX
next:
    lda FAT_EIDX
    asl
    asl
    asl
    asl
    asl
    sta DISK_PTR_LO
    jsr eval_entry
    bcs end_dir
    inc FAT_EIDX
    lda FAT_EIDX
    cmp #8
    bcc next
    clc
    rts
end_dir:
    sec
    rts
.endproc

; eval_entry -- examine the 32-byte dir entry at DISK_PTR_LO.
;   C=1 -> end-of-directory ($00 type) ; C=0 -> continue.
; If it is a non-deleted, non-LFN file whose extension is "D64", append it.
.proc eval_entry
    ; read the 32 bytes into DK_ENTRY (reuse the directory-entry buffer)
    ldy #0
copy:
    lda DISK_DATA
    sta DK_ENTRY,y
    iny
    cpy #32
    bne copy
    lda DK_ENTRY+0
    beq is_end             ; $00 -> end of directory
    cmp #$E5
    beq cont               ; deleted
    lda DK_ENTRY+11        ; attr
    and #$18
    bne cont               ; LFN/volume label/directory
    ; extension at bytes 8,9,10 must be "D64"
    lda DK_ENTRY+8
    cmp #'D'
    bne cont
    lda DK_ENTRY+9
    cmp #'6'
    bne cont
    lda DK_ENTRY+10
    cmp #'4'
    bne cont
    jsr append_file
cont:
    clc
    rts
is_end:
    sec
    rts
.endproc

; append_file -- add DK_ENTRY (a .d64 dir entry) to the tables, if room.
;   name = 8.3 from DK_ENTRY[0..10]; LBA = data_start + (first_clus-2)*spc.
.proc append_file
    lda FAT_CNT
    cmp #FAT_MAX
    bcc has_room           ; room available -> append
    rts                    ; table full -> ignore extra files
has_room:
    ; name index = cnt*12  ; lba index = cnt*4
    ; copy 11 name bytes + nul
    ldx FAT_CNT
    ; compute name dest = FAT_NAMES + cnt*12
    lda #0
    sta FAT_TMP            ; high of offset
    txa
    asl                    ; *2
    sta F32B+0
    txa
    asl
    asl                    ; *4 (low only; cnt<=20 so *12 < 256)
    clc
    adc F32B+0             ; *4 + *2 = *6 ... need *12
    asl                    ; *12
    tay                    ; Y = cnt*12 (fits: 20*12=240)
    ldx #0
ncopy:
    lda DK_ENTRY,x         ; bytes 0..10 are the 8.3 name
    sta FAT_NAMES,y
    iny
    inx
    cpx #11
    bne ncopy
    lda #0
    sta FAT_NAMES,y        ; nul-terminate

    ; FAT16 first_cluster = DK_ENTRY[26..27]
    lda DK_ENTRY+26
    sta F32B+0
    lda DK_ENTRY+27
    sta F32B+1
    lda #0
    sta F32B+2
    sta F32B+3
    ; F32B -= 2
    sec
    lda F32B+0
    sbc #2
    sta F32B+0
    lda F32B+1
    sbc #0
    sta F32B+1
    lda F32B+2
    sbc #0
    sta F32B+2
    lda F32B+3
    sbc #0
    sta F32B+3
    jsr mul_f32b_spc       ; F32B = (first_clus-2)*spc
    ; file_lba = data_start + F32B  -> store in FAT_LBAS[cnt]
    ; lba index = cnt*4
    lda FAT_CNT
    asl
    asl
    tay                    ; Y = cnt*4
    clc
    lda FAT_DSTART+0
    adc F32B+0
    sta FAT_LBAS,y
    lda FAT_DSTART+1
    adc F32B+1
    sta FAT_LBAS+1,y
    lda FAT_DSTART+2
    adc F32B+2
    sta FAT_LBAS+2,y
    lda FAT_DSTART+3
    adc F32B+3
    sta FAT_LBAS+3,y
    inc FAT_CNT
    rts
.endproc

; ------------------------------------------------------------
; DISK_MOUNT_LBA -- mount the LBA for table entry A (0-based).
;   Writes FAT_LBAS[A] to $882C-$882F and issues CMD_MOUNT_LBA.
; ------------------------------------------------------------
.proc DISK_MOUNT_LBA
    asl
    asl
    tay                    ; Y = index*4
    lda FAT_LBAS,y
    sta DISK_RAW_LBA0
    sta DK_MOUNTLBA0
    lda FAT_LBAS+1,y
    sta DISK_RAW_LBA1
    sta DK_MOUNTLBA1
    lda FAT_LBAS+2,y
    sta DISK_RAW_LBA2
    sta DK_MOUNTLBA2
    lda FAT_LBAS+3,y
    sta DISK_RAW_LBA3
    sta DK_MOUNTLBA3
    lda #CMD_MOUNT_LBA
    sta DISK_COMMAND
    jmp disk_wait
.endproc

; ------------------------------------------------------------
; DISK_MENU -- interactive .d64 selection menu.
;   Enumerates the .d64 files, lists them, lets the user move the highlight with
;   the up/down cursor keys and pick one with Enter, then mounts it.
;   Returns C=0 if a file was mounted, C=1 if cancelled / none / error.
; Cursor key codes (from the kernel keyboard layer): $11 down, $91 up, $0D enter,
;   $1B / $03 cancel.
; ------------------------------------------------------------
MENU_SEL = FAT_TMP          ; reuse: current highlighted index
.proc DISK_MENU
    jsr DISK_ENUM
    lda FAT_CNT
    bne have
    ; none found
    jsr CLRSCR
    ldx #<menu_none
    ldy #>menu_none
    jsr STROUT
    sec
    rts
have:
    lda #0
    sta MENU_SEL
redraw:
    jsr draw_menu
keyloop:
    jsr menu_getkey       ; raw key (bypasses the screen-editor cursor handling)
    cmp #$0D
    beq choose
    cmp #$11              ; cursor down
    beq go_down
    cmp #$91             ; cursor up
    beq go_up
    cmp #$1B
    beq cancel
    cmp #$03
    beq cancel
    jmp keyloop
go_down:
    lda MENU_SEL
    clc
    adc #1
    cmp FAT_CNT
    bcc set_sel
    lda #0                ; wrap to top
set_sel:
    sta MENU_SEL
    jmp redraw
go_up:
    lda MENU_SEL
    bne dec_sel
    lda FAT_CNT          ; wrap to bottom
dec_sel:
    sec
    sbc #1
    sta MENU_SEL
    jmp redraw
choose:
    lda MENU_SEL
    jsr DISK_MOUNT_LBA
    jsr CLRSCR
    ldx #<menu_mounted
    ldy #>menu_mounted
    jsr STROUT
    clc
    rts
cancel:
    sec
    rts
.endproc

; menu_getkey -- blocking raw key read for the menu.  Unlike CHRIN, this does
; NOT run handle_screen_key, so the cursor keys ($11/$91) arrive as raw codes
; instead of being consumed to move the on-screen editor cursor.  Returns the
; raw byte in A.
.proc menu_getkey
loop:
    lda KBD_STATUS          ; PS/2 keyboard ASCII register
    and #KBD_READY
    beq try_via
    lda KBD_ASCII           ; read byte (clears key_ready)
    bne got_key
try_via:
    lda VIA_IFR             ; optional keyboard via VIA CA1
    and #CA1_BIT
    beq loop
    lda VIA_ORA             ; read byte (clears the CA1 flag)
got_key:
    rts
.endproc

; draw_menu -- clear screen, print header + the file list with a '>' marker on
; the highlighted entry.
.proc draw_menu
    jsr CLRSCR
    ldx #<menu_hdr
    ldy #>menu_hdr
    jsr STROUT
    lda #0
    sta DK_TMP            ; row index
row:
    lda DK_TMP
    cmp FAT_CNT
    bcs done
    ; marker: '>' if row==MENU_SEL else ' '
    lda #' '
    sta DK_DIG           ; scratch
    lda DK_TMP
    cmp MENU_SEL
    bne nomark
    lda #'>'
    sta DK_DIG
nomark:
    lda DK_DIG
    jsr CHROUT
    lda #' '
    jsr CHROUT
    ; print the name at FAT_NAMES + row*12 (nul-terminated)
    ; Y = row*12
    lda DK_TMP
    asl
    sta F32B+0           ; *2
    lda DK_TMP
    asl
    asl
    clc
    adc F32B+0           ; *6
    asl                  ; *12
    tay
pname:
    lda FAT_NAMES,y
    beq pend
    jsr CHROUT           ; print the 8.3 name char (padding spaces included)
    iny
    jmp pname
pend:
    lda #$0D
    jsr CHROUT
    inc DK_TMP
    jmp row
done:
    lda #$0D
    jsr CHROUT
    ldx #<menu_foot
    ldy #>menu_foot
    jmp STROUT
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

menu_hdr:    .byte $0D, " SELECT A .D64 DISK:", $0D, $0D, 0
menu_foot:   .byte $0D, " UP/DOWN = MOVE  RETURN = MOUNT", $0D, 0
menu_none:   .byte $0D, " NO .D64 FILES FOUND", $0D, 0
menu_mounted:.byte $0D, " MOUNTED.", $0D, 0

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
