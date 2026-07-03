; Tang MiSTer64 SD direct-sector fastload smoke test.
;
; This is a hardware-assisted loader for the probe's $DF08-$DF0C sector window.
; It loads the first PRG from the currently mounted D64 by parsing the CBM DOS
; directory and following the sector chain directly, bypassing IEC transfer.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $C000

CHROUT = $FFD2
IMAIN  = $0302

TXTTAB = $2B
VARTAB = $2D
ARYTAB = $2F
STREND = $31

FL_TRACK  = $DF08
FL_SECTOR = $DF09
FL_OFFSET = $DF0A
FL_STAT   = $DF0B
FL_DATA   = $DF0C

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
PTR:    .res 2
DST:    .res 2

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "49152", 0     ; 10 SYS 49152 ($C000)
basic_end:
        .word 0

.segment "CODE"
start:
        sei
        cld
        jsr save_zp
        lda #$93
        jsr CHROUT
        lda #<title
        ldy #>title
        jsr print_z

        lda FL_STAT
        and #$01
        bne :+
        lda #<no_sd_msg
        ldy #>no_sd_msg
        jmp fail_msg
:
        jsr find_first_prg
        bcc :+
        lda #<not_found_msg
        ldy #>not_found_msg
        jmp fail_msg
:
        lda #<load_msg
        ldy #>load_msg
        jsr print_z
        jsr load_prg_chain
        bcc :+
        lda #<read_fail_msg
        ldy #>read_fail_msg
        jmp fail_msg
:
        jsr patch_basic_if_0801
        lda #<ok_msg
        ldy #>ok_msg
        jsr print_z
        lda DST+1
        jsr print_hex
        lda DST
        jsr print_hex
        lda #$0D
        jsr CHROUT
        jsr restore_zp
        cli
        jmp (IMAIN)

fail_msg:
        jsr print_z
        jsr restore_zp
        cli
        jmp (IMAIN)

find_first_prg:
        lda #18
        sta DIRT
        lda #1
        sta DIRS

dir_sector:
        lda DIRT
        sta REQT
        lda DIRS
        sta REQS
        jsr read_sector
        bcc :+
        rts
:
        lda #0
        jsr get_byte
        sta NEXTT
        lda #1
        jsr get_byte
        sta NEXTS
        lda #2
        sta ENTRY_OFF
        ldx #8

dir_entry:
        lda ENTRY_OFF
        jsr get_byte
        sta TMP
        lda TMP
        and #$80
        beq dir_next
        lda TMP
        and #$07
        cmp #$02                 ; PRG
        beq dir_found

dir_next:
        clc
        lda ENTRY_OFF
        adc #32
        sta ENTRY_OFF
        dex
        bne dir_entry
        lda NEXTT
        beq dir_not_found
        sta DIRT
        lda NEXTS
        sta DIRS
        jmp dir_sector

dir_found:
        clc
        lda ENTRY_OFF
        adc #1
        jsr get_byte
        sta CURT
        clc
        lda ENTRY_OFF
        adc #2
        jsr get_byte
        sta CURS
        clc
        rts

dir_not_found:
        sec
        rts

load_prg_chain:
        lda #1
        sta FIRST

load_sector:
        lda CURT
        sta REQT
        lda CURS
        sta REQS
        jsr read_sector
        bcc :+
        rts
:
        lda #0
        jsr get_byte
        sta NEXTT
        lda #1
        jsr get_byte
        sta NEXTS

        lda #2
        sta OFFSET
        lda FIRST
        beq have_payload_start
        lda #2
        jsr get_byte
        sta DST
        sta LOADP
        lda #3
        jsr get_byte
        sta DST+1
        sta LOADP+1
        lda #4
        sta OFFSET
        lda #0
        sta FIRST

have_payload_start:
        lda NEXTT
        beq last_sector
        lda #$FF
        sta ENDOFF
        jmp copy_payload

last_sector:
        lda NEXTS
        sta ENDOFF

copy_payload:
        lda ENDOFF
        cmp OFFSET
        bcc sector_done
        lda OFFSET
        jsr get_byte
        ldy #0
        sta (DST),y
        jsr inc_dst
        lda OFFSET
        cmp ENDOFF
        beq sector_done
        inc OFFSET
        jmp copy_payload

sector_done:
        lda NEXTT
        beq load_done
        sta CURT
        lda NEXTS
        sta CURS
        jmp load_sector

load_done:
        clc
        rts

read_sector:
        lda REQT
        sta FL_TRACK
        lda REQS
        sta FL_SECTOR
        lda #$03                 ; clear previous error + start
        sta FL_STAT

read_wait:
        lda FL_STAT
        and #$08
        bne read_error
        lda FL_STAT
        and #$06
        cmp #$04
        beq read_ok
        jmp read_wait

read_error:
        sec
        rts
read_ok:
        clc
        rts

get_byte:
        sta FL_OFFSET
        lda FL_DATA
        rts

inc_dst:
        inc DST
        bne :+
        inc DST+1
:
        rts

patch_basic_if_0801:
        lda LOADP
        cmp #<LOAD_ADDR
        bne patch_done
        lda LOADP+1
        cmp #>LOAD_ADDR
        bne patch_done
        lda LOADP
        sta TXTTAB
        lda LOADP+1
        sta TXTTAB+1
        lda DST
        sta VARTAB
        sta ARYTAB
        sta STREND
        lda DST+1
        sta VARTAB+1
        sta ARYTAB+1
        sta STREND+1
patch_done:
        rts

save_zp:
        lda PTR
        sta zp_save
        lda PTR+1
        sta zp_save+1
        lda DST
        sta zp_save+2
        lda DST+1
        sta zp_save+3
        rts

restore_zp:
        lda zp_save
        sta PTR
        lda zp_save+1
        sta PTR+1
        lda zp_save+2
        sta DST
        lda zp_save+3
        sta DST+1
        rts

print_z:
        sta PTR
        sty PTR+1
        ldy #0
:
        lda (PTR),y
        beq :+
        jsr CHROUT
        iny
        bne :-
:
        rts

print_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr print_nibble
        pla
        and #$0F
print_nibble:
        cmp #$0A
        bcc :+
        adc #$06
:
        adc #$30
        jmp CHROUT

.segment "BSS"
REQT:      .res 1
REQS:      .res 1
DIRT:      .res 1
DIRS:      .res 1
CURT:      .res 1
CURS:      .res 1
NEXTT:     .res 1
NEXTS:     .res 1
ENTRY_OFF: .res 1
OFFSET:    .res 1
ENDOFF:    .res 1
FIRST:     .res 1
TMP:       .res 1
LOADP:     .res 2
zp_save:   .res 4

.segment "RODATA"
title:
        .byte "TANG SD FASTLOAD FIRST", $0D, $0D, 0
load_msg:
        .byte "LOADING FIRST PRG", $0D, 0
ok_msg:
        .byte "FASTLOAD OK END $", 0
no_sd_msg:
        .byte "SD NOT READY", $0D, 0
not_found_msg:
        .byte "NO PRG IN DIRECTORY", $0D, 0
read_fail_msg:
        .byte "SECTOR READ FAILED", $0D, 0
