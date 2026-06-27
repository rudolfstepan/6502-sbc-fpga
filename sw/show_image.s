; ============================================================
; show_image -- display a 320x240 16-colour image (color16_mode) loaded from
; the data D64.  The 38400-byte framebuffer is split into five 8 KB parts
; (IMG0..IMG4), each a PRG whose load address is the $6000 bitmap window.  This
; loader selects each framebuffer bank via VIC_MODE bits 7:5, then loads the
; matching part straight into fb_ram, and finally shows bank 0.
;
; The disk is already mounted (the user LOADed this PRG from it), so no mount is
; needed.  Run: LOAD "SHOWIMG" then CALL 8192.
;
; Build: assembled at $2000 (prg2000.cfg) and packed with IMG0..IMG4 into a D64
; by tools/build_image_disk.py.
; ============================================================

KLOAD    = $F024             ; DISK_LOAD (DK_PTR -> name; loads to embedded addr)
KCHRIN   = $F006             ; blocking key read (echo invisible in bitmap mode)
DK_PTR   = $F2               ; kernel name pointer
VIC_MODE = $9000             ; bit0 bitmap, bit4 color16, bits7:5 framebuffer bank

.segment "CODE"
start:
    lda #0
    sta bank_ix              ; DISK_LOAD clobbers A/X/Y, so the loop index lives
load_loop:                   ; in memory, reloaded into X on every iteration
    ldx bank_ix
    lda modetab,x
    sta VIC_MODE             ; route the $6000 window to bank X (color16 + bitmap)
    lda namelo,x
    sta DK_PTR
    lda namehi,x
    sta DK_PTR+1
    jsr KLOAD                ; load IMGx straight into fb_ram bank X
    inc bank_ix
    lda bank_ix
    cmp #5
    bne load_loop

    lda #$11                 ; bank 0, color16 + bitmap: show the image
    sta VIC_MODE

    jsr KCHRIN               ; wait for a key, then return to text mode + BASIC
    lda #$00
    sta VIC_MODE
    rts

bank_ix:
    .byte 0

; (bank << 5) | $11  for banks 0..4  -> $6000 window maps into fb_ram
modetab:
    .byte $11, $31, $51, $71, $91

namelo:
    .byte <n0, <n1, <n2, <n3, <n4
namehi:
    .byte >n0, >n1, >n2, >n3, >n4
n0: .byte "IMG0", 0
n1: .byte "IMG1", 0
n2: .byte "IMG2", 0
n3: .byte "IMG3", 0
n4: .byte "IMG4", 0
