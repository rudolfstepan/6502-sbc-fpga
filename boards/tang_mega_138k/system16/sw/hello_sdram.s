UART_DATA      equ     $00f00010
UART_STAT      equ     $00f00012
VIDEO_CTRL     equ     $00f00002
LED_STATUS     equ     $00f00000

        org     $00000000

start:
        movem.l d0-d1/a0,-(sp)
        move.w  #$001f,VIDEO_CTRL.l
        move.w  #$0005,LED_STATUS.l
        lea     message(pc),a0

send_next:
        moveq   #0,d0
        move.b  (a0)+,d0
        beq.s   done

wait_tx:
        move.w  UART_STAT.l,d1
        andi.w  #1,d1
        beq.s   wait_tx
        move.w  d0,UART_DATA.l
        bra.s   send_next

done:
        movem.l (sp)+,d0-d1/a0
        rts

message:
        dc.b    13,10,"HELLO FROM EXTERNAL SDRAM",13,10,0
        even
