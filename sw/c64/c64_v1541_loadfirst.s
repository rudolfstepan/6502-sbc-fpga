; Native C64 virtual-1541 LOADFIRST smoke loader.
;
; Build:
;   make c64-v1541-loadfirst-prg
;
; Workflow:
;   1. Upload roms/v1541_loadfirst.prg with tools/c64_uart_prg_loader.py.
;   2. Start tools/virtual_1541/c64_1541_uart_gui.py on the same COM port and mount a D64.
;   3. Type RUN on the C64.
;   4. On success the selected PRG is loaded to its own load address. Type RUN
;      manually if the PRG is a BASIC-style loader.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $C000

UART_DATA   = $DE00
UART_STATUS = $DE01

CHROUT = $FFD2

IMAIN  = $0302
TXTTAB = $2B
VARTAB = $2D
ARYTAB = $2F
STREND = $31

REQ_MAGIC  = $C6
RESP_MAGIC = $64
CMD_LOAD_FIRST_CHUNK = $22
CHUNK_SIZE = $80

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
PTR:    .res 2
DST:    .res 2
ENDP:   .res 2
LOADP:  .res 2
LEN:    .res 2
OFF:    .res 2
GOT:    .res 2
SUM:    .res 1
TMP:    .res 1
CHECK:  .res 1
BAD:    .res 1
RESYNC: .res 1
STATUS: .res 1
RETRIES:.res 1
ERRCODE:.res 1
FIRST:  .res 1
ZP_END:

.segment "STARTUP"
basic:
        .word basic_end
        .word 10
        .byte $9E, "49152", 0     ; 10 SYS 49152 ($C000)
basic_end:
        .word 0

.segment "CODE"
.macro JMP_IF_C_SET target
        bcc :+
        jmp target
:
.endmacro

.macro JMP_IF_NE target
        beq :+
        jmp target
:
.endmacro

start:
        sei
        cld
        jsr save_zp
        lda #$93
        jsr CHROUT

        lda #<title
        ldy #>title
        jsr print_z

        jsr uart_flush
        lda #<send_msg
        ldy #>send_msg
        jsr print_z
        jsr send_loadfirst
        lda #<wait_msg
        ldy #>wait_msg
        jsr print_z
        jsr recv_prg
        bcs failed

        jsr patch_basic_if_0801
        lda #<ok_msg
        ldy #>ok_msg
        jsr print_z
        lda ENDP+1
        jsr print_hex
        lda ENDP
        jsr print_hex
        lda #$0D
        jsr CHROUT
        lda #<run_msg
        ldy #>run_msg
        jsr print_z
        jsr restore_zp
        cli
        jmp (IMAIN)

failed:
        lda #<fail_msg
        ldy #>fail_msg
        jsr print_z
        lda STATUS
        jsr print_hex
        lda #<err_msg
        ldy #>err_msg
        jsr print_z
        lda ERRCODE
        jsr print_hex
        lda #$0D
        jsr CHROUT
        lda #<diag_msg
        ldy #>diag_msg
        jsr print_z
        lda DST+1
        jsr print_hex
        lda DST
        jsr print_hex
        lda #<left_msg
        ldy #>left_msg
        jsr print_z
        lda LEN+1
        jsr print_hex
        lda LEN
        jsr print_hex
        lda #<sum_msg
        ldy #>sum_msg
        jsr print_z
        lda SUM
        jsr print_hex
        lda #<got_msg
        ldy #>got_msg
        jsr print_z
        lda CHECK
        jsr print_hex
        lda #<bad_msg
        ldy #>bad_msg
        jsr print_z
        lda BAD
        jsr print_hex
        lda #$0D
        jsr CHROUT
        jsr print_status_text
        jsr restore_zp
        cli
        jmp (IMAIN)

send_loadfirst:
        lda #$00
        sta OFF
        sta OFF+1
        sta FIRST
        inc FIRST
        rts

send_chunk_request:
        lda #REQ_MAGIC
        jsr uart_put
        lda #CMD_LOAD_FIRST_CHUNK
        jsr uart_put
        lda #$04
        jsr uart_put
        lda #$00
        jsr uart_put
        lda OFF
        jsr uart_put
        lda OFF+1
        jsr uart_put
        lda #CHUNK_SIZE
        jsr uart_put
        lda #$00
        jsr uart_put
        lda #CMD_LOAD_FIRST_CHUNK + $04 + CHUNK_SIZE
        clc
        adc OFF
        clc
        adc OFF+1
        jsr uart_put
        rts

recv_prg:
        lda #$FF
        sta STATUS
        lda #$00
        sta ERRCODE

recv_next_chunk:
        lda #$00
        sta SUM
        sta CHECK
        sta BAD
        jsr send_chunk_request
        jsr recv_response_magic
        bcc :+
        jmp recv_fail_code
:
        jsr uart_get_timeout          ; command
        bcc :+
        lda #$03
        jmp recv_fail_code
:
        cmp #CMD_LOAD_FIRST_CHUNK
        beq :+
        lda #$04
        jmp recv_fail_code
:
        sta SUM

        jsr uart_get_timeout          ; status
        bcc :+
        lda #$05
        jmp recv_fail_code
:
        sta STATUS
        cmp #$00
        beq :+
        lda #$0F
        jmp recv_fail_code
:
        clc
        adc SUM
        sta SUM

        jsr uart_get_timeout          ; payload length low
        bcc :+
        lda #$06
        jmp recv_fail_code
:
        sta LEN
        sta GOT
        clc
        adc SUM
        sta SUM

        jsr uart_get_timeout          ; payload length high
        bcc :+
        lda #$07
        jmp recv_fail_code
:
        sta LEN+1
        sta GOT+1
        clc
        adc SUM
        sta SUM

        lda LEN+1
        bne have_data
        lda LEN
        bne have_data
        lda FIRST
        bne recv_short
        jmp recv_checksum
have_data:
        lda FIRST
        beq recv_payload_loop
        lda LEN+1
        bne have_loadaddr
        lda LEN
        cmp #$02
        bcs have_loadaddr
recv_short:
        lda #$08
        jmp recv_fail_code
have_loadaddr:
        jsr read_payload_byte         ; PRG load address low
        bcc :+
        lda #$09
        jmp recv_fail_code
:
        sta DST
        sta LOADP
        jsr dec_len
        jsr read_payload_byte         ; PRG load address high
        bcc :+
        lda #$0A
        jmp recv_fail_code
:
        sta DST+1
        sta LOADP+1
        jsr dec_len
        lda #$00
        sta FIRST

recv_payload_loop:
        lda LEN
        ora LEN+1
        beq recv_checksum
        jsr read_payload_byte
        bcc :+
        lda #$0B
        jmp recv_fail_code
:
        ldy #$00
        sta (DST),y
        jsr inc_dst
        jsr dec_len
        jmp recv_payload_loop

recv_checksum:
        jsr uart_get_timeout
        bcc :+
        lda #$0C
        jmp recv_fail_code
:
        sta CHECK
        lda UART_STATUS
        and #$04
        beq :+
        lda #$0E
        jmp recv_fail_code
:
        lda CHECK
        cmp SUM
        beq :+
        lda #$0D
        jmp recv_fail_code
:
        jsr advance_offset
        lda GOT+1
        beq :+
        jmp recv_next_chunk
:
        lda GOT
        cmp #CHUNK_SIZE
        bcc recv_done
        jmp recv_next_chunk
recv_done:
        lda DST
        sta ENDP
        lda DST+1
        sta ENDP+1
        clc
        rts

recv_fail:
        sec
        rts

recv_fail_code:
        sta ERRCODE
        sec
        rts

recv_response_magic:
        lda #$10
        sta RESYNC
recv_magic_loop:
        jsr uart_get_timeout
        bcc :+
        lda #$01
        sec
        rts
:
        cmp #RESP_MAGIC
        beq recv_magic_ok
        sta BAD
        dec RESYNC
        bne recv_magic_loop
        lda #$02
        sec
        rts
recv_magic_ok:
        clc
        rts

read_payload_byte:
        jsr uart_get_timeout
        bcs read_payload_done
        sta TMP
        clc
        adc SUM
        sta SUM
        lda TMP
        clc
read_payload_done:
        rts

dec_len:
        lda LEN
        bne dec_len_low
        dec LEN+1
dec_len_low:
        dec LEN
        rts

inc_dst:
        inc DST
        bne inc_dst_done
        inc DST+1
inc_dst_done:
        rts

advance_offset:
        clc
        lda OFF
        adc GOT
        sta OFF
        lda OFF+1
        adc GOT+1
        sta OFF+1
        rts

patch_basic_if_0801:
        lda LOADP
        cmp #<LOAD_ADDR
        bne patch_basic_done
        lda LOADP+1
        cmp #>LOAD_ADDR
        bne patch_basic_done
        lda LOADP
        sta TXTTAB
        lda LOADP+1
        sta TXTTAB+1
        lda ENDP
        sta VARTAB
        sta ARYTAB
        sta STREND
        lda ENDP+1
        sta VARTAB+1
        sta ARYTAB+1
        sta STREND+1
patch_basic_done:
        rts

save_zp:
        ldx #$00
save_zp_loop:
        lda PTR,x
        sta zp_save,x
        inx
        cpx #ZP_END-PTR
        bne save_zp_loop
        rts

restore_zp:
        ldx #$00
restore_zp_loop:
        lda zp_save,x
        sta PTR,x
        inx
        cpx #ZP_END-PTR
        bne restore_zp_loop
        rts

uart_put:
        pha
uart_put_wait:
        lda UART_STATUS
        and #$02
        bne uart_put_wait
        pla
        sta UART_DATA
        rts

uart_get_timeout:
        lda #$08
        sta RETRIES
get_outer:
        ldy #$FF
get_mid:
        ldx #$00
get_inner:
        lda UART_STATUS
        and #$01
        bne get_byte
        dex
        bne get_inner
        dey
        bne get_mid
        dec RETRIES
        bne get_outer
        sec
        rts
get_byte:
        lda UART_DATA
        clc
        rts

uart_flush:
        ldx #$20
flush_loop:
        lda UART_STATUS
        and #$01
        beq flush_done
        lda UART_DATA
        dex
        bne flush_loop
flush_done:
        rts

print_z:
        sta PTR
        sty PTR+1
        ldy #$00
print_loop:
        lda (PTR),y
        beq print_done
        jsr CHROUT
        iny
        bne print_loop
print_done:
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
        bcc print_digit
        adc #$06
print_digit:
        adc #$30
        jmp CHROUT

print_status_text:
        lda STATUS
        cmp #$01
        beq status_no_disk
        cmp #$02
        beq status_not_found
        cmp #$03
        beq status_bad_request
        cmp #$04
        beq status_io_error
        cmp #$FF
        beq status_no_response
        rts
status_no_disk:
        lda #<no_disk_msg
        ldy #>no_disk_msg
        jmp print_z
status_not_found:
        lda #<not_found_msg
        ldy #>not_found_msg
        jmp print_z
status_bad_request:
        lda #<bad_request_msg
        ldy #>bad_request_msg
        jmp print_z
status_io_error:
        lda #<io_error_msg
        ldy #>io_error_msg
        jmp print_z
status_no_response:
        lda #<no_response_msg
        ldy #>no_response_msg
        jmp print_z

.segment "BSS"
zp_save:
        .res ZP_END-PTR

.segment "RODATA"
title:
        .byte "VIRTUAL 1541 LOADFIRST", $0D, $0D, 0
send_msg:
        .byte "SEND LOADFIRST", $0D, 0
wait_msg:
        .byte "WAIT DRIVE", $0D, 0
ok_msg:
        .byte "LOAD OK, END $", 0
run_msg:
        .byte "READY - TYPE RUN IF APPLICABLE", $0D, 0
fail_msg:
        .byte "LOAD FAILED, STATUS $", 0
err_msg:
        .byte " ERR $", 0
diag_msg:
        .byte "ADDR $", 0
left_msg:
        .byte " LEFT $", 0
sum_msg:
        .byte " SUM $", 0
got_msg:
        .byte " GOT $", 0
bad_msg:
        .byte " BAD $", 0
no_disk_msg:
        .byte "NO DISK MOUNTED", $0D, 0
not_found_msg:
        .byte "FILE NOT FOUND", $0D, 0
bad_request_msg:
        .byte "BAD REQUEST", $0D, 0
io_error_msg:
        .byte "DRIVE IO ERROR", $0D, 0
no_response_msg:
        .byte "NO RESPONSE FROM DRIVE", $0D, 0
