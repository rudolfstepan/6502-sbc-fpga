; ============================================================
; Blitter demo — Amiga-style feature show, 640x400 RGB332
;
; Every blitter feature runs live, each in its own screen zone:
;   * top band:   sprite strip (sources) + 16 colour bars, colour-cycled
;                 every frame with FILL (copper-bar look)
;   * left zone:  line kaleidoscope — zone cleared with FILL, then four
;                 colour-cycling LINEs to sine-driven endpoints per frame
;   * playfield:  24 shaded balls ("bobs") on Lissajous paths, each moved
;                 per frame by FILL-erase + transparent COPYT from the
;                 sprite strip (their $00 corners stay see-through)
;   * bottom:     a 64x64 checkered slider that glides left/right moved
;                 ONLY by overlapping +/-4 px COPYs (both walk directions)
;   * top-right:  backend square, green = DDR3 active, red = SDRAM0
;
; ~70 blitter ops per frame, vsync-paced: on DDR3 this holds 60 FPS
; (~4200 blits/s), on the SDRAM0 backend it visibly drops — the speed
; difference between the backends is the demo.
;
; Build:  make blitdemo-rom
; Upload: roms\6502\upload\blitdemo.bat [COMx]
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000
VIC2_CTRL1  = $D011

BLIT_X0LO   = $8840
BLIT_X0HI   = $8841
BLIT_Y0LO   = $8842
BLIT_Y0HI   = $8843
BLIT_X1LO   = $8844
BLIT_X1HI   = $8845
BLIT_Y1LO   = $8846
BLIT_Y1HI   = $8847
BLIT_COL    = $8848
BLIT_OP     = $8849
BLIT_FBCTL  = $884C
BLIT_DXLO   = $884D
BLIT_DYLO   = $884E
BLIT_TRIG   = $884F

OP_FILL     = 0
OP_COPY     = 1
OP_COPYT    = 2
OP_LINE     = 3

NBOBS       = 24

; --- zero page ---
FRM    = $10                ; frame counter
BOBI   = $11                ; bob loop index
TMP    = $12
CURXLO = $13
CURXHI = $14
CURYLO = $15
CURYHI = $16
PRVXLO = $17
PRVXHI = $18
PRVYLO = $19
PRVYHI = $1A
SXLO   = $1B                ; slider x (16-bit)
SXHI   = $1C
SDIR   = $1D                ; 0 = right, 1 = left
T0LO   = $1E
T0HI   = $1F

; --- bob state arrays (main RAM) ---
prevx_lo = $0300
prevx_hi = $0320
prevy_lo = $0340
prevy_hi = $0360
xidx_arr = $0380
yidx_arr = $03A0

SLIDER_Y  = 330             ; slider strip 330..393 (64 high)
SLIDER_W  = 64

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

; shaded 32x32 ball at (bx,0) in the sprite strip: octagon silhouette on the
; $00 strip background (corners stay transparent for COPYT)
.macro DRAWBALL bx, cdark, cbrite
    MFILL bx+8,  0, bx+23, 31, cdark
    MFILL bx+0,  8, bx+31, 23, cdark
    MFILL bx+4,  4, bx+27, 27, cdark
    MFILL bx+8,  6, bx+21, 17, cbrite
    MFILL bx+11, 8, bx+16, 13, $FF
.endmacro

; ============================================================
.segment "CODE"

RESET:
    sei
    cld
    ldx #$FF
    txs

    ; --- prefer the DDR3 backend when calibrated ---
    lda #$00
    sta BLIT_FBCTL
    lda BLIT_FBCTL
    bpl backend_done
    lda #$01
    sta BLIT_FBCTL
backend_done:

    lda #$20
    sta VIC_MODE            ; 640x400 hi-res

    ; --- black screen, then the static scene parts ---
    MFILL 0, 0, 639, 399, $00

    ; backend indicator (top-right, outside the bar band)
    lda BLIT_FBCTL
    and #$40
    beq ind_sdram
    MFILL 626, 2, 639, 15, $1C
    jmp ind_done
ind_sdram:
    MFILL 626, 2, 639, 15, $E0
ind_done:

    ; sprite strip background + three shaded balls at x = 0 / 32 / 64
    MFILL 0, 0, 95, 31, $00
    DRAWBALL  0, $A0, $E0   ; red
    DRAWBALL 32, $10, $1C   ; green
    DRAWBALL 64, $02, $17   ; blue/cyan
    ; strip separator
    MFILL 0, 32, 639, 33, $6D

    ; slider object: 64x64 checkered block with white frame at (8, SLIDER_Y)
    MFILL  8,      SLIDER_Y,      8+63, SLIDER_Y+63, $FF
    MFILL 10,      SLIDER_Y+2,    8+31, SLIDER_Y+31, $E3
    MFILL  8+32,   SLIDER_Y+2,    8+61, SLIDER_Y+31, $1F
    MFILL 10,      SLIDER_Y+32,   8+31, SLIDER_Y+61, $1F
    MFILL  8+32,   SLIDER_Y+32,   8+61, SLIDER_Y+61, $E3
    lda #8
    sta SXLO
    lda #0
    sta SXHI
    sta SDIR

    ; --- init bob state ---
    ldx #NBOBS-1
init_bobs:
    lda xphase_tab,x
    sta xidx_arr,x
    lda yphase_tab,x
    sta yidx_arr,x
    lda #144
    sta prevx_lo,x          ; harmless first-frame erase position
    lda #0
    sta prevx_hi,x
    sta prevy_hi,x
    lda #36
    sta prevy_lo,x
    dex
    bpl init_bobs

    lda #0
    sta FRM

; ============================================================
; Frame loop
; ============================================================
main_loop:
    jsr wait_frame
    inc FRM

    jsr do_bars             ; FILL:  colour-cycling copper bars
    jsr do_lines            ; LINE:  kaleidoscope zone
    jsr do_bobs             ; COPYT: erase + redraw all bobs
    jsr do_slider           ; COPY:  overlapping move of the big block
    jmp main_loop

; ------------------------------------------------------------
; 16 colour bars (x 96..623, y 2..31), colours rotate with FRM/8
; ------------------------------------------------------------
do_bars:
    lda FRM
    lsr
    lsr
    lsr
    sta TMP                 ; bar colour cycle
.repeat 16, K
    lda TMP
    clc
    adc #K
    and #15
    tax
    lda barcols,x
    sta BLIT_COL
    SETRECT 96+K*33, 2, 96+K*33+31, 31
    lda #OP_FILL
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait
.endrepeat
    rts

; ------------------------------------------------------------
; line kaleidoscope: zone (8,36)-(135,163), centre (72,100)
; ------------------------------------------------------------
do_lines:
    MFILL 8, 36, 135, 163, $00
.repeat 4, K
    ; endpoint x = 8 + sin(2*FRM + K*64)/2
    lda FRM
    asl
    clc
    adc #K*64
    tay
    lda sintab,y
    lsr
    clc
    adc #8
    sta BLIT_X1LO
    ; endpoint y = 36 + sin(3*FRM + K*64 + 85)/2
    lda FRM
    asl
    sta TMP
    lda FRM
    clc
    adc TMP
    clc
    adc #<(K*64 + 85)       ; phase wraps mod 256
    tay
    lda sintab,y
    lsr
    clc
    adc #36
    sta BLIT_Y1LO
    ; from the centre, colour cycles with FRM/4
    lda #72
    sta BLIT_X0LO
    lda #100
    sta BLIT_Y0LO
    lda #0
    sta BLIT_X0HI
    sta BLIT_Y0HI
    sta BLIT_X1HI
    sta BLIT_Y1HI
    lda FRM
    lsr
    lsr
    clc
    adc #K
    and #7
    tax
    lda linecols,x
    sta BLIT_COL
    lda #OP_LINE
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait
.endrepeat
    rts

; ------------------------------------------------------------
; bobs: erase all old positions, then update + transparent-copy all
; ------------------------------------------------------------
do_bobs:
    ; phase 1: erase
    lda #0
    sta BOBI
erase_loop:
    ldx BOBI
    lda prevx_lo,x
    sta PRVXLO
    lda prevx_hi,x
    sta PRVXHI
    lda prevy_lo,x
    sta PRVYLO
    lda prevy_hi,x
    sta PRVYHI
    jsr erase_bob
    inc BOBI
    lda BOBI
    cmp #NBOBS
    bne erase_loop

    ; phase 2: update + draw
    lda #0
    sta BOBI
draw_loop:
    ldx BOBI
    ; x = 144 + sin*1.5  (144..525)
    lda xidx_arr,x
    clc
    adc xspd_tab,x
    sta xidx_arr,x
    tay
    lda sintab,y
    sta TMP
    lsr
    clc
    adc TMP
    sta CURXLO
    lda #0
    adc #0
    sta CURXHI
    clc
    lda CURXLO
    adc #144
    sta CURXLO
    lda CURXHI
    adc #0
    sta CURXHI
    ; y = 36 + sin  (36..291)
    lda yidx_arr,x
    clc
    adc yspd_tab,x
    sta yidx_arr,x
    tay
    lda sintab,y
    clc
    adc #36
    sta CURYLO
    lda #0
    adc #0
    sta CURYHI
    ; draw from the sprite strip
    lda srcx_tab,x
    jsr draw_bob
    ; remember position for next frame's erase
    ldx BOBI
    lda CURXLO
    sta prevx_lo,x
    lda CURXHI
    sta prevx_hi,x
    lda CURYLO
    sta prevy_lo,x
    lda CURYHI
    sta prevy_hi,x
    inc BOBI
    lda BOBI
    cmp #NBOBS
    bne draw_loop
    rts

; erase 32x32 at (PRVX, PRVY) with background black
erase_bob:
    lda PRVXLO
    sta BLIT_X0LO
    clc
    adc #31
    sta BLIT_X1LO
    lda PRVXHI
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    lda PRVYLO
    sta BLIT_Y0LO
    clc
    adc #31
    sta BLIT_Y1LO
    lda PRVYHI
    sta BLIT_Y0HI
    adc #0
    sta BLIT_Y1HI
    lda #$00
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    sta BLIT_TRIG
    jmp busy_wait

; transparent-copy the 32x32 ball at (A,0) in the strip to (CURX, CURY)
draw_bob:
    sta BLIT_X0LO
    clc
    adc #31
    sta BLIT_X1LO
    lda #0
    sta BLIT_X0HI
    sta BLIT_X1HI
    sta BLIT_Y0LO
    sta BLIT_Y0HI
    sta BLIT_Y1HI
    lda #31
    sta BLIT_Y1LO
    lda CURXLO
    sta BLIT_DXLO
    lda CURYLO
    sta BLIT_DYLO
    lda CURYHI
    and #1
    asl
    asl
    sta TMP
    lda CURXHI
    and #3
    ora TMP
    sta BLIT_COL            ; DST high bits ride in COLOR for COPY ops
    lda #OP_COPYT
    sta BLIT_OP
    sta BLIT_TRIG
    jmp busy_wait

; ------------------------------------------------------------
; slider: move the 64x64 block by +/-4 px with an OVERLAPPING copy,
; then erase the 4-px trailing sliver
; ------------------------------------------------------------
do_slider:
    ; source rect (SX, SLIDER_Y)-(SX+63, SLIDER_Y+63)
    lda SXLO
    sta BLIT_X0LO
    clc
    adc #(SLIDER_W-1)
    sta BLIT_X1LO
    sta T0LO
    lda SXHI
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    sta T0HI                ; T0 = right edge
    lda #<SLIDER_Y
    sta BLIT_Y0LO
    sta BLIT_DYLO
    lda #>SLIDER_Y
    sta BLIT_Y0HI
    lda #<(SLIDER_Y+63)
    sta BLIT_Y1LO
    lda #>(SLIDER_Y+63)
    sta BLIT_Y1HI

    lda SDIR
    bne slider_left
    clc
    lda SXLO
    adc #4
    sta BLIT_DXLO
    lda SXHI
    adc #0
    jmp slider_hi
slider_left:
    sec
    lda SXLO
    sbc #4
    sta BLIT_DXLO
    lda SXHI
    sbc #0
slider_hi:
    and #$03
    ora #$04                ; SLIDER_Y >= 256 -> DST_Y bit 8
    sta BLIT_COL
    lda #OP_COPY
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait

    ; erase the 4-px trailing sliver at the old position
    lda SDIR
    bne sliver_right
    lda SXLO                ; moved right: erase SX .. SX+3
    sta BLIT_X0LO
    clc
    adc #3
    sta BLIT_X1LO
    lda SXHI
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    jmp sliver_fill
sliver_right:
    lda T0LO                ; moved left: erase SX+60 .. SX+63
    sta BLIT_X1LO
    sec
    sbc #3
    sta BLIT_X0LO
    lda T0HI
    sta BLIT_X1HI
    sbc #0
    sta BLIT_X0HI
sliver_fill:
    lda #<SLIDER_Y
    sta BLIT_Y0LO
    lda #>SLIDER_Y
    sta BLIT_Y0HI
    lda #<(SLIDER_Y+63)
    sta BLIT_Y1LO
    lda #>(SLIDER_Y+63)
    sta BLIT_Y1HI
    lda #$00
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    sta BLIT_TRIG
    jsr busy_wait

    ; SX +/- 4, bounce at 8 and 560
    lda SDIR
    bne slider_step_left
    clc
    lda SXLO
    adc #4
    sta SXLO
    lda SXHI
    adc #0
    sta SXHI
    cmp #2                  ; SX >= $230 (560)?
    bcc slider_done
    lda SXLO
    cmp #$30
    bcc slider_done
    lda #1
    sta SDIR
slider_done:
    rts
slider_step_left:
    sec
    lda SXLO
    sbc #4
    sta SXLO
    lda SXHI
    sbc #0
    sta SXHI
    bne slider_done         ; SX >= 256: keep going
    lda SXLO
    cmp #9                  ; SX <= 8?
    bcs slider_done
    lda #0
    sta SDIR
    rts

; ============================================================
; helpers
; ============================================================
busy_wait:
    bit BLIT_TRIG
    bmi busy_wait
    rts

wait_frame:
:   bit VIC2_CTRL1
    bpl :-
:   bit VIC2_CTRL1
    bmi :-
    rts

irq_stub:
    rti

; ============================================================
; tables
; ============================================================
barcols:
    .byte $40,$80,$A0,$E0,$E4,$E8,$FC,$BC,$1C,$1D,$1F,$17,$13,$03,$47,$87
linecols:
    .byte $FF,$FC,$1F,$E3,$1C,$E0,$9F,$FD

xspd_tab:
    .repeat NBOBS, I
    .byte ((I .mod 3)+1)
    .endrepeat
yspd_tab:
    .repeat NBOBS, I
    .byte (((I+1) .mod 3)+1)
    .endrepeat
xphase_tab:
    .repeat NBOBS, I
    .byte ((I*89) .mod 256)
    .endrepeat
yphase_tab:
    .repeat NBOBS, I
    .byte ((I*57+13) .mod 256)
    .endrepeat
srcx_tab:
    .repeat NBOBS, I
    .byte ((I .mod 3)*32)
    .endrepeat

; 128 + 127.5*sin(2*pi*k/256), 256 entries
sintab:
    .byte $80,$83,$86,$89,$8C,$8F,$92,$95,$98,$9B,$9E,$A2,$A5,$A7,$AA,$AD
    .byte $B0,$B3,$B6,$B9,$BC,$BE,$C1,$C4,$C6,$C9,$CB,$CE,$D0,$D3,$D5,$D7
    .byte $DA,$DC,$DE,$E0,$E2,$E4,$E6,$E8,$EA,$EB,$ED,$EE,$F0,$F1,$F3,$F4
    .byte $F5,$F6,$F8,$F9,$FA,$FA,$FB,$FC,$FD,$FD,$FE,$FE,$FE,$FF,$FF,$FF
    .byte $FF,$FF,$FF,$FF,$FE,$FE,$FE,$FD,$FD,$FC,$FB,$FA,$FA,$F9,$F8,$F6
    .byte $F5,$F4,$F3,$F1,$F0,$EE,$ED,$EB,$EA,$E8,$E6,$E4,$E2,$E0,$DE,$DC
    .byte $DA,$D7,$D5,$D3,$D0,$CE,$CB,$C9,$C6,$C4,$C1,$BE,$BC,$B9,$B6,$B3
    .byte $B0,$AD,$AA,$A7,$A5,$A2,$9E,$9B,$98,$95,$92,$8F,$8C,$89,$86,$83
    .byte $80,$7C,$79,$76,$73,$70,$6D,$6A,$67,$64,$61,$5D,$5A,$58,$55,$52
    .byte $4F,$4C,$49,$46,$43,$41,$3E,$3B,$39,$36,$34,$31,$2F,$2C,$2A,$28
    .byte $25,$23,$21,$1F,$1D,$1B,$19,$17,$15,$14,$12,$11,$0F,$0E,$0C,$0B
    .byte $0A,$09,$07,$06,$05,$05,$04,$03,$02,$02,$01,$01,$01,$00,$00,$00
    .byte $00,$00,$00,$00,$01,$01,$01,$02,$02,$03,$04,$05,$05,$06,$07,$09
    .byte $0A,$0B,$0C,$0E,$0F,$11,$12,$14,$15,$17,$19,$1B,$1D,$1F,$21,$23
    .byte $25,$28,$2A,$2C,$2F,$31,$34,$36,$39,$3B,$3E,$41,$43,$46,$49,$4C
    .byte $4F,$52,$55,$58,$5A,$5D,$61,$64,$67,$6A,$6D,$70,$73,$76,$79,$7C

.segment "VECTORS"
    .word irq_stub          ; NMI
    .word RESET             ; RESET
    .word irq_stub          ; IRQ/BRK
