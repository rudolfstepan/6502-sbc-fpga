; ============================================================
; CRYPT OF THE 6502 -- a text adventure for the Tang Primer 20K SBC.
;
; Standalone, self-contained ROM: writes the VIC text screen ($8000 chars /
; $8400 colour) directly and reads the PS/2 keyboard ($8820/$8823).  Built as a
; 16 KB split-ROM image ($A000-$CFFF code, $F000-$FFFF padding + vectors) and
; uploaded with upload_monitor_hex --split-rom.
;
; Layout (40x25 text mode, Scott-Adams style): the top 11 rows are a per-room
; PETSCII picture drawn from solid-block ($7F) colour cells, the bottom rows are
; the text (room name, description, items, exits, status, command line).  Colours
; are foreground-only (solid $7F blocks), so it runs on the stock bitstream.
;
; Build:  make adventure-rom        Upload: roms/upload/adventure.bat
; ============================================================

; ---- hardware ----
SCREEN      = $8000
COLOR       = $8400
COLS        = 40
ROWS        = 25
VIC_MODE    = $9000
VIC_TEXT_ATTR = $9005
VICII_BORDER = $D020
VICII_BG    = $D021
KBD_STATUS  = $8820
KBD_ASCII   = $8823

; ---- audio: SID at $D400, note length timed off the $883A ms counter ----
MS_TIMER    = $883A
SID_FREQ_LO = $D400
SID_FREQ_HI = $D401
SID_PW_LO   = $D402
SID_PW_HI   = $D403
SID_CTRL    = $D404          ; bit4 tri/bit5 saw/bit6 pulse/bit7 noise + bit0 gate
SID_AD      = $D405
SID_SR      = $D406
SID_VOL     = $D418

; ---- glyphs ----
SOLID       = $7F            ; full block (a solid colour cell)
VBAR        = $61            ; vertical bar
HATCH       = $6E            ; texture
HLINE       = $60
SPACE       = $20

; ---- 16-colour palette indices ----
BLACK=0
WHITE=1
RED=2
CYAN=3
PURPLE=4
GREEN=5
BLUE=6
YELLOW=7
ORANGE=8
BROWN=9
LRED=10
DGRAY=11
GRAY=12
LGREEN=13
LBLUE=14
LGRAY=15

; ---- semantic text colours ----
COL_ROOM    = LGREEN
COL_DESC    = LGRAY
COL_ITEM    = CYAN
COL_EXIT    = LBLUE
COL_PROMPT  = YELLOW
COL_MSG     = LRED
COL_GOOD    = GREEN
COL_INPUT   = WHITE
COL_FRAME   = BROWN
COL_TITLE   = YELLOW

; ---- layout ----
PICH        = 11             ; picture rows 0..10
TROW_DIV    = 11
TROW_NAME   = 13
TROW_DESC   = 14
TROW_GUARD  = 15
TROW_ITEMS  = 16
TROW_EXITS  = 17
TROW_MSG    = 20
TROW_INPUT  = 22

; ---- zero page ----
scr         = $02
col         = $04
curx        = $06
cury        = $07
ccolor      = $08
tmpch       = $09
strp        = $0A
tmp1        = $10
tmp2        = $11
nr          = $12
room        = $13
guard       = $14
inv         = $15
scene_ch    = $16
RITEMS      = $18            ; ritems[1..8] -> $19..$20
snd_lo      = $21
snd_hi      = $22
snd_dur     = $23
snd_w0      = $24
snd_w1      = $25
snd_t0      = $26
snd_wave    = $27

INBUF       = $0200
IBMAX       = 16

; ============================================================
.macro SETSTR s
    lda #<s
    sta strp
    lda #>s
    sta strp+1
.endmacro

.macro POS cc, rr
    ldx #cc
    lda #rr
    jsr setcur
.endmacro

.macro MSG c, s
    lda #TROW_MSG
    jsr clear_row
    lda #c
    sta ccolor
    POS 1, TROW_MSG
    SETSTR s
    jsr prints
.endmacro

; error message + buzz
.macro ERRMSG s
    MSG COL_MSG, s
    jsr sfx_error
.endmacro

.macro CHECK kw, handler
    SETSTR kw
    jsr streq
    bne :+
    jsr handler
    rts
:
.endmacro

.macro CHKIT kw, bit, target
    SETSTR kw
    jsr streq
    bne :+
    lda #bit
    jmp target
:
.endmacro

; ============================================================
.segment "CODE"

start:
    sei
    cld
    ldx #$FF
    txs
    lda #$00
    sta VIC_MODE
    sta VIC_TEXT_ATTR
    sta VICII_BG
    lda #COL_FRAME
    sta VICII_BORDER

    jsr sid_init
    jsr init_game
    jsr draw_intro
mloop:
    jsr describe_room
    lda #TROW_INPUT
    jsr clear_row
    lda #COL_PROMPT
    sta ccolor
    POS 1, TROW_INPUT
    SETSTR txt_cmd
    jsr prints
    lda #COL_INPUT
    sta ccolor
    jsr read_line
    jsr dispatch
    jmp mloop

; ------------------------------------------------------------
init_game:
    lda #1
    sta room
    lda #0
    sta guard
    sta inv
    ldx #8
@ci:
    lda ritems_init-1,x
    sta RITEMS,x
    dex
    bne @ci
    rts

; ------------------------------------------------------------
dispatch:
    jsr clear_msg
    CHECK kw_n,     cmd_north
    CHECK kw_s,     cmd_south
    CHECK kw_e,     cmd_east
    CHECK kw_w,     cmd_west
    CHECK kw_take,  cmd_take
    CHECK kw_drop,  cmd_drop
    CHECK kw_inv,   cmd_inv
    CHECK kw_look,  cmd_look
    CHECK kw_fight, cmd_fight
    CHECK kw_help,  cmd_help
    CHECK kw_quit,  cmd_quit
    ERRMSG msg_unknown
    rts

exit_of:
    pha
    lda room
    sec
    sbc #1
    asl a
    asl a
    sta tmp1
    pla
    sec
    sbc #1
    clc
    adc tmp1
    tax
    lda exits,x
    rts

cmd_north:
    lda #1
    jsr exit_of
    cmp #0
    bne @go
    ERRMSG msg_noexit_n
    rts
@go:
    sta room
    jsr sfx_step
    rts

cmd_south:
    lda #2
    jsr exit_of
    cmp #0
    bne @go
    ERRMSG msg_noexit_s
    rts
@go:
    sta room
    jsr sfx_step
    rts

cmd_west:
    lda #4
    jsr exit_of
    cmp #0
    bne @go
    ERRMSG msg_noexit_w
    rts
@go:
    sta room
    jsr sfx_step
    rts

cmd_east:
    lda #3
    jsr exit_of
    sta nr
    lda nr
    bne @e1
    ERRMSG msg_noexit_e
    rts
@e1:
    lda room
    cmp #6
    bne @move
    lda guard
    bne @vault
    ERRMSG msg_guard_blocks
    rts
@vault:
    lda nr
    cmp #7
    bne @move
    lda inv
    and #2
    bne @vkey
    ERRMSG msg_vault_locked
    rts
@vkey:
    lda inv
    and #$FD
    sta inv
    MSG COL_GOOD, msg_door_opens
    jsr sfx_door
@move:
    lda nr
    sta room
    cmp #8
    beq @towin
    jsr sfx_step
    rts
@towin:
    jsr try_win
    rts

try_win:
    lda inv
    and #8
    bne @win
    ERRMSG msg_nochip
    lda #7
    sta room
    rts
@win:
    jmp show_win

; ------------------------------------------------------------
cmd_take:
    MSG COL_PROMPT, txt_take_what
    jsr ask_item
    CHKIT kw_book,  1, do_take
    CHKIT kw_key,   2, do_take
    CHKIT kw_sword, 4, do_take
    CHKIT kw_chip,  8, do_take
    ERRMSG msg_not_here
    rts

do_take:
    sta tmp2
    ldx room
    lda RITEMS,x
    and tmp2
    beq @no
    lda RITEMS,x
    eor tmp2
    sta RITEMS,x
    lda inv
    ora tmp2
    sta inv
    MSG COL_GOOD, msg_taken
    jsr sfx_pickup
    rts
@no:
    ERRMSG msg_not_here
    rts

cmd_drop:
    MSG COL_PROMPT, txt_drop_what
    jsr ask_item
    CHKIT kw_book,  1, do_drop
    CHKIT kw_key,   2, do_drop
    CHKIT kw_sword, 4, do_drop
    CHKIT kw_chip,  8, do_drop
    ERRMSG msg_donthave
    rts

do_drop:
    sta tmp2
    lda inv
    and tmp2
    beq @no
    lda inv
    eor tmp2
    sta inv
    ldx room
    lda RITEMS,x
    ora tmp2
    sta RITEMS,x
    MSG COL_GOOD, msg_dropped
    jsr sfx_drop
    rts
@no:
    ERRMSG msg_donthave
    rts

ask_item:
    lda #TROW_INPUT
    jsr clear_row
    lda #COL_PROMPT
    sta ccolor
    POS 1, TROW_INPUT
    SETSTR txt_item
    jsr prints
    lda #COL_INPUT
    sta ccolor
    jmp read_line

cmd_inv:
    lda #TROW_MSG
    jsr clear_row
    lda #COL_ITEM
    sta ccolor
    POS 1, TROW_MSG
    SETSTR txt_carrying
    jsr prints
    lda inv
    bne @list
    SETSTR txt_nothing
    jsr prints
    rts
@list:
    sta tmp1
    ldx #0
@l:
    lda item_bits,x
    and tmp1
    beq @n
    lda #' '
    jsr putc
    lda item_name_lo,x
    sta strp
    lda item_name_hi,x
    sta strp+1
    jsr prints
@n:
    inx
    cpx #4
    bne @l
    rts

cmd_look:
    rts

cmd_fight:
    lda room
    cmp #6
    beq @here
    ERRMSG msg_no_enemy
    rts
@here:
    lda guard
    beq @notdead
    ERRMSG msg_already
    rts
@notdead:
    lda inv
    and #4
    bne @ok
    ERRMSG msg_need_sword
    rts
@ok:
    lda #1
    sta guard
    MSG COL_GOOD, msg_fight2
    jsr sfx_fight
    rts

cmd_help:
    MSG COL_DESC, msg_help
    rts

cmd_quit:
    MSG COL_TITLE, msg_farewell
halt:
    jmp halt

; ------------------------------------------------------------
; describe_room: draw the room picture (top) then the text (bottom).
describe_room:
    lda #BLACK
    sta ccolor
    jsr cls
    lda room
    jsr draw_scene
    ; divider line under the picture
    lda #COL_FRAME
    sta ccolor
    ldx #0
    lda #TROW_DIV
    jsr setcur
    ldx #COLS
@dv:
    lda #HLINE
    jsr putc
    dex
    bne @dv
    ; room name
    lda #COL_ROOM
    sta ccolor
    POS 1, TROW_NAME
    SETSTR txt_eq
    jsr prints
    ldx room
    lda rn_lo-1,x
    sta strp
    lda rn_hi-1,x
    sta strp+1
    jsr prints
    SETSTR txt_eq2
    jsr prints
    ; description
    lda #COL_DESC
    sta ccolor
    POS 1, TROW_DESC
    ldx room
    lda rd_lo-1,x
    sta strp
    lda rd_hi-1,x
    sta strp+1
    jsr prints
    ; guard line
    lda room
    cmp #6
    bne @items
    POS 1, TROW_GUARD
    lda guard
    bne @gdead
    lda #COL_MSG
    sta ccolor
    SETSTR msg_guard_here
    jsr prints
    jmp @items
@gdead:
    lda #COL_DESC
    sta ccolor
    SETSTR msg_guard_dead
    jsr prints
@items:
    ldx room
    lda RITEMS,x
    beq @exits
    sta tmp1
    lda #COL_ITEM
    sta ccolor
    POS 1, TROW_ITEMS
    SETSTR txt_yousee
    jsr prints
    ldx #0
@il:
    lda item_bits,x
    and tmp1
    beq @in
    txa
    pha
    lda #' '
    jsr putc
    pla
    tax
    lda item_name_lo,x
    sta strp
    lda item_name_hi,x
    sta strp+1
    jsr prints
@in:
    inx
    cpx #4
    bne @il
@exits:
    lda #COL_EXIT
    sta ccolor
    POS 1, TROW_EXITS
    SETSTR txt_exits
    jsr prints
    lda #1
    jsr show_exit
    lda #2
    jsr show_exit
    lda #3
    jsr show_exit
    lda #4
    jsr show_exit
    rts

show_exit:
    pha
    jsr exit_of
    cmp #0
    beq @none
    lda #' '
    jsr putc
    pla
    tax
    lda dir_letters-1,x
    jsr putc
    rts
@none:
    pla
    rts

; ------------------------------------------------------------
show_win:
    lda #YELLOW
    sta ccolor
    jsr cls
    lda #8
    jsr draw_scene           ; the daylight/forest picture
    lda #COL_TITLE
    sta ccolor
    POS 11, TROW_NAME
    SETSTR win1
    jsr prints
    lda #COL_GOOD
    sta ccolor
    POS 2, TROW_DESC+1
    SETSTR win2
    jsr prints
    lda #COL_TITLE
    sta ccolor
    POS 11, TROW_DESC+3
    SETSTR win3
    jsr prints
    jsr win_theme
win_halt:
    jmp win_halt

; ------------------------------------------------------------
; draw_intro: a title picture (the forest) with the title + story, wait RETURN.
draw_intro:
    lda #BLACK
    sta ccolor
    jsr cls
    lda #8
    jsr draw_scene
    lda #COL_FRAME
    sta ccolor
    ldx #0
    lda #TROW_DIV
    jsr setcur
    ldx #COLS
@dv:
    lda #HLINE
    jsr putc
    dex
    bne @dv
    lda #COL_TITLE
    sta ccolor
    POS 11, 13
    SETSTR txt_title2
    jsr prints
    lda #COL_DESC
    sta ccolor
    POS 1, 15
    SETSTR story1
    jsr prints
    POS 1, 16
    SETSTR story2
    jsr prints
    lda #COL_PROMPT
    sta ccolor
    POS 1, 19
    SETSTR txt_press
    jsr prints
    jsr intro_theme
    jsr read_line
    rts

; ============================================================
; scene engine: RLE picture into rows 0..PICH-1.
;   data = per row: runs of (count, char, colour) terminated by count=0.
; ============================================================
draw_scene:                  ; A = room (1..8)
    tax
    lda scene_lo-1,x
    sta strp
    lda scene_hi-1,x
    sta strp+1
    lda #0
    sta tmp2                 ; row
@row:
    ldx #0
    lda tmp2
    jsr setcur
@run:
    ldy #0
    lda (strp),y
    beq @rowend
    sta tmp1                 ; count
    ldy #1
    lda (strp),y
    sta scene_ch
    ldy #2
    lda (strp),y
    sta ccolor
    clc                      ; strp += 3
    lda strp
    adc #3
    sta strp
    lda strp+1
    adc #0
    sta strp+1
@emit:
    lda scene_ch
    jsr putc
    dec tmp1
    bne @emit
    jmp @run
@rowend:
    clc                      ; skip the count=0 terminator
    lda strp
    adc #1
    sta strp
    lda strp+1
    adc #0
    sta strp+1
    inc tmp2
    lda tmp2
    cmp #PICH
    bne @row
    rts

; ============================================================
; text engine
; ============================================================
cls:
    lda #$20
    ldx #0
@s:
    sta SCREEN,x
    sta SCREEN+$100,x
    sta SCREEN+$200,x
    sta SCREEN+$300,x
    inx
    bne @s
    lda ccolor
    ldx #0
@c:
    sta COLOR,x
    sta COLOR+$100,x
    sta COLOR+$200,x
    sta COLOR+$300,x
    inx
    bne @c
    lda #0
    sta curx
    sta cury
    rts

setcur:
    sta cury
    stx curx
    rts

clear_row:                   ; A = row; blank the whole row
    ldx #0
    jsr setcur
    ldx #COLS
@c:
    lda #$20
    jsr putc
    dex
    bne @c
    rts

clear_msg:
    lda #TROW_MSG
    jmp clear_row

calc_ptr:
    ldx cury
    clc
    lda rowoff_lo,x
    adc curx
    sta scr
    sta col
    lda rowoff_hi,x
    adc #0
    ora #$80
    sta scr+1
    clc
    adc #$04
    sta col+1
    rts

putc:
    sta tmpch
    txa
    pha
    tya
    pha
    lda tmpch
    cmp #$0D
    beq @nl
    jsr calc_ptr
    ldy #0
    lda tmpch
    sta (scr),y
    lda ccolor
    sta (col),y
    inc curx
    lda curx
    cmp #COLS
    bcc @done
@nl:
    lda #0
    sta curx
    inc cury
    lda cury
    cmp #ROWS
    bcc @done
    lda #ROWS-1
    sta cury
@done:
    pla
    tay
    pla
    tax
    rts

prints:
    ldy #0
@l:
    lda (strp),y
    beq @done
    jsr putc
    iny
    bne @l
@done:
    rts

read_line:
    ldx #0
@k:
    jsr getkey
    cmp #$0D
    beq @enter
    cmp #$08
    beq @bs
    cmp #$7F
    beq @bs
    cmp #$20
    bcc @k
    cpx #IBMAX
    bcs @k
    cmp #'a'
    bcc @store
    cmp #'z'+1
    bcs @store
    and #$DF
@store:
    sta INBUF,x
    inx
    jsr putc
    jmp @k
@bs:
    cpx #0
    beq @k
    dex
    lda curx
    beq @k
    dec curx
    jsr calc_ptr
    ldy #0
    lda #$20
    sta (scr),y
    jmp @k
@enter:
    lda #0
    sta INBUF,x
    rts

getkey:
    lda KBD_STATUS
    and #$01
    beq getkey
    lda KBD_ASCII
    rts

streq:
    ldy #0
@l:
    lda (strp),y
    cmp INBUF,y
    bne @ne
    lda (strp),y
    beq @eq
    iny
    bne @l
@eq:
    lda #0
    rts
@ne:
    lda #1
    rts

irq_handler:
    rti

; ============================================================
; SID sound: effects + short melodies, timed off the $883A ms counter.
; A note's frequency is given in Hz; the SID phase increment is freq*17
; (16777216/985248 = 17.03 at the PAL phi2 rate), computed inline.
; ============================================================
sid_init:
    lda #$0F
    sta SID_VOL              ; master volume, filter off
    lda #$00
    sta SID_AD               ; attack 0, decay 0
    lda #$F0
    sta SID_SR               ; sustain 15, release 0
    lda #$00
    sta SID_PW_LO
    lda #$08
    sta SID_PW_HI            ; 50% pulse width
    rts

; sid_tone: A=freq lo, X=freq hi, Y=duration ms; waveform in snd_wave (gate set)
sid_tone:
    sta snd_lo
    stx snd_hi
    sty snd_dur
    lda snd_lo
    sta snd_w0
    lda snd_hi
    sta snd_w1
    ldx #4
@shl:
    asl snd_w0
    rol snd_w1
    dex
    bne @shl
    clc                      ; w = freq*16 + freq = freq*17
    lda snd_w0
    adc snd_lo
    sta SID_FREQ_LO
    lda snd_w1
    adc snd_hi
    sta SID_FREQ_HI
    lda snd_wave
    sta SID_CTRL             ; waveform + gate on
    jsr sdelay
    lda snd_wave
    and #$FE
    sta SID_CTRL             ; gate off -> release
    rts

sdelay:                      ; wait snd_dur ms
    lda MS_TIMER
    sta snd_t0
@w:
    lda MS_TIMER
    sec
    sbc snd_t0
    cmp snd_dur
    bcc @w
    rts

; play_melody: strp -> (lo,hi,dur) triples, dur=0 ends. snd_wave preset.
play_melody:
@m:
    ldy #2
    lda (strp),y
    beq @done
    sta snd_dur
    ldy #1
    lda (strp),y
    tax
    ldy #0
    lda (strp),y
    ldy snd_dur
    jsr sid_tone
    lda #8                   ; short gap between notes
    sta snd_dur
    jsr sdelay
    clc
    lda strp
    adc #3
    sta strp
    lda strp+1
    adc #0
    sta strp+1
    jmp @m
@done:
    rts

sfx_step:
    lda #$11
    sta snd_wave
    lda #200
    ldx #0
    ldy #25
    jmp sid_tone

sfx_pickup:
    lda #$11
    sta snd_wave
    lda #<660
    ldx #>660
    ldy #60
    jsr sid_tone
    lda #<990
    ldx #>990
    ldy #80
    jmp sid_tone

sfx_drop:
    lda #$11
    sta snd_wave
    lda #<440
    ldx #>440
    ldy #60
    jsr sid_tone
    lda #<330
    ldx #>330
    ldy #80
    jmp sid_tone

sfx_error:
    lda #$21                 ; sawtooth = harsher buzz
    sta snd_wave
    lda #140
    ldx #0
    ldy #150
    jmp sid_tone

sfx_fight:
    lda #$81                 ; noise = clash
    sta snd_wave
    lda #<300
    ldx #>300
    ldy #180
    jmp sid_tone

sfx_door:
    lda #$21
    sta snd_wave
    lda #<300
    ldx #>300
    ldy #50
    jsr sid_tone
    lda #240
    ldx #0
    ldy #50
    jsr sid_tone
    lda #180
    ldx #0
    ldy #90
    jmp sid_tone

intro_theme:
    lda #$11
    sta snd_wave
    SETSTR mel_intro
    jmp play_melody

win_theme:
    lda #$11
    sta snd_wave
    SETSTR mel_win
    jmp play_melody

; ============================================================
.segment "RODATA"

rowoff_lo:
    .repeat 25, I
    .byte <(I*40)
    .endrepeat
rowoff_hi:
    .repeat 25, I
    .byte >(I*40)
    .endrepeat

exits:
    .byte 0,0,2,0
    .byte 3,5,6,1
    .byte 0,2,0,0
    .byte 0,0,0,5
    .byte 2,0,4,0
    .byte 5,0,7,2
    .byte 0,6,8,0
    .byte 0,7,0,0

ritems_init:
    .byte 0,0,3,0,4,0,8,0

item_bits:
    .byte 1,2,4,8
item_name_lo:
    .byte <n_book, <n_key, <n_sword, <n_chip
item_name_hi:
    .byte >n_book, >n_key, >n_sword, >n_chip
n_book:  .byte "BOOK",0
n_key:   .byte "KEY",0
n_sword: .byte "SWORD",0
n_chip:  .byte "CHIP",0

dir_letters:
    .byte 'N','S','E','W'

rn_lo:
    .byte <rn1,<rn2,<rn3,<rn4,<rn5,<rn6,<rn7,<rn8
rn_hi:
    .byte >rn1,>rn2,>rn3,>rn4,>rn5,>rn6,>rn7,>rn8
rn1: .byte "CELL",0
rn2: .byte "CORRIDOR",0
rn3: .byte "LIBRARY",0
rn4: .byte "LAB",0
rn5: .byte "ARMORY",0
rn6: .byte "GUARD ROOM",0
rn7: .byte "VAULT",0
rn8: .byte "EXIT",0

rd_lo:
    .byte <rd1,<rd2,<rd3,<rd4,<rd5,<rd6,<rd7,<rd8
rd_hi:
    .byte >rd1,>rd2,>rd3,>rd4,>rd5,>rd6,>rd7,>rd8
rd1: .byte "YOU AWAKE IN A DARK STONE CELL.",0
rd2: .byte "A LONG TORCHLIT CORRIDOR.",0
rd3: .byte "DUSTY SHELVES OF ANCIENT BOOKS.",0
rd4: .byte "STRANGE EQUIPMENT. A DEAD END.",0
rd5: .byte "OLD WEAPONS LINE THE WALLS.",0
rd6: .byte "A CHAMBER BEFORE THE VAULT.",0
rd7: .byte "A GOLDEN CHAMBER. VERY OLD.",0
rd8: .byte "YOU SEE DAYLIGHT AHEAD!",0

kw_n:     .byte "N",0
kw_s:     .byte "S",0
kw_e:     .byte "E",0
kw_w:     .byte "W",0
kw_take:  .byte "TAKE",0
kw_drop:  .byte "DROP",0
kw_inv:   .byte "INV",0
kw_look:  .byte "LOOK",0
kw_fight: .byte "FIGHT",0
kw_help:  .byte "HELP",0
kw_quit:  .byte "QUIT",0
kw_book:  .byte "BOOK",0
kw_key:   .byte "KEY",0
kw_sword: .byte "SWORD",0
kw_chip:  .byte "CHIP",0

txt_eq:        .byte "== ",0
txt_eq2:       .byte " ==",0
txt_exits:     .byte "EXITS:",0
txt_yousee:    .byte "YOU SEE:",0
txt_carrying:  .byte "CARRYING:",0
txt_nothing:   .byte " NOTHING",0
txt_cmd:       .byte "CMD> ",0
txt_item:      .byte "ITEM> ",0
txt_take_what: .byte "TAKE WHAT?",0
txt_drop_what: .byte "DROP WHAT?",0

msg_noexit_n:    .byte "NO EXIT NORTH.",0
msg_noexit_s:    .byte "NO EXIT SOUTH.",0
msg_noexit_e:    .byte "NO EXIT EAST.",0
msg_noexit_w:    .byte "NO EXIT WEST.",0
msg_guard_blocks:.byte "THE GUARD BLOCKS YOUR WAY!",0
msg_guard_here:  .byte "A GIANT GUARD STANDS HERE!",0
msg_guard_dead:  .byte "THE GUARD LIES DEFEATED.",0
msg_vault_locked:.byte "THE VAULT IS LOCKED!",0
msg_door_opens:  .byte "YOU USE THE KEY - DOOR OPENS!",0
msg_nochip:      .byte "NO CHIP! GO BACK FOR IT!",0
msg_not_here:    .byte "NOT HERE.",0
msg_taken:       .byte "TAKEN.",0
msg_dropped:     .byte "DROPPED.",0
msg_donthave:    .byte "YOU DON'T HAVE THAT.",0
msg_no_enemy:    .byte "NO ENEMY HERE.",0
msg_already:     .byte "ALREADY DEFEATED.",0
msg_need_sword:  .byte "YOU NEED A SWORD!",0
msg_fight2:      .byte "YOU SLASH - THE GUARD FALLS!",0
msg_unknown:     .byte "UNKNOWN CMD. TRY HELP.",0
msg_farewell:    .byte "FAREWELL!",0
msg_help:        .byte "N S E W TAKE DROP INV FIGHT QUIT",0

txt_title2: .byte "CRYPT OF THE 6502",0
story1: .byte "FIND THE GOLDEN 6502 CHIP",0
story2: .byte "AND ESCAPE THE ANCIENT CRYPT.",0
txt_press: .byte "PRESS RETURN TO BEGIN...",0

win1: .byte "*** YOU WIN! ***",0
win2: .byte "YOU ESCAPE WITH THE GOLDEN CHIP!",0
win3: .byte "THE 6502 POWERS ON...",0

; melodies: (freq lo, freq hi, duration ms) per note; dur=0 ends.
mel_intro:
    .byte <523,>523,150     ; C5
    .byte <659,>659,150     ; E5
    .byte <784,>784,150     ; G5
    .byte <1047,>1047,220   ; C6
    .byte <784,>784,140     ; G5
    .byte 0,0,0
mel_win:
    .byte <523,>523,120     ; C5
    .byte <659,>659,120     ; E5
    .byte <784,>784,120     ; G5
    .byte <1047,>1047,240   ; C6
    .byte <784,>784,120     ; G5
    .byte <1047,>1047,240   ; C6
    .byte 0,0,0

; ============================================================
; room pictures: 8 scenes, 11 rows each, RLE runs (count,char,colour),0/row.
; ============================================================
scene_lo:
    .byte <sc1,<sc2,<sc3,<sc4,<sc5,<sc6,<sc7,<sc8
scene_hi:
    .byte >sc1,>sc2,>sc3,>sc4,>sc5,>sc6,>sc7,>sc8

; -- 1 CELL: dark stone with a barred window --
sc1:
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 14,SOLID,DGRAY, 12,SOLID,BLUE, 14,SOLID,DGRAY, 0
    .byte 14,SOLID,DGRAY, 2,VBAR,CYAN, 2,SOLID,BLUE, 2,VBAR,CYAN, 2,SOLID,BLUE, 2,VBAR,CYAN, 2,SOLID,BLUE, 14,SOLID,DGRAY, 0
    .byte 14,SOLID,DGRAY, 12,SOLID,BLUE, 14,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,HATCH,DGRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 2 CORRIDOR: walls with two torches --
sc2:
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 9,SOLID,DGRAY, 2,SOLID,YELLOW, 18,SOLID,DGRAY, 2,SOLID,YELLOW, 9,SOLID,DGRAY, 0
    .byte 9,SOLID,DGRAY, 2,SOLID,ORANGE, 18,SOLID,DGRAY, 2,SOLID,ORANGE, 9,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,HATCH,DGRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 3 LIBRARY: colourful bookshelves --
sc3:
    .byte 40,SOLID,BROWN, 0
    .byte 5,SOLID,RED, 5,SOLID,GREEN, 5,SOLID,YELLOW, 5,SOLID,CYAN, 5,SOLID,PURPLE, 5,SOLID,LBLUE, 5,SOLID,LRED, 5,SOLID,WHITE, 0
    .byte 40,SOLID,BROWN, 0
    .byte 5,SOLID,CYAN, 5,SOLID,YELLOW, 5,SOLID,RED, 5,SOLID,GREEN, 5,SOLID,WHITE, 5,SOLID,PURPLE, 5,SOLID,LBLUE, 5,SOLID,LRED, 0
    .byte 40,SOLID,BROWN, 0
    .byte 5,SOLID,GREEN, 5,SOLID,RED, 5,SOLID,LBLUE, 5,SOLID,YELLOW, 5,SOLID,CYAN, 5,SOLID,WHITE, 5,SOLID,PURPLE, 5,SOLID,LRED, 0
    .byte 40,SOLID,BROWN, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 4 LAB: equipment with coloured bottles --
sc4:
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 6,SOLID,DGRAY, 2,SOLID,GREEN, 6,SOLID,DGRAY, 2,SOLID,RED, 6,SOLID,DGRAY, 2,SOLID,CYAN, 6,SOLID,DGRAY, 2,SOLID,YELLOW, 8,SOLID,DGRAY, 0
    .byte 6,SOLID,DGRAY, 2,SOLID,LGREEN, 6,SOLID,DGRAY, 2,SOLID,LRED, 6,SOLID,DGRAY, 2,SOLID,LBLUE, 6,SOLID,DGRAY, 2,SOLID,WHITE, 8,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 5 ARMORY: weapons and shields on the wall --
sc5:
    .byte 40,SOLID,BROWN, 0
    .byte 6,SOLID,BROWN, 1,VBAR,WHITE, 6,SOLID,BROWN, 1,VBAR,WHITE, 6,SOLID,BROWN, 1,VBAR,WHITE, 6,SOLID,BROWN, 1,VBAR,WHITE, 6,SOLID,BROWN, 1,VBAR,WHITE, 5,SOLID,BROWN, 0
    .byte 6,SOLID,BROWN, 1,VBAR,GRAY, 6,SOLID,BROWN, 1,VBAR,GRAY, 6,SOLID,BROWN, 1,VBAR,GRAY, 6,SOLID,BROWN, 1,VBAR,GRAY, 6,SOLID,BROWN, 1,VBAR,GRAY, 5,SOLID,BROWN, 0
    .byte 40,SOLID,BROWN, 0
    .byte 7,SOLID,BROWN, 4,SOLID,RED, 8,SOLID,BROWN, 4,SOLID,BLUE, 8,SOLID,BROWN, 4,SOLID,YELLOW, 5,SOLID,BROWN, 0
    .byte 40,SOLID,BROWN, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 6 GUARD ROOM: a red guard before the vault door --
sc6:
    .byte 40,SOLID,DGRAY, 0
    .byte 17,SOLID,DGRAY, 6,SOLID,BROWN, 17,SOLID,DGRAY, 0
    .byte 17,SOLID,DGRAY, 6,SOLID,BROWN, 17,SOLID,DGRAY, 0
    .byte 18,SOLID,DGRAY, 4,SOLID,LRED, 18,SOLID,DGRAY, 0
    .byte 17,SOLID,DGRAY, 6,SOLID,RED, 17,SOLID,DGRAY, 0
    .byte 17,SOLID,DGRAY, 6,SOLID,RED, 17,SOLID,DGRAY, 0
    .byte 18,SOLID,DGRAY, 4,SOLID,GRAY, 18,SOLID,DGRAY, 0
    .byte 40,SOLID,GRAY, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 7 VAULT: a pile of gold --
sc7:
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 40,SOLID,DGRAY, 0
    .byte 4,SOLID,DGRAY, 14,SOLID,YELLOW, 4,SOLID,WHITE, 14,SOLID,YELLOW, 4,SOLID,DGRAY, 0
    .byte 2,SOLID,DGRAY, 36,SOLID,YELLOW, 2,SOLID,DGRAY, 0
    .byte 40,SOLID,YELLOW, 0
    .byte 40,SOLID,YELLOW, 0
    .byte 5,SOLID,ORANGE, 30,SOLID,YELLOW, 5,SOLID,ORANGE, 0
    .byte 40,SOLID,ORANGE, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; -- 8 EXIT: daylight forest --
sc8:
    .byte 40,SOLID,GREEN, 0
    .byte 13,SOLID,GREEN, 4,SOLID,CYAN, 6,SOLID,GREEN, 4,SOLID,CYAN, 13,SOLID,GREEN, 0
    .byte 40,SOLID,GREEN, 0
    .byte 9,SOLID,GREEN, 3,SOLID,BROWN, 14,SOLID,GREEN, 3,SOLID,BROWN, 11,SOLID,GREEN, 0
    .byte 9,SOLID,GREEN, 3,SOLID,BROWN, 14,SOLID,GREEN, 3,SOLID,BROWN, 11,SOLID,GREEN, 0
    .byte 9,SOLID,GREEN, 3,SOLID,BROWN, 14,SOLID,GREEN, 3,SOLID,BROWN, 11,SOLID,GREEN, 0
    .byte 40,SOLID,LGREEN, 0
    .byte 40,SOLID,GREEN, 0
    .byte 40,SOLID,GREEN, 0
    .byte 40,SPACE,BLACK, 0
    .byte 40,SPACE,BLACK, 0

; ============================================================
.segment "VECTORS"
    .word irq_handler
    .word start
    .word irq_handler
