; MiSTer64 SD D64 selector smoke test.
;
; This PRG exercises the Tang MiSTer C64 probe's $DF00 SD mount window:
;   $DF00-$DF03  .d64 start LBA, little-endian
;   $DF04        write $01 to mount/invalidate
;   $DF05        status: bit0 SD init done, bit1 drive active, bit7 packed mode
;
; The table is included from sw/c64_sd_d64_select_table.inc.  Generate it with:
;   python tools/d64/make_fat16_d64_card.py ... --selector-table sw/c64_sd_d64_select_table.inc
;
; After selecting a disk, return to BASIC and use:
;   LOAD"$",8
;   LIST
;   LOAD"*",8
;   RUN

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

CHROUT = $FFD2
GETIN  = $FFE4

SD_LBA0 = $DF00
SD_LBA1 = $DF01
SD_LBA2 = $DF02
SD_LBA3 = $DF03
SD_CMD  = $DF04
SD_STAT = $DF05

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
PTR:    .res 2
SEL:    .res 1

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "2064", 0       ; 10 SYS 2064 ($0810)
basic_end:
        .word 0
        .res 3

.segment "CODE"
start:
        sei
        cld
        lda #$93
        jsr CHROUT

        lda #<title
        ldy #>title
        jsr print_z

        lda SD_STAT
        and #$01
        bne show_menu
        lda #<no_sd
        ldy #>no_sd
        jsr print_z
        jmp done

show_menu:
        lda #<menu
        ldy #>menu
        jsr print_z

wait_key:
        jsr GETIN
        beq wait_key
        cmp #$03                 ; RUN/STOP in many KERNAL mappings
        beq done
        jsr key_to_index
        bcc mount_index
        jmp wait_key

key_to_index:
        cmp #'1'
        bcc not_digit
        cmp #('9' + 1)
        bcs not_digit
        sec
        sbc #'1'
        jmp check_index
not_digit:
        cmp #'A'
        bcc bad_key
        cmp #('Z' + 1)
        bcs bad_key
        sec
        sbc #('A' - 9)
check_index:
        cmp #ENTRY_COUNT
        bcs bad_key
        clc
        rts
bad_key:
        sec
        rts

mount_index:
        sta SEL
        asl
        asl                      ; index * 4
        tax
        lda lba_table+0,x
        sta SD_LBA0
        lda lba_table+1,x
        sta SD_LBA1
        lda lba_table+2,x
        sta SD_LBA2
        lda lba_table+3,x
        sta SD_LBA3
        lda #$01
        sta SD_CMD

        lda #<mounted
        ldy #>mounted
        jsr print_z
        lda SEL
        jsr print_name
        lda #<after
        ldy #>after
        jsr print_z

done:
        cli
        rts

print_name:
        asl
        tay
        lda name_ptrs,y
        tax
        lda name_ptrs+1,y
        tay
        txa
        jsr print_z
        rts

print_z:
        sta PTR
        sty PTR+1
        ldy #0
loop:
        lda (PTR),y
        beq out
        jsr CHROUT
        iny
        bne loop
out:
        rts

.segment "RODATA"
title:
        .byte "MISTER64 SD D64 SELECT", $0D, $0D, 0
no_sd:
        .byte "SD NOT READY", $0D, 0
mounted:
        .byte $0D, "MOUNTED ", 0
after:
        .byte $0D, "NOW USE LOAD", $22, "$", $22, ",8", $0D, 0

.include "c64_sd_d64_select_table.inc"
