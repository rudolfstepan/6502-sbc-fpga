; ============================================================
; Blitter COPY/COPYT test — 640x400 RGB332 hi-res
;
; Exercises the new rect copy/move ops end-to-end on hardware:
;   * three plain COPYs of a decorated 64x64 source sprite in a row
;     -> all three must be pixel-identical to the source
;   * COPYT of the same sprite onto a striped background
;     -> the sprite's black ($00) slots show the stripes through
;   * two static overlapping MOVEs (+16,+16 and -16,-16)
;     -> the moved sprite must be intact (no smearing = the per-axis
;        backward/forward walk selection works)
;   * a cyan 40x40 box bouncing left/right forever, moved ONLY by
;     overlapping +/-2 px COPYs (trailing sliver erased with FILL)
;     -> continuously exercises both x walk directions, vsync-paced
;   * top-right corner square: green = DDR3 backend active, red = SDRAM0
;
; Build (split-map application at $A000, vectors at $FFFA):
;   make blitcopy-rom
; Upload:
;   roms\6502\upload\blitcopy.bat [COMx]
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000         ; bit5 = 640x400 8bpp hi-res
VIC2_CTRL1  = $D011         ; bit7 = raster line bit 8 (vsync detect)

BLIT_X0LO   = $8840
BLIT_X0HI   = $8841
BLIT_Y0LO   = $8842
BLIT_Y0HI   = $8843
BLIT_X1LO   = $8844
BLIT_X1HI   = $8845
BLIT_Y1LO   = $8846
BLIT_Y1HI   = $8847
BLIT_COL    = $8848         ; FILL/LINE colour; COPY: DST high bits (1:0=X 9:8, 2=Y8)
BLIT_OP     = $8849         ; 0=FILL 1=COPY 2=COPYT 3=LINE
BLIT_PG     = $884A
BLIT_FBCTL  = $884C         ; bit0 W = backend (1=DDR3); R bit7=ready, bit6=active
BLIT_DXLO   = $884D         ; COPY destination X low
BLIT_DYLO   = $884E         ; COPY destination Y low
BLIT_TRIG   = $884F         ; any write = trigger; read bit7 = busy

OP_FILL     = 0
OP_COPY     = 1
OP_COPYT    = 2
OP_LINE     = 3

; --- animation state (zero page) ---
BXLO  = $10                 ; bouncing box x (16-bit)
BXHI  = $11
DIR   = $12                 ; 0 = moving right, 1 = moving left
T0LO  = $13                 ; scratch 16-bit
T0HI  = $14

BOX_Y  = 320
BOX_W  = 40                 ; box is 40x40, moves 2 px per frame

; ============================================================
; Macros (compile-time coordinates)
; ============================================================
.macro SETRECT x0, y0, x1, y1
    lda #<(x0)
    sta BLIT_X0LO
    lda #>(x0)
    sta BLIT_X0HI
    lda #<(y0)
    sta BLIT_Y0LO
    lda #>(y0)
    sta BLIT_Y0HI
    lda #<(x1)
    sta BLIT_X1LO
    lda #>(x1)
    sta BLIT_X1HI
    lda #<(y1)
    sta BLIT_Y1LO
    lda #>(y1)
    sta BLIT_Y1HI
.endmacro

.macro MFILL x0, y0, x1, y1, col
    SETRECT x0, y0, x1, y1
    lda #(col)
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait
.endmacro

.macro MLINE x0, y0, x1, y1, col
    SETRECT x0, y0, x1, y1
    lda #(col)
    sta BLIT_COL
    lda #OP_LINE
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait
.endmacro

; copy the inclusive source rect to destination top-left (dx,dy)
.macro MCOPY sx0, sy0, sx1, sy1, dx, dy, opv
    SETRECT sx0, sy0, sx1, sy1
    lda #<(dx)
    sta BLIT_DXLO
    lda #<(dy)
    sta BLIT_DYLO
    lda #(((((dy) >> 8) & 1) << 2) | (((dx) >> 8) & 3))
    sta BLIT_COL
    lda #(opv)
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait
.endmacro

; ============================================================
.segment "CODE"

RESET:
    sei
    cld
    ldx #$FF
    txs

    ; --- prefer the DDR3 framebuffer backend when calibrated ---
    lda #$00
    sta BLIT_FBCTL
    lda BLIT_FBCTL
    bpl backend_done
    lda #$01
    sta BLIT_FBCTL
backend_done:

    ; --- 640x400 hi-res mode ---
    lda #$20
    sta VIC_MODE

    ; --- clear screen dark blue ---
    MFILL 0, 0, 639, 399, $02

    ; --- backend indicator top-right: green = DDR3 active, red = SDRAM0 ---
    lda BLIT_FBCTL
    and #$40
    beq ind_sdram
    MFILL 624, 0, 639, 15, $1C
    jmp ind_done
ind_sdram:
    MFILL 624, 0, 639, 15, $E0
ind_done:

    ; --- striped background for the transparent-copy area ---
    MFILL 392, 8, 455, 71, $92
    MFILL 400, 8, 407, 71, $1C
    MFILL 416, 8, 423, 71, $1C
    MFILL 432, 8, 439, 71, $1C
    MFILL 448, 8, 455, 71, $1C

    ; --- source sprite at (16,8), 64x64: red frame, yellow core, two black
    ;     slots (transparency holes), white X across ---
    MFILL 16,  8, 79, 71, $E0
    MFILL 24, 16, 71, 63, $FC
    MFILL 32, 24, 39, 55, $00
    MFILL 56, 24, 63, 55, $00
    MLINE 16,  8, 79, 71, $FF
    MLINE 79,  8, 16, 71, $FF

    ; --- three plain copies in a row: must look identical to the source ---
    MCOPY 16, 8, 79, 71,  96, 8, OP_COPY
    MCOPY 16, 8, 79, 71, 176, 8, OP_COPY
    MCOPY 16, 8, 79, 71, 256, 8, OP_COPY

    ; --- transparent copy onto the stripes: slots show the background ---
    MCOPY 16, 8, 79, 71, 392, 8, OP_COPYT

    ; --- overlapping MOVE right+down (+16,+16): backward walk required.
    ;     Place a copy at (96,120), then move it onto itself. The sprite at
    ;     (112,136) must be intact; an L-shaped remnant at the old top/left
    ;     edge is expected (copy does not erase). ---
    MCOPY 16, 8, 79, 71, 96, 120, OP_COPY
    MCOPY 96, 120, 159, 183, 112, 136, OP_COPY

    ; --- overlapping MOVE left+up (-16,-16): forward walk ---
    MCOPY 16, 8, 79, 71, 256, 120, OP_COPY
    MCOPY 256, 120, 319, 183, 240, 104, OP_COPY

    ; --- bouncing box: drawn once, then moved ONLY by overlapping copies ---
    MFILL 16, BOX_Y, 16 + BOX_W - 1, BOX_Y + BOX_W - 1, $1F
    lda #16
    sta BXLO
    lda #0
    sta BXHI
    sta DIR

; ============================================================
; Main loop: once per frame move the box 2 px by an overlapping copy,
; then erase the 2-px trailing sliver with a FILL.
; ============================================================
main_loop:
    jsr wait_frame

    ; source rect: (BX, BOX_Y) - (BX+39, BOX_Y+39)
    lda BXLO
    sta BLIT_X0LO
    sta BLIT_DXLO           ; dst x = BX +/- 2, patched below
    lda BXHI
    sta BLIT_X0HI
    lda #<BOX_Y
    sta BLIT_Y0LO
    sta BLIT_DYLO
    lda #>BOX_Y
    sta BLIT_Y0HI
    clc
    lda BXLO
    adc #(BOX_W - 1)
    sta BLIT_X1LO
    sta T0LO
    lda BXHI
    adc #0
    sta BLIT_X1HI
    sta T0HI                ; T0 = BX + 39 (right edge, used for left-move dst)
    lda #<(BOX_Y + BOX_W - 1)
    sta BLIT_Y1LO
    lda #>(BOX_Y + BOX_W - 1)
    sta BLIT_Y1HI

    ; destination: BX+2 (right) or BX-2 (left); COL carries DST_X bit 8,
    ; DST_Y (320) needs bit 8 set -> COL bit 2
    lda DIR
    bne move_left

    clc
    lda BXLO
    adc #2
    sta BLIT_DXLO
    lda BXHI
    adc #0
    jmp set_dst_hi

move_left:
    sec
    lda BXLO
    sbc #2
    sta BLIT_DXLO
    lda BXHI
    sbc #0

set_dst_hi:
    and #$03
    ora #$04                ; DST_Y bit 8 (BOX_Y = 320)
    sta BLIT_COL
    lda #OP_COPY
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait

    ; erase the 2-px trailing sliver at the old position
    lda DIR
    bne erase_right_edge

    ; moved right: erase old columns BX .. BX+1
    lda BXLO
    sta BLIT_X0LO
    clc
    adc #1
    sta BLIT_X1LO
    lda BXHI
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    jmp erase_common

erase_right_edge:
    ; moved left: erase old columns BX+38 .. BX+39 (T0 = BX+39)
    lda T0LO
    sta BLIT_X1LO
    sec
    sbc #1
    sta BLIT_X0LO
    lda T0HI
    sta BLIT_X1HI
    sbc #0
    sta BLIT_X0HI

erase_common:
    lda #<BOX_Y
    sta BLIT_Y0LO
    lda #>BOX_Y
    sta BLIT_Y0HI
    lda #<(BOX_Y + BOX_W - 1)
    sta BLIT_Y1LO
    lda #>(BOX_Y + BOX_W - 1)
    sta BLIT_Y1HI
    lda #$02                ; background dark blue
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait

    ; BX += / -= 2, bounce at 16 and 584
    lda DIR
    bne step_left

    clc
    lda BXLO
    adc #2
    sta BXLO
    lda BXHI
    adc #0
    sta BXHI
    cmp #2                  ; BX >= $248 (584)?
    bcs :+
    jmp main_loop
:   lda BXLO
    cmp #$48
    bcs :+
    jmp main_loop
:   lda #1
    sta DIR
    jmp main_loop

step_left:
    sec
    lda BXLO
    sbc #2
    sta BXLO
    lda BXHI
    sbc #0
    sta BXHI
    beq :+
    jmp main_loop           ; BX >= 256: keep going left
:   lda BXLO
    cmp #17                 ; BX <= 16?
    bcc :+
    jmp main_loop
:   lda #0
    sta DIR
    jmp main_loop

; ============================================================
; helpers
; ============================================================

; wait for the blitter to finish ($884F bit 7 = sticky busy)
busy_wait:
    bit BLIT_TRIG
    bmi busy_wait
    rts

; one frame: wait for raster bit 8 to rise, then to fall again
wait_frame:
:   bit VIC2_CTRL1
    bpl :-
:   bit VIC2_CTRL1
    bmi :-
    rts

irq_stub:
    rti

.segment "VECTORS"
    .word irq_stub          ; NMI
    .word RESET             ; RESET
    .word irq_stub          ; IRQ/BRK
