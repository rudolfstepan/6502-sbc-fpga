; Native C64 virtual-1541 KERNAL LOAD hook.
;
; Build:
;   make c64-v1541-hook-prg
;
; Workflow:
;   1. Upload roms/v1541_hook.prg with tools/c64_uart_prg_loader.py.
;   2. RUN it once.  It installs a RAM vector hook at $0330 (KERNAL LOAD).
;   3. Start tools/c64_1541_uart_gui.py, mount a D64, then use normal C64
;      KERNAL loads such as LOAD"*",8,1.

.setcpu "6502"

LOAD_ADDR  = $0801
CODE_START = $C000

UART_DATA   = $DE00
UART_STATUS = $DE01
SCREEN_DIAG = $0400 + 22 * 40

CHROUT = $FFD2
IMAIN  = $0302
ILOAD  = $0330

STATUS_REG = $90
MEMUSS     = $C3
NDX        = $C6
TXTTAB     = $2B
VARTAB     = $2D
ARYTAB     = $2F
STREND     = $31
FNLEN      = $B7
SA         = $B9
FA         = $BA
FNADR      = $BB

ZP_PTR = $FB
KEYD   = $0277

REQ_MAGIC  = $C6
RESP_MAGIC = $64
CMD_LOAD_CHUNK = $23
CHUNK_SIZE = $80
TEST_STATUS = $C4F0

.ifdef DUMMY_SELFTEST
.export selftest_pass_jam
.export selftest_fail_jam
.endif

.segment "LOADADDR"
        .word LOAD_ADDR

.segment "STARTUP"
basic:
.ifdef DUMMY_SCRIPTED_BASIC
basic_line_10:
        .word basic_line_20
        .word 10
        .byte $9E, "49152", 0     ; 10 SYS 49152 ($C000)
basic_line_20:
        .word basic_line_30
        .word 20
        .byte $93, $22, "$", $22, ",8", 0
basic_line_30:
        .word basic_end
        .word 30
        .byte $9B, 0              ; 30 LIST
basic_end:
        .word 0
.else
        .word basic_end
        .word 10
        .byte $9E, "49152", 0     ; 10 SYS 49152 ($C000)
basic_end:
        .word 0
.endif

.segment "CODE"
.macro JMP_IF_NE target
        beq :+
        jmp target
:
.endmacro

install:
.ifdef DUMMY_STATUS
        lda #$01
        sta TEST_STATUS
.endif
        sei
        cld
        jsr save_zp_plain
        lda ILOAD
        sta old_load
        lda ILOAD+1
        sta old_load+1
        lda #<vload
        sta ILOAD
        lda #>vload
        sta ILOAD+1
.ifdef DUMMY_STATUS
        lda #$02
        sta TEST_STATUS
.endif
        lda #<install_msg
        ldy #>install_msg
        jsr print_z
.ifdef DUMMY_AUTOTEST
        jsr queue_autotest_load_dir
.endif
        jsr restore_zp
.ifdef DUMMY_SELFTEST
        cli
        jmp run_selftest
.endif
.ifdef DUMMY_SCRIPTED_BASIC
        cli
        rts
.else
        ldx #$FB
        txs
        cli
        jmp (IMAIN)
.endif

vload:
.ifdef DUMMY_STATUS
        pha
        lda #$11
        sta TEST_STATUS
        pla
.endif
        stx MEMUSS
        sty MEMUSS+1
        sta verify_flag
        stx req_addr
        sty req_addr+1
        lda FA
        cmp #$08
        beq vload_device8
        jmp (old_load)

vload_device8:
        sei
        cld
        jsr save_zp
        lda #$00
        sta STATUS_REG
        sta OFF
        sta OFF+1
        sta FIRST
        inc FIRST
        lda req_addr
        sta DST
        sta LOADP
        lda req_addr+1
        sta DST+1
        sta LOADP+1

.ifdef DUMMY_DRIVE
        jmp dummy_load
.endif

load_next_chunk:
        lda #$00
        sta SUM
        sta CHECK
        sta BAD
        jsr send_chunk_request
        jsr recv_response_magic
        bcc :+
        jmp load_failed
:
        jsr uart_get_timeout          ; command
        bcc :+
        jmp load_failed
:
        cmp #CMD_LOAD_CHUNK
        beq :+
        jmp load_failed
:
        sta SUM

        jsr uart_get_timeout          ; status
        bcc :+
        jmp load_failed
:
        sta STATUS_CODE
        clc
        adc SUM
        sta SUM
        lda STATUS_CODE
        beq :+
        jmp load_failed
:
        jsr uart_get_timeout          ; payload length low
        bcc :+
        jmp load_failed
:
        sta LEN
        sta GOT
        clc
        adc SUM
        sta SUM

        jsr uart_get_timeout          ; payload length high
        bcc :+
        jmp load_failed
:
        sta LEN+1
        sta GOT+1
        clc
        adc SUM
        sta SUM

        lda LEN
        ora LEN+1
        bne have_data
        lda FIRST
        beq recv_checksum
        jmp load_failed

have_data:
        lda FIRST
        beq recv_payload_loop
        lda LEN+1
        bne have_loadaddr
        lda LEN
        cmp #$02
        bcs have_loadaddr
        jmp load_failed

have_loadaddr:
        jsr read_payload_byte         ; PRG load address low
        bcc :+
        jmp load_failed
:
        sta FILE_LOAD
        jsr dec_len
        jsr read_payload_byte         ; PRG load address high
        bcc :+
        jmp load_failed
:
        sta FILE_LOAD+1
        jsr dec_len
        lda SA
        beq keep_requested_addr
        lda FILE_LOAD
        sta DST
        sta LOADP
        lda FILE_LOAD+1
        sta DST+1
        sta LOADP+1
keep_requested_addr:
        jsr set_zp_dst
        lda #$00
        sta FIRST

recv_payload_loop:
        lda LEN
        ora LEN+1
        beq recv_checksum
        jsr read_payload_byte
        bcs load_failed
        ldy #$00
        sta (ZP_PTR),y
        jsr inc_dst
        jsr dec_len
        jmp recv_payload_loop

recv_checksum:
        jsr uart_get_timeout
        bcs load_failed
        sta CHECK
        lda CHECK
        cmp SUM
        bne load_failed
        jsr advance_offset
        lda GOT+1
        beq :+
        jmp load_next_chunk
:
        lda GOT
        cmp #CHUNK_SIZE
        bcc load_done
        jmp load_next_chunk

load_done:
        lda #$00
        sta STATUS_REG
.ifdef DUMMY_STATUS
        lda #$33
        sta TEST_STATUS
.endif
        jsr patch_basic_if_0801
.ifdef DIAG_LOAD_RETURN
        jsr write_diag_screen
        jsr restore_zp
.ifndef HOLD_IRQ_ON_RETURN
        cli
.endif
        ldx DST
        ldy DST+1
        lda #$00
        clc
        rts
.else
        jsr restore_zp
.ifndef HOLD_IRQ_ON_RETURN
        cli
.endif
        ldx DST
        ldy DST+1
        lda #$00
        clc
        rts
.endif

load_failed:
        lda #$05
        sta STATUS_REG
.ifdef DUMMY_STATUS
        lda #$EE
        sta TEST_STATUS
.endif
        jsr restore_zp
.ifndef HOLD_IRQ_ON_RETURN
        cli
.endif
        sec
        rts

.ifdef DUMMY_DRIVE
dummy_load:
        lda FNLEN
        beq dummy_load_program
        ldy #$00
        lda (FNADR),y
        cmp #'$'
        beq dummy_load_directory

dummy_load_program:
.ifdef DUMMY_STATUS
        lda #$20
        sta TEST_STATUS
.endif
        lda dummy_program_prg
        sta FILE_LOAD
        lda dummy_program_prg+1
        sta FILE_LOAD+1
        lda SA
        beq :+
        lda FILE_LOAD
        sta DST
        sta LOADP
        lda FILE_LOAD+1
        sta DST+1
        sta LOADP+1
:
        jsr set_zp_dst
        ldx #$00
dummy_program_loop:
        lda dummy_program_prg+2,x
        ldy #$00
        sta (ZP_PTR),y
        jsr inc_dst
        inx
        cpx #dummy_program_prg_end - dummy_program_prg - 2
        bne dummy_program_loop
        jmp load_done

dummy_load_directory:
.ifdef DUMMY_STATUS
        lda #$21
        sta TEST_STATUS
.endif
        lda dummy_directory_prg
        sta FILE_LOAD
        lda dummy_directory_prg+1
        sta FILE_LOAD+1
        lda SA
        beq :+
        lda FILE_LOAD
        sta DST
        sta LOADP
        lda FILE_LOAD+1
        sta DST+1
        sta LOADP+1
:
        jsr set_zp_dst
        ldx #$00
dummy_directory_loop:
        lda dummy_directory_prg+2,x
        ldy #$00
        sta (ZP_PTR),y
        jsr inc_dst
        inx
        cpx #dummy_directory_prg_end - dummy_directory_prg - 2
        bne dummy_directory_loop
.ifdef DUMMY_AUTOTEST
        jsr queue_autotest_list
.endif
        jmp load_done
.endif

send_chunk_request:
        lda #REQ_MAGIC
        jsr uart_put
        lda #CMD_LOAD_CHUNK
        jsr uart_put_sum
        lda FNLEN
        clc
        adc #$04
        jsr uart_put_sum
        lda #$00
        jsr uart_put_sum
        lda OFF
        jsr uart_put_sum
        lda OFF+1
        jsr uart_put_sum
        lda #CHUNK_SIZE
        jsr uart_put_sum
        lda #$00
        jsr uart_put_sum
        ldy #$00
send_name_loop:
        cpy FNLEN
        beq send_request_sum
        lda (FNADR),y
        jsr uart_put_sum
        iny
        bne send_name_loop
send_request_sum:
        lda SUM
        jmp uart_put

recv_response_magic:
        lda #$10
        sta RESYNC
recv_magic_loop:
        jsr uart_get_timeout
        bcs recv_magic_fail
        cmp #RESP_MAGIC
        beq recv_magic_ok
        sta BAD
        dec RESYNC
        bne recv_magic_loop
recv_magic_fail:
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
        jsr set_zp_dst
        rts

set_zp_dst:
        lda DST
        sta ZP_PTR
        lda DST+1
        sta ZP_PTR+1
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
        lda DST
        sta VARTAB
        sta ARYTAB
        sta STREND
        lda DST+1
        sta VARTAB+1
        sta ARYTAB+1
        sta STREND+1
patch_basic_done:
        rts

save_zp:
        jsr save_zp_plain
        lda DST
        sta ZP_PTR
        lda DST+1
        sta ZP_PTR+1
        rts

save_zp_plain:
        lda ZP_PTR
        sta zp_save
        lda ZP_PTR+1
        sta zp_save+1
        rts

restore_zp:
        lda zp_save
        sta ZP_PTR
        lda zp_save+1
        sta ZP_PTR+1
        rts

.ifdef DUMMY_SELFTEST
run_selftest:
        lda #$08
        sta FA
        lda #$00
        sta SA
        sta STATUS_REG
        lda #$01
        sta FNLEN
        lda #<selftest_name_dir
        sta FNADR
        lda #>selftest_name_dir
        sta FNADR+1
        lda #<LOAD_ADDR
        ldx #<LOAD_ADDR
        ldy #>LOAD_ADDR
        jsr vload
        bcs selftest_fail
        lda TEST_STATUS
        cmp #$33
        bne selftest_fail
        lda #$44
        sta TEST_STATUS
        lda #$0D
        jsr CHROUT
        lda #<selftest_pass_msg
        ldy #>selftest_pass_msg
        jsr print_z
selftest_pass_jam:
        .byte $02

selftest_fail:
        lda #$EF
        sta TEST_STATUS
        lda #$0D
        jsr CHROUT
        lda #<selftest_fail_msg
        ldy #>selftest_fail_msg
        jsr print_z
selftest_fail_jam:
        .byte $02
.endif

uart_put_sum:
        pha
        jsr uart_put
        pla
        clc
        adc SUM
        sta SUM
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
        lda #$10
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

print_z:
        sta ZP_PTR
        sty ZP_PTR+1
        ldy #$00
print_loop:
        lda (ZP_PTR),y
        beq print_done
        jsr CHROUT
        iny
        bne print_loop
print_done:
        rts

.ifdef DIAG_LOAD_RETURN
write_diag_screen:
        lda #$00
        sta diag_pos
        lda #<diag_msg
        ldy #>diag_msg
        jsr screen_print_z
        lda DST+1
        jsr screen_print_hex
        lda DST
        jsr screen_print_hex
        lda #<diag_sp_msg
        ldy #>diag_sp_msg
        jsr screen_print_z
        tsx
        txa
        jsr screen_print_hex
        lda #<diag_status_msg
        ldy #>diag_status_msg
        jsr screen_print_z
        lda STATUS_REG
        jsr screen_print_hex
        lda #<diag_vec_msg
        ldy #>diag_vec_msg
        jsr screen_print_z
        lda ILOAD+1
        jsr screen_print_hex
        lda ILOAD
        jsr screen_print_hex
        rts

screen_print_z:
        sta ZP_PTR
        sty ZP_PTR+1
        ldy #$00
screen_print_loop:
        lda (ZP_PTR),y
        beq screen_print_done
        jsr screen_put_ascii
        iny
        bne screen_print_loop
screen_print_done:
        rts

screen_print_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr screen_print_nibble
        pla
        and #$0F
screen_print_nibble:
        cmp #$0A
        bcc screen_digit
        adc #$06
screen_digit:
        adc #$30
        jmp screen_put_ascii

screen_put_ascii:
        pha
        ldx diag_pos
        cpx #$28
        bcs screen_put_drop
        pla
        jsr ascii_to_screen
        sta SCREEN_DIAG,x
        inc diag_pos
        rts
screen_put_drop:
        pla
        rts

ascii_to_screen:
        cmp #'A'
        bcc ascii_screen_done
        cmp #'Z' + 1
        bcs ascii_screen_done
        sec
        sbc #$40
ascii_screen_done:
        rts
.endif

print_diag:
        jsr save_zp_plain
        lda #$0D
        jsr CHROUT
        lda #<diag_msg
        ldy #>diag_msg
        jsr print_z
        lda DST+1
        jsr print_hex
        lda DST
        jsr print_hex
        lda #<diag_sp_msg
        ldy #>diag_sp_msg
        jsr print_z
        tsx
        txa
        jsr print_hex
        lda #<diag_status_msg
        ldy #>diag_status_msg
        jsr print_z
        lda STATUS_REG
        jsr print_hex
        lda #<diag_vec_msg
        ldy #>diag_vec_msg
        jsr print_z
        lda ILOAD+1
        jsr print_hex
        lda ILOAD
        jsr print_hex
        lda #$0D
        jsr CHROUT
        jsr restore_zp
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

.ifdef DUMMY_AUTOTEST
queue_autotest_load_dir:
        lda #<autotest_load_dir_keys
        ldy #>autotest_load_dir_keys
        jmp queue_keys

queue_autotest_list:
        lda #<autotest_list_keys
        ldy #>autotest_list_keys
        jmp queue_keys

queue_keys:
        sta ZP_PTR
        sty ZP_PTR+1
        ldx #$00
        ldy #$00
queue_keys_loop:
        lda (ZP_PTR),y
        beq queue_keys_done
        sta KEYD,x
        inx
        iny
        bne queue_keys_loop
queue_keys_done:
        stx NDX
        rts
.endif

.segment "RODATA"
old_load:   .word $F4A5

.segment "BSS"
req_addr:   .res 2
verify_flag:.res 1
DST:        .res 2
LOADP:      .res 2
OFF:        .res 2
LEN:        .res 2
GOT:        .res 2
FILE_LOAD:  .res 2
SUM:        .res 1
TMP:        .res 1
CHECK:      .res 1
BAD:        .res 1
RESYNC:     .res 1
RETRIES:    .res 1
FIRST:      .res 1
STATUS_CODE:.res 1
zp_save:    .res 2
diag_pos:   .res 1

.segment "RODATA"
install_msg:
        .byte "V1541 KERNAL LOAD HOOK READY", $0D
        .byte "USE LOAD", $22, "*", $22, ",8,1", $0D, 0
diag_msg:
        .byte "VLOAD OK END $", 0
diag_sp_msg:
        .byte " SP $", 0
diag_status_msg:
        .byte " ST $", 0
diag_vec_msg:
        .byte " V $", 0

.ifdef DUMMY_SELFTEST
selftest_name_dir:
        .byte "$"
selftest_pass_msg:
        .byte "V1541 SELFTEST PASS", $0D, 0
selftest_fail_msg:
        .byte "V1541 SELFTEST FAIL", $0D, 0
.endif

.ifdef DUMMY_DRIVE
dummy_program_prg:
        .word LOAD_ADDR
dummy_program_line:
        .word LOAD_ADDR + (dummy_program_end - dummy_program_prg - 2)
        .word 10
        .byte $99, " ", $22, "V1541 DUMMY OK", $22, 0
dummy_program_end:
        .word 0
dummy_program_prg_end:

dummy_directory_prg:
        .word LOAD_ADDR
dummy_dir_header:
        .word LOAD_ADDR + (dummy_dir_file - dummy_directory_prg - 2)
        .word 0
        .byte $22, "DUMMY DRIVE", $22, " 00 2A", 0
dummy_dir_file:
        .word LOAD_ADDR + (dummy_dir_free - dummy_directory_prg - 2)
        .word 5
        .byte $22, "DUMMY", $22, " PRG", 0
dummy_dir_free:
        .word LOAD_ADDR + (dummy_dir_end - dummy_directory_prg - 2)
        .word 581
        .byte "BLOCKS FREE.", 0
dummy_dir_end:
        .word 0
dummy_directory_prg_end:
.endif

.ifdef DUMMY_AUTOTEST
autotest_load_dir_keys:
        .byte "LOAD", $22, "$", $22, ",8", $0D, 0
autotest_list_keys:
        .byte "LIST", $0D, 0
.endif
