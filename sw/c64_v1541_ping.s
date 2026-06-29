; Native C64 virtual-1541 UART transport smoke test.
;
; Build:
;   make c64-v1541-ping-prg
;
; Workflow:
;   1. Upload roms/v1541_ping.prg with tools/c64_uart_prg_loader.py.
;   2. Start tools/c64_1541_uart_gui.py on the same COM port.
;   3. Type RUN on the C64.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $0810

UART_DATA   = $DE00
UART_STATUS = $DE01

CHROUT = $FFD2
GETIN  = $FFE4

REQ_MAGIC  = $C6
RESP_MAGIC = $64
CMD_PING   = $01

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "ZEROPAGE"
PTR:    .res 2
LENLO:  .res 1
LENHI:  .res 1
SUM:    .res 1
COUNT:  .res 1
TMP:    .res 1
BUFIDX: .res 1

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

        jsr uart_flush
        jsr send_ping
        jsr recv_response
        bcs failed

        lda #<ok_msg
        ldy #>ok_msg
        jsr print_z
        jmp wait_key

failed:
        lda #<fail_msg
        ldy #>fail_msg
        jsr print_z

wait_key:
        lda #<key_msg
        ldy #>key_msg
        jsr print_z
wait_key_loop:
        jsr GETIN
        beq wait_key_loop
        cli
        rts

send_ping:
        lda #REQ_MAGIC
        jsr uart_put
        lda #CMD_PING
        jsr uart_put
        lda #$00
        jsr uart_put
        jsr uart_put
        lda #CMD_PING
        jsr uart_put
        rts

recv_response:
        jsr uart_get_timeout
        bcs recv_fail
        cmp #RESP_MAGIC
        bne recv_fail

        jsr uart_get_timeout          ; command
        bcs recv_fail
        cmp #CMD_PING
        bne recv_fail
        sta SUM

        jsr uart_get_timeout          ; status
        bcs recv_fail
        cmp #$00
        bne recv_fail
        clc
        adc SUM
        sta SUM

        jsr uart_get_timeout          ; length lo
        bcs recv_fail
        sta LENLO
        clc
        adc SUM
        sta SUM

        jsr uart_get_timeout          ; length hi
        bcs recv_fail
        sta LENHI
        clc
        adc SUM
        sta SUM

        lda LENHI
        bne recv_fail                 ; smoke test expects a short text reply
        lda LENLO
        cmp #$21
        bcs recv_fail                 ; keep reply inside REPLY_BUF

        lda LENLO
        sta COUNT
        lda #$00
        sta BUFIDX
recv_payload:
        lda COUNT
        beq recv_checksum
        jsr uart_get_timeout
        bcs recv_fail
        sta TMP
        clc
        adc SUM
        sta SUM
        lda TMP
        ldy BUFIDX
        sta REPLY_BUF,y
        inc BUFIDX
        dec COUNT
        jmp recv_payload

recv_checksum:
        jsr uart_get_timeout
        bcs recv_fail
        cmp SUM
        bne recv_fail
        jsr print_reply
        lda #$0D
        jsr CHROUT
        clc
        rts

recv_fail:
        sec
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
        ldy #$80
get_outer:
        ldx #$00
get_inner:
        lda UART_STATUS
        and #$01
        bne get_byte
        dex
        bne get_inner
        dey
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

print_reply:
        lda #<reply_prefix
        ldy #>reply_prefix
        jsr print_z
        lda LENLO
        sta COUNT
        lda #$00
        sta BUFIDX
print_reply_loop:
        lda COUNT
        beq print_reply_done
        ldy BUFIDX
        lda REPLY_BUF,y
        jsr CHROUT
        inc BUFIDX
        dec COUNT
        jmp print_reply_loop
print_reply_done:
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

.segment "RODATA"
title:
        .byte "VIRTUAL 1541 UART TEST", $0D, $0D, 0
reply_prefix:
        .byte "REPLY: ", 0
ok_msg:
        .byte "PING OK", $0D, 0
fail_msg:
        .byte "PING FAILED", $0D, 0
key_msg:
        .byte $0D, "PRESS KEY", $0D, 0
REPLY_BUF:
        .res 32
