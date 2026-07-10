UART_DATA      equ     $00f00010
UART_STAT      equ     $00f00012
UART_RX        equ     $00f00014
VIDEO_CTRL     equ     $00f00002
LED_STATUS     equ     $00f00000
RAM_BASE       equ     $00000800
RAM_END        equ     $00001000
SDRAM_BASE     equ     $00001000
SDRAM_END      equ     $00f00000

        org     $00000000
        dc.l    SDRAM_END
        dc.l    start

start:
        move.w  #$2700,sr
        moveq   #0,d0
        lea     boot_message(pc),a0
        lea     boot_done(pc),a1

send_next:
        move.b  (a0)+,d0
        beq.s   send_done

wait_tx:
        move.w  UART_STAT.l,d1
        andi.w  #1,d1
        beq.s   wait_tx
        move.w  d0,UART_DATA.l
        bra.s   send_next

send_done:
        jmp     (a1)

boot_done:
        move.w  #$07e0,d0
        move.w  d0,VIDEO_CTRL.l
        moveq   #15,d0
        move.w  d0,LED_STATUS.l
        moveq   #0,d7

command_loop:
        move.w  UART_STAT.l,d1
        andi.w  #2,d1
        beq.s   command_loop
        move.w  UART_RX.l,d0
        andi.w  #$00ff,d0

echo_wait:
        move.w  UART_STAT.l,d1
        andi.w  #1,d1
        beq.s   echo_wait
        move.w  d0,UART_DATA.l

        tst.b   d7
        bne.w   parse_hex
        cmpi.b  #'?',d0
        beq.w   show_help
        cmpi.b  #'R',d0
        beq.w   show_status
        cmpi.b  #'r',d0
        beq.w   show_status
        cmpi.b  #'T',d0
        beq.w   ram_test
        cmpi.b  #'t',d0
        beq.w   ram_test
        cmpi.b  #'X',d0
        beq.w   sdram_test
        cmpi.b  #'x',d0
        beq.w   sdram_test
        cmpi.b  #'M',d0
        beq.w   read_start
        cmpi.b  #'m',d0
        beq.w   read_start
        cmpi.b  #'W',d0
        beq.w   write_start
        cmpi.b  #'w',d0
        beq.w   write_start
        cmpi.b  #'G',d0
        beq.w   run_start
        cmpi.b  #'g',d0
        beq.w   run_start
        cmpi.b  #13,d0
        beq.w   show_prompt
        bra.w   command_loop

read_start:
        moveq   #1,d7
        moveq   #0,d3
        moveq   #6,d5
        bra.w   command_loop

write_start:
        moveq   #2,d7
        moveq   #0,d3
        moveq   #6,d5
        bra.w   command_loop

run_start:
        moveq   #4,d7
        moveq   #0,d3
        moveq   #6,d5
        bra.w   command_loop

parse_hex:
        moveq   #0,d6
        move.b  d0,d6
        cmpi.b  #'0',d6
        blo.w   parse_error
        cmpi.b  #'9',d6
        bls.s   parse_digit
        cmpi.b  #'A',d6
        blo.s   parse_lower
        cmpi.b  #'F',d6
        bhi.s   parse_lower
        subi.b  #$37,d6
        bra.s   parse_store

parse_lower:
        cmpi.b  #'a',d6
        blo.w   parse_error
        cmpi.b  #'f',d6
        bhi.w   parse_error
        subi.b  #$57,d6
        bra.s   parse_store

parse_digit:
        subi.b  #'0',d6

parse_store:
        cmpi.b  #3,d7
        beq.s   parse_write_data
        lsl.l   #4,d3
        or.b    d6,d3
        subq.w  #1,d5
        bne.w   command_loop
        andi.l  #$00fffffe,d3
        movea.l d3,a2
        cmpi.b  #1,d7
        beq.s   read_complete
        cmpi.b  #4,d7
        beq.s   run_complete

        cmpi.l  #RAM_BASE,d3
        blo.w   parse_error
        cmpi.l  #SDRAM_END,d3
        bhs.w   parse_error
        moveq   #3,d7
        moveq   #0,d4
        moveq   #4,d5
        bra.w   command_loop

parse_write_data:
        lsl.w   #4,d4
        or.b    d6,d4
        subq.w  #1,d5
        bne.w   command_loop
        move.w  d4,(a2)
        moveq   #0,d7
        lea     write_ok_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

run_complete:
        cmpi.l  #SDRAM_BASE,d3
        blo.w   parse_error
        cmpi.l  #SDRAM_END,d3
        bhs.w   parse_error
        moveq   #0,d7
        jsr     (a2)
        bra.w   show_prompt

read_complete:
        move.w  (a2),d4
        moveq   #0,d7
        lea     value_prefix(pc),a0
        lea     hex_output_start(pc),a1
        bra.w   send_next

hex_output_start:
        moveq   #3,d5

hex_output_next:
        rol.w   #4,d4
        moveq   #0,d0
        move.b  d4,d0
        andi.b  #$0f,d0
        cmpi.b  #9,d0
        bls.s   hex_digit
        addi.b  #$37,d0
        bra.s   hex_send

hex_digit:
        addi.b  #'0',d0

hex_send:
        move.w  UART_STAT.l,d1
        andi.w  #1,d1
        beq.s   hex_send
        move.w  d0,UART_DATA.l
        dbra    d5,hex_output_next
        lea     result_suffix(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

ram_test:
        movea.l #RAM_BASE,a2
        move.w  #$03ff,d2
        move.w  #$a55a,d3

ram_write_loop:
        move.w  d3,(a2)+
        not.w   d3
        dbra    d2,ram_write_loop

        movea.l #RAM_BASE,a2
        move.w  #$03ff,d2
        move.w  #$a55a,d3

ram_verify_loop:
        cmp.w   (a2)+,d3
        bne.s   ram_test_failed
        not.w   d3
        dbra    d2,ram_verify_loop

        lea     ram_ok_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

ram_test_failed:
        move.w  #$f800,d0
        move.w  d0,VIDEO_CTRL.l
        moveq   #1,d0
        move.w  d0,LED_STATUS.l
        lea     ram_fail_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

sdram_test:
        movea.l #SDRAM_BASE,a2
        move.w  #$0fff,d2
        move.w  #$5aa5,d3

sdram_write_loop:
        move.w  d3,(a2)+
        not.w   d3
        dbra    d2,sdram_write_loop

        movea.l #SDRAM_BASE,a2
        move.w  #$0fff,d2
        move.w  #$5aa5,d3

sdram_verify_loop:
        cmp.w   (a2)+,d3
        bne.s   sdram_test_failed
        not.w   d3
        dbra    d2,sdram_verify_loop

        lea     sdram_ok_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

sdram_test_failed:
        move.w  #$f800,d0
        move.w  d0,VIDEO_CTRL.l
        moveq   #2,d0
        move.w  d0,LED_STATUS.l
        lea     sdram_fail_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

parse_error:
        moveq   #0,d7
        lea     error_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

show_help:
        lea     help_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

show_status:
        lea     status_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

show_prompt:
        lea     prompt_message(pc),a0
        lea     command_loop(pc),a1
        bra.w   send_next

boot_message:
        dc.b    "SYSTEM16 READY",13,10,"> ",0
help_message:
        dc.b    13,10,"? HELP  R STATUS  T BRAM  X SDRAM",13,10
        dc.b    "Maaaaaa READ  Waaaaaadddd WRITE",13,10
        dc.b    "Gaaaaaa RUN",13,10,"> ",0
status_message:
        dc.b    13,10,"SYSTEM16 READY",13,10,"> ",0
ram_ok_message:
        dc.b    13,10,"RAM PASS 2K",13,10,"> ",0
ram_fail_message:
        dc.b    13,10,"RAM FAIL",13,10,"> ",0
sdram_ok_message:
        dc.b    13,10,"SDRAM PASS 8K",13,10,"> ",0
sdram_fail_message:
        dc.b    13,10,"SDRAM FAIL",13,10,"> ",0
write_ok_message:
        dc.b    " OK",13,10,"> ",0
value_prefix:
        dc.b    " = $",0
result_suffix:
        dc.b    13,10,"> ",0
error_message:
        dc.b    13,10,"ERROR",13,10,"> ",0
prompt_message:
        dc.b    10,"> ",0
        even
