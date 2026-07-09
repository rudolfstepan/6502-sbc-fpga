; ============================================================
; Generic PRG-in-ROM launcher for the split ROM map.
;
; Wraps an unmodified PRG (2-byte little-endian load-address header +
; payload) into a 16 KiB split-ROM image that uploads like the mandelbrot
; ROMs: the PRG is carried in the ROM window at $A000, copied to its load
; address at reset and started with an indirect jump through the header.
; The demos keep running from RAM exactly as when uploaded with --prg, so
; self-modifying code and in-image data tables need no adaptation.
;
; Use from a per-demo stub:
;   .define PRG_FILE "blittest.prg"
;   .include "prg_rom_wrapper.inc"
; assembled with --bin-include-dir pointing at the PRG directory, linked
; with mandelbrot_bitmap.cfg (application at $A000, vectors at $FFFA).
; Upload:
;   python tools/upload_monitor_hex.py roms/6502/<name>_rom.bin --split-rom --run
; ============================================================

; Transient zero-page copy pointers. Only live until the PRG starts; the
; pair for the entry vector sits at $FE/$FF so JMP () never crosses a page.
SRC   = $F8
DST   = $FA
LEN   = $FC
ENTRY = $FE

; Framebuffer backend select/status ($884C, blitter window): write bit 0 =
; 1 -> DDR3, 0 -> SDRAM0; read bit 7 = DDR3 calibrated/ready, bit 6 =
; effective backend. NOT $9007 -- demos write emulator frame acks there.
VIC_FB_CTRL = $884C

.segment "CODE"

RESET:
    sei
    cld
    ldx #$FF
    txs

    ; Prefer the DDR3 framebuffer backend when it is calibrated. The core
    ; ignores the select latch while DDR3 is not ready, and only latching it
    ; when bit 7 is already high avoids a mid-demo backend flip if DDR3 were
    ; to finish calibrating later.
    lda #$00
    sta VIC_FB_CTRL         ; default: SDRAM0 backend
    lda VIC_FB_CTRL
    bpl backend_done        ; bit 7 clear -> DDR3 not calibrated
    lda #$01
    sta VIC_FB_CTRL         ; calibrated -> run the demo on DDR3
backend_done:

    lda #<(PAYLOAD+2)
    sta SRC+0
    lda #>(PAYLOAD+2)
    sta SRC+1
    lda PAYLOAD+0           ; PRG header = load address (little endian)
    sta DST+0
    sta ENTRY+0
    lda PAYLOAD+1
    sta DST+1
    sta ENTRY+1
    lda #<PAYLOAD_LEN
    sta LEN+0
    lda #>PAYLOAD_LEN
    sta LEN+1

copy_loop:
    lda LEN+0
    ora LEN+1
    beq copy_done
    ldy #0
    lda (SRC),y
    sta (DST),y
    inc SRC+0
    bne :+
    inc SRC+1
:   inc DST+0
    bne :+
    inc DST+1
:   lda LEN+0
    bne :+
    dec LEN+1
:   dec LEN+0
    jmp copy_loop

copy_done:
    jmp (ENTRY)             ; run address = load address (as with --prg --run)

irq_stub:
    rti

PAYLOAD:
    .incbin PRG_FILE
PAYLOAD_END:
PAYLOAD_LEN = PAYLOAD_END - PAYLOAD - 2

.segment "VECTORS"
    .word irq_stub          ; NMI
    .word RESET             ; RESET (button restart re-runs the copier)
    .word irq_stub          ; IRQ/BRK
