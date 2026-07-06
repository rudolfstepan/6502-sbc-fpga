; Tiny UART-monitor PRG: switch the FPGA VIC text path to 80 columns and then
; jump into EhBASIC without overwriting it.
;
; Build:
;   ca65 --cpu 6502 -t none -o text80_on.o text80_on.s
;   ld65 -C text80_on.cfg -o ../../roms/6502/text80_on.prg text80_on.o
;
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/text80_on.prg --prg --run --verbose

LOAD_ADDR      = $0200
BASIC_ENTRY    = $A000
VIC_GFX_MODE   = $9000
VIC_CURSOR_X   = $9001
VIC_CURSOR_Y   = $9002
VIC_TEXT_COLOR = $9003
VIC_BG_COLOR   = $9004
VIC_TEXT_ATTR  = $9005
VIC_TEXT_80    = $02
VRAM           = $8000
UART_DATA      = $8810
UART_SR        = $8811
UART_TDRE      = $10

.segment "LOADADDR"
    .word LOAD_ADDR

.segment "CODE"
start:
    sei
    cld
    ldx #$FF
    txs

    lda #$00
    sta VIC_GFX_MODE
    sta VIC_BG_COLOR
    lda #$01
    sta VIC_TEXT_COLOR
    lda #VIC_TEXT_80
    sta VIC_TEXT_ATTR

    ldx #$00
uart_loop:
    lda uart_msg,x
    beq start_basic
    jsr putc
    inx
    bne uart_loop

start_basic:
    jmp BASIC_ENTRY

putc:
    pha
wait_tx:
    lda UART_SR
    and #UART_TDRE
    beq wait_tx
    pla
    sta UART_DATA
    rts

.segment "RODATA"
uart_msg:
    .byte $0D, "TEXT80 BOOTSTRAP: $9005=$02, jumping to EhBASIC", $0D, 0
