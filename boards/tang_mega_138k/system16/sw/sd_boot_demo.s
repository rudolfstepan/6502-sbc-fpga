UART_DATA      equ     $00f00010
UART_STAT      equ     $00f00012
VIDEO_CTRL     equ     $00f00002
LED_STATUS     equ     $00f00000

        org     $00000000

start:
        move.w  #$2700,sr
        move.w  #$07e0,VIDEO_CTRL.l
        move.w  #$000a,LED_STATUS.l
        lea     message(pc),a0

send_next:
        moveq   #0,d0
        move.b  (a0)+,d0
        beq.s   running

wait_tx:
        move.w  UART_STAT.l,d1
        andi.w  #1,d1
        beq.s   wait_tx
        move.w  d0,UART_DATA.l
        bra.s   send_next

running:
        bra.s   running

message:
        dc.b    13,10,"SYSTEM16 SD BOOT OK",13,10,0
        even
