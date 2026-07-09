; ============================================================
; Mandelcube demo -- Mandelbrot texture on a rotating 3D cube, 640x400 RGB332.
;
; The 6502 computes a 64x64 Mandelbrot texture with the MUL32 coprocessor and
; stores it in the hidden framebuffer pad at $3E800 (past the visible 256000
; bytes).  Each frame it rotates a real 3D cube (Y spin + fixed X tilt,
; orthographic projection), culls back faces via the screen-space cross
; product, computes the affine texture gradients as the INVERSE of each
; face's 2x2 edge matrix (16384*e/det with a software 24-bit divide; the
; coprocessor supplies the 16x16 products), and fires ONE OP_TEX blit per
; visible face: the face's screen bounding box is filled in UV-CLIP mode
; (FLAGS bit 1), so pixels outside the parallelogram are skipped and the
; blitter rasterizes the rotated face exactly.
;
; Fixed-point pipeline validated bit-exact in
; scratchpad/mandelcube_proto.py before this port.
;
; Build:  make mandelcube-rom
; Upload: roms\6502\upload\mandelcube_rom.bat [COMx]
; ============================================================

VIC_MODE    = $9000
VIC_FB_BANK = $9006
VIC2_CTRL1  = $D011
FB_WIN      = $6000

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
BLIT_TEXIDX = $884A
BLIT_TEXDAT = $884B
BLIT_FBCTL  = $884C
BLIT_TRIG   = $884F

OP_FILL     = 0
OP_TEX      = 4

MUL         = $88B0
MUL_A       = MUL+0
MUL_B       = MUL+4
MUL_RES     = MUL+8
MUL_SHIFT   = MUL+12

TEXTURE     = $3000
TEX_FB_BANK = 31
TEX_FB_WIN  = $6800         ; byte $3E800: hidden 64x64 texture in hi-res FB pad
TEX_BASE0   = $00
TEX_BASE1   = $E8
TEX_BASE2   = $03

; cube/projection constants (see mandelcube_proto.py)
CUBE_S      = 88            ; half edge length in pixels
TILT_SIN    = 56            ; fixed X tilt: sin = 56/128
TILT_COS    = 115           ;               cos = 115/128
CENTER_X    = 320
CENTER_Y    = 200

TEX_W       = 64

X_LEFT      = $FD600000     ; -2.625 in 8.24
CI_START    = $FEC00000     ; -1.25
SX_STEP     = $000F0000     ; 3.75 / 64
SY_STEP     = $000A0000     ; 2.50 / 64
ESCAPE_INT  = $04
MAX_ITER    = 32

; projected vertex arrays (main RAM)
SXL = $0300                 ; screen x low, 8 entries
SXH = $0308                 ; screen x high
SYL = $0310                 ; screen y low
SYH = $0318                 ; screen y high

.segment "ZEROPAGE"
; --- Mandelbrot texture generation (MUL_SHIFT = 24 phase) ---
ZR:       .res 4
ZI:       .res 4
CR:       .res 4
CI:       .res 4
ZR2:      .res 4
ZI2:      .res 4
PROD:     .res 4
SUM:      .res 4
ITER:     .res 1
TEXLO:    .res 1
TEXHI:    .res 1
SRCLO:    .res 1
SRCHI:    .res 1
DSTLO:    .res 1
DSTHI:    .res 1
ROWCNT:   .res 1
COLCNT:   .res 1
; --- animation state ---
PHASE:    .res 1
VI:       .res 1            ; vertex loop index
FACEIX:   .res 1            ; face loop index
; --- 16x16 -> 32 multiply interface (MUL_SHIFT = 0 phase) ---
MA:       .res 2
MB:       .res 2
MR:       .res 4
; --- projection scratch ---
SA16:     .res 2            ; sin(phase), sign-extended
CA16:     .res 2            ; cos(phase)
P24:      .res 3            ; 24-bit accumulator (asr7 input)
ZW:       .res 2            ; rotated Z (for the tilt)
; --- face setup ---
P0X:      .res 2
P0Y:      .res 2
E1X:      .res 2
E1Y:      .res 2
E2X:      .res 2
E2Y:      .res 2
DET:      .res 4            ; e1x*e2y - e1y*e2x (positive after cull)
; --- divide: NUM/Q shares bytes, R = remainder ---
NUM:      .res 3            ; numerator in, quotient out
REM:      .res 3
DIVT:     .res 2
EW:       .res 2            ; gradient input edge value
NEGF:     .res 1            ; negate result flag
GRQ:      .res 2            ; gradient result (signed 8.8)
DUDX:     .res 2
DUDY:     .res 2
DVDX:     .res 2
DVDY:     .res 2
ACC:      .res 4            ; 32-bit accumulator for u0/v0
U0W:      .res 2
V0W:      .res 2
BX0:      .res 2
BX1:      .res 2
BY0:      .res 2
BY1:      .res 2
TXW:      .res 2            ; candidate point for min/max
TYW:      .res 2
DOFF:     .res 2            ; bbox corner offset for u0/v0

.macro LD32I dst, val
    lda #<(val)
    sta dst+0
    lda #>(val)
    sta dst+1
    lda #^(val)
    sta dst+2
    lda #>((val) >> 16)
    sta dst+3
.endmacro

.macro ADD32I dst, val
    clc
    lda dst+0
    adc #<(val)
    sta dst+0
    lda dst+1
    adc #>(val)
    sta dst+1
    lda dst+2
    adc #^(val)
    sta dst+2
    lda dst+3
    adc #>((val) >> 16)
    sta dst+3
.endmacro

.macro ZERO32 dst
    lda #0
    sta dst+0
    sta dst+1
    sta dst+2
    sta dst+3
.endmacro

.macro MUL32 opA, opB, dst
    lda opA+0
    sta MUL_A+0
    lda opA+1
    sta MUL_A+1
    lda opA+2
    sta MUL_A+2
    lda opA+3
    sta MUL_A+3
    lda opB+0
    sta MUL_B+0
    lda opB+1
    sta MUL_B+1
    lda opB+2
    sta MUL_B+2
    lda opB+3
    sta MUL_B+3
    lda MUL_RES+0
    sta dst+0
    lda MUL_RES+1
    sta dst+1
    lda MUL_RES+2
    sta dst+2
    lda MUL_RES+3
    sta dst+3
.endmacro

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

.segment "CODE"
RESET:
    sei
    cld
    ldx #$FF
    txs

    ; Prefer the calibrated DDR3 blitter backend when present.
    lda #$00
    sta BLIT_FBCTL
    lda BLIT_FBCTL
    bpl @backend_done
    lda #$01
    sta BLIT_FBCTL
@backend_done:

    lda #$20
    sta VIC_MODE
    lda #0
    sta VIC_FB_BANK

    MFILL 0, 0, 639, 399, $00

    lda #24
    sta MUL_SHIFT           ; 8.24 for the Mandelbrot iteration
    jsr generate_texture
    jsr upload_texture_to_fb
    lda #0
    sta MUL_SHIFT           ; raw 32-bit products for the 3D pipeline

    lda #0
    sta PHASE
main_loop:
    jsr wait_frame
    ; clear only the cube region (full-screen fills would halve the framerate)
    MFILL 136, 40, 504, 360, $00
    jsr project_vertices
    lda #0
    sta FACEIX
@face_loop:
    jsr draw_face
    inc FACEIX
    lda FACEIX
    cmp #6
    bne @face_loop
    inc PHASE
    inc PHASE
    jmp main_loop

; ------------------------------------------------------------
; 16x16 signed multiply via the coprocessor: MR = MA * MB.
; ------------------------------------------------------------
mul16s:
    lda MA+0
    sta MUL_A+0
    ldx #0
    lda MA+1
    sta MUL_A+1
    bpl :+
    ldx #$FF
:   stx MUL_A+2
    stx MUL_A+3
    lda MB+0
    sta MUL_B+0
    ldx #0
    lda MB+1
    sta MUL_B+1
    bpl :+
    ldx #$FF
:   stx MUL_B+2
    stx MUL_B+3
    lda MUL_RES+0
    sta MR+0
    lda MUL_RES+1
    sta MR+1
    lda MUL_RES+2
    sta MR+2
    lda MUL_RES+3
    sta MR+3
    rts

; arithmetic shift right by 7 of the 24-bit accumulator P24
asr7_p24:
    ldx #7
@l: lda P24+2
    asl
    ror P24+2
    ror P24+1
    ror P24+0
    dex
    bne @l
    rts

; ------------------------------------------------------------
; Project the 8 cube vertices:
;   X  = (vx*ca + vz*sa) >> 7            (rotation about Y)
;   Z  = (vz*ca - vx*sa) >> 7
;   Y2 = (vy*TILT_COS - Z*TILT_SIN) >> 7 (fixed tilt about X)
;   SX = 320 + X, SY = 200 + Y2
; ------------------------------------------------------------
project_vertices:
    ; NOTE: ldx must come BEFORE the sbc -- ldx #0 sets N and would make the
    ; bpl always taken (sign extension silently lost for negative sin/cos;
    ; that bug blew the cube up as soon as cos went negative at phase 64).
    ldx #0
    ldy PHASE
    lda sintab,y
    sec
    sbc #128                ; signed sin in [-128,127]
    sta SA16+0
    bpl :+
    ldx #$FF
:   stx SA16+1
    ldx #0
    lda PHASE
    clc
    adc #64
    tay
    lda sintab,y
    sec
    sbc #128
    sta CA16+0
    bpl :+
    ldx #$FF
:   stx CA16+1

    lda #0
    sta VI
@vloop:
    ldx VI
    ; --- X = asr7(vx*ca + vz*sa), SX = 320 + X ---
    lda vertx_lo,x
    sta MA+0
    lda vertx_hi,x
    sta MA+1
    lda CA16+0
    sta MB+0
    lda CA16+1
    sta MB+1
    jsr mul16s
    lda MR+0
    sta P24+0
    lda MR+1
    sta P24+1
    lda MR+2
    sta P24+2
    ldx VI
    lda vertz_lo,x
    sta MA+0
    lda vertz_hi,x
    sta MA+1
    lda SA16+0
    sta MB+0
    lda SA16+1
    sta MB+1
    jsr mul16s
    clc
    lda P24+0
    adc MR+0
    sta P24+0
    lda P24+1
    adc MR+1
    sta P24+1
    lda P24+2
    adc MR+2
    sta P24+2
    jsr asr7_p24
    clc
    lda P24+0
    adc #<CENTER_X
    tay                     ; SX low
    lda P24+1
    adc #>CENTER_X
    ldx VI
    sta SXH,x
    tya
    sta SXL,x

    ; --- Z = asr7(vz*ca - vx*sa) ---
    ldx VI
    lda vertz_lo,x
    sta MA+0
    lda vertz_hi,x
    sta MA+1
    lda CA16+0
    sta MB+0
    lda CA16+1
    sta MB+1
    jsr mul16s
    lda MR+0
    sta P24+0
    lda MR+1
    sta P24+1
    lda MR+2
    sta P24+2
    ldx VI
    lda vertx_lo,x
    sta MA+0
    lda vertx_hi,x
    sta MA+1
    lda SA16+0
    sta MB+0
    lda SA16+1
    sta MB+1
    jsr mul16s
    sec
    lda P24+0
    sbc MR+0
    sta P24+0
    lda P24+1
    sbc MR+1
    sta P24+1
    lda P24+2
    sbc MR+2
    sta P24+2
    jsr asr7_p24
    lda P24+0
    sta ZW+0
    lda P24+1
    sta ZW+1

    ; --- Y2 = asr7(vy*TILT_COS - Z*TILT_SIN), SY = 200 + Y2 ---
    ldx VI
    lda vycb_lo,x           ; vy*TILT_COS precomputed (+/-10120)
    sta P24+0
    lda vycb_hi,x
    sta P24+1
    bpl :+                  ; sign-extend the 16-bit table value to 24 bits
    lda #$FF
    bne :++
:   lda #0
:   sta P24+2
    lda ZW+0
    sta MA+0
    lda ZW+1
    sta MA+1
    lda #TILT_SIN
    sta MB+0
    lda #0
    sta MB+1
    jsr mul16s
    sec
    lda P24+0
    sbc MR+0
    sta P24+0
    lda P24+1
    sbc MR+1
    sta P24+1
    lda P24+2
    sbc MR+2
    sta P24+2
    jsr asr7_p24
    clc
    lda P24+0
    adc #<CENTER_Y
    tay
    lda P24+1
    adc #>CENTER_Y
    ldx VI
    sta SYH,x
    tya
    sta SYL,x

    inc VI
    lda VI
    cmp #8
    beq @done
    jmp @vloop
@done:
    rts

; ------------------------------------------------------------
; Draw one cube face (FACEIX): cull, gradients, bbox, OP_TEX.
; ------------------------------------------------------------
draw_face:
    ; fetch P0 and edge vectors E1 = Pu-P0, E2 = Pv-P0 (screen space)
    ldy FACEIX
    lda fp0,y
    tax
    lda SXL,x
    sta P0X+0
    lda SXH,x
    sta P0X+1
    lda SYL,x
    sta P0Y+0
    lda SYH,x
    sta P0Y+1

    ldy FACEIX
    lda fpu,y
    tax
    sec
    lda SXL,x
    sbc P0X+0
    sta E1X+0
    lda SXH,x
    sbc P0X+1
    sta E1X+1
    sec
    lda SYL,x
    sbc P0Y+0
    sta E1Y+0
    lda SYH,x
    sbc P0Y+1
    sta E1Y+1

    ldy FACEIX
    lda fpv,y
    tax
    sec
    lda SXL,x
    sbc P0X+0
    sta E2X+0
    lda SXH,x
    sbc P0X+1
    sta E2X+1
    sec
    lda SYL,x
    sbc P0Y+0
    sta E2Y+0
    lda SYH,x
    sbc P0Y+1
    sta E2Y+1

    ; --- det = e1x*e2y - e1y*e2x ---
    lda E1X+0
    sta MA+0
    lda E1X+1
    sta MA+1
    lda E2Y+0
    sta MB+0
    lda E2Y+1
    sta MB+1
    jsr mul16s
    lda MR+0
    sta DET+0
    lda MR+1
    sta DET+1
    lda MR+2
    sta DET+2
    lda MR+3
    sta DET+3
    lda E1Y+0
    sta MA+0
    lda E1Y+1
    sta MA+1
    lda E2X+0
    sta MB+0
    lda E2X+1
    sta MB+1
    jsr mul16s
    sec
    lda DET+0
    sbc MR+0
    sta DET+0
    lda DET+1
    sbc MR+1
    sta DET+1
    lda DET+2
    sbc MR+2
    sta DET+2
    lda DET+3
    sbc MR+3
    sta DET+3

    ; --- cull: draw only when det >= ~1280 (backface or edge-on otherwise) ---
    lda DET+3
    bmi @cull
    lda DET+2
    bne @visible
    lda DET+1
    cmp #5
    bcs @visible
@cull:
    rts

@visible:
    ; --- gradients: 16384 * e / det, signs per the affine inverse ---
    lda E2Y+0
    sta EW+0
    lda E2Y+1
    sta EW+1
    lda #0
    sta NEGF
    jsr grad_from_e
    lda GRQ+0
    sta DUDX+0
    lda GRQ+1
    sta DUDX+1

    lda E2X+0
    sta EW+0
    lda E2X+1
    sta EW+1
    lda #1
    sta NEGF
    jsr grad_from_e
    lda GRQ+0
    sta DUDY+0
    lda GRQ+1
    sta DUDY+1

    lda E1Y+0
    sta EW+0
    lda E1Y+1
    sta EW+1
    lda #1
    sta NEGF
    jsr grad_from_e
    lda GRQ+0
    sta DVDX+0
    lda GRQ+1
    sta DVDX+1

    lda E1X+0
    sta EW+0
    lda E1X+1
    sta EW+1
    lda #0
    sta NEGF
    jsr grad_from_e
    lda GRQ+0
    sta DVDY+0
    lda GRQ+1
    sta DVDY+1

    ; --- screen bounding box over P0, P0+E1, P0+E2, P0+E1+E2 ---
    lda P0X+0
    sta BX0+0
    sta BX1+0
    lda P0X+1
    sta BX0+1
    sta BX1+1
    lda P0Y+0
    sta BY0+0
    sta BY1+0
    lda P0Y+1
    sta BY0+1
    sta BY1+1

    clc                     ; P0+E1
    lda P0X+0
    adc E1X+0
    sta TXW+0
    lda P0X+1
    adc E1X+1
    sta TXW+1
    clc
    lda P0Y+0
    adc E1Y+0
    sta TYW+0
    lda P0Y+1
    adc E1Y+1
    sta TYW+1
    jsr bbox_update

    clc                     ; P0+E2
    lda P0X+0
    adc E2X+0
    sta TXW+0
    lda P0X+1
    adc E2X+1
    sta TXW+1
    clc
    lda P0Y+0
    adc E2Y+0
    sta TYW+0
    lda P0Y+1
    adc E2Y+1
    sta TYW+1
    jsr bbox_update

    clc                     ; P0+E1+E2
    lda TXW+0
    adc E1X+0
    sta TXW+0
    lda TXW+1
    adc E1X+1
    sta TXW+1
    clc
    lda TYW+0
    adc E1Y+0
    sta TYW+0
    lda TYW+1
    adc E1Y+1
    sta TYW+1
    jsr bbox_update

    ; --- u0/v0 anchored at the bbox top-left corner ---
    sec                     ; DOFF = BX0 - P0X (<= 0)
    lda BX0+0
    sbc P0X+0
    sta DOFF+0
    lda BX0+1
    sbc P0X+1
    sta DOFF+1
    lda DUDX+0
    sta MA+0
    lda DUDX+1
    sta MA+1
    lda DOFF+0
    sta MB+0
    lda DOFF+1
    sta MB+1
    jsr mul16s
    lda MR+0
    sta ACC+0
    lda MR+1
    sta ACC+1
    lda DVDX+0
    sta MA+0
    lda DVDX+1
    sta MA+1
    jsr mul16s              ; MB still = DOFF
    lda MR+0
    sta V0W+0
    lda MR+1
    sta V0W+1

    sec                     ; DOFF = BY0 - P0Y
    lda BY0+0
    sbc P0Y+0
    sta DOFF+0
    lda BY0+1
    sbc P0Y+1
    sta DOFF+1
    lda DUDY+0
    sta MA+0
    lda DUDY+1
    sta MA+1
    lda DOFF+0
    sta MB+0
    lda DOFF+1
    sta MB+1
    jsr mul16s
    clc
    lda ACC+0
    adc MR+0
    sta U0W+0
    lda ACC+1
    adc MR+1
    sta U0W+1
    lda DVDY+0
    sta MA+0
    lda DVDY+1
    sta MA+1
    jsr mul16s              ; MB still = BY0-P0Y
    clc
    lda V0W+0
    adc MR+0
    sta V0W+0
    lda V0W+1
    adc MR+1
    sta V0W+1

    ; --- program the texture parameter bank ---
    lda #0
    sta BLIT_TEXIDX
    lda #TEX_BASE0
    sta BLIT_TEXDAT
    lda #TEX_BASE1
    sta BLIT_TEXDAT
    lda #TEX_BASE2
    sta BLIT_TEXDAT
    lda U0W+0
    sta BLIT_TEXDAT
    lda U0W+1
    sta BLIT_TEXDAT
    lda V0W+0
    sta BLIT_TEXDAT
    lda V0W+1
    sta BLIT_TEXDAT
    lda DUDX+0
    sta BLIT_TEXDAT
    lda DUDX+1
    sta BLIT_TEXDAT
    lda DVDX+0
    sta BLIT_TEXDAT
    lda DVDX+1
    sta BLIT_TEXDAT
    lda DUDY+0
    sta BLIT_TEXDAT
    lda DUDY+1
    sta BLIT_TEXDAT
    lda DVDY+0
    sta BLIT_TEXDAT
    lda DVDY+1
    sta BLIT_TEXDAT
    lda #$02                ; FLAGS: UV clip (rasterize the parallelogram)
    sta BLIT_TEXDAT

    ; --- destination rect = bbox, fire OP_TEX ---
    lda BX0+0
    sta BLIT_X0LO
    lda BX0+1
    sta BLIT_X0HI
    lda BY0+0
    sta BLIT_Y0LO
    lda BY0+1
    sta BLIT_Y0HI
    lda BX1+0
    sta BLIT_X1LO
    lda BX1+1
    sta BLIT_X1HI
    lda BY1+0
    sta BLIT_Y1LO
    lda BY1+1
    sta BLIT_Y1HI
    lda #OP_TEX
    sta BLIT_OP
    sta BLIT_TRIG
    jmp busy_wait

; update BX0/BX1/BY0/BY1 with candidate point (TXW, TYW); all screen
; coordinates are positive, unsigned 16-bit compares suffice
bbox_update:
    lda TXW+1
    cmp BX0+1
    bcc @xmin
    bne @xmax_chk
    lda TXW+0
    cmp BX0+0
    bcs @xmax_chk
@xmin:
    lda TXW+0
    sta BX0+0
    lda TXW+1
    sta BX0+1
@xmax_chk:
    lda TXW+1
    cmp BX1+1
    bcc @ycheck
    bne @xmax
    lda TXW+0
    cmp BX1+0
    bcc @ycheck
    beq @ycheck
@xmax:
    lda TXW+0
    sta BX1+0
    lda TXW+1
    sta BX1+1
@ycheck:
    lda TYW+1
    cmp BY0+1
    bcc @ymin
    bne @ymax_chk
    lda TYW+0
    cmp BY0+0
    bcs @ymax_chk
@ymin:
    lda TYW+0
    sta BY0+0
    lda TYW+1
    sta BY0+1
@ymax_chk:
    lda TYW+1
    cmp BY1+1
    bcc @done
    bne @ymax
    lda TYW+0
    cmp BY1+0
    bcc @done
    beq @done
@ymax:
    lda TYW+0
    sta BY1+0
    lda TYW+1
    sta BY1+1
@done:
    rts

; ------------------------------------------------------------
; GRQ = sign * (16384 * |EW|) / DET, sign = sign(EW) xor NEGF.
; DET is positive (cull guarantees it) and <= ~260000 (24 bit).
; ------------------------------------------------------------
grad_from_e:
    lda EW+1
    bpl @pos
    ; abs
    sec
    lda #0
    sbc EW+0
    sta EW+0
    lda #0
    sbc EW+1
    sta EW+1
    lda NEGF
    eor #1
    sta NEGF
@pos:
    ; NUM = |EW| << 14  (|EW| <= 511): N1 = (|EW| & 3) << 6, N2 = |EW| >> 2
    lda EW+0
    and #$03
    asl
    asl
    asl
    asl
    asl
    asl
    sta NUM+1
    ; N2 = |EW| >> 2 (9-bit value)
    lda EW+1
    lsr                     ; bit8 -> carry
    lda EW+0
    ror
    lsr
    sta NUM+2
    lda #0
    sta NUM+0

    ; 24-bit divide: NUM = NUM / DET(2..0), remainder in REM
    lda #0
    sta REM+0
    sta REM+1
    sta REM+2
    ldx #24
@dl:
    asl NUM+0
    rol NUM+1
    rol NUM+2
    rol REM+0
    rol REM+1
    rol REM+2
    sec
    lda REM+0
    sbc DET+0
    sta DIVT+0
    lda REM+1
    sbc DET+1
    sta DIVT+1
    lda REM+2
    sbc DET+2
    bcc @no_sub
    sta REM+2
    lda DIVT+1
    sta REM+1
    lda DIVT+0
    sta REM+0
    inc NUM+0
@no_sub:
    dex
    bne @dl

    lda NEGF
    beq @store_pos
    sec
    lda #0
    sbc NUM+0
    sta GRQ+0
    lda #0
    sbc NUM+1
    sta GRQ+1
    rts
@store_pos:
    lda NUM+0
    sta GRQ+0
    lda NUM+1
    sta GRQ+1
    rts

; ------------------------------------------------------------
; 64x64 Mandelbrot texture generator, output at TEXTURE (MUL_SHIFT=24).
; ------------------------------------------------------------
generate_texture:
    lda #<TEXTURE
    sta TEXLO
    lda #>TEXTURE
    sta TEXHI
    LD32I CI, CI_START
    lda #TEX_W
    sta ROWCNT
@row:
    LD32I CR, X_LEFT
    lda #TEX_W
    sta COLCNT
@pixel:
    ZERO32 ZR
    ZERO32 ZI
    lda #MAX_ITER
    sta ITER
@iter:
    MUL32 ZR, ZR, ZR2
    MUL32 ZI, ZI, ZI2

    clc
    lda ZR2+0
    adc ZI2+0
    sta SUM+0
    lda ZR2+1
    adc ZI2+1
    sta SUM+1
    lda ZR2+2
    adc ZI2+2
    sta SUM+2
    lda ZR2+3
    adc ZI2+3
    sta SUM+3
    bpl @sum_pos
    jmp @escaped
@sum_pos:
    lda SUM+3
    cmp #ESCAPE_INT
    bcc @inside
    jmp @escaped

@inside:
    MUL32 ZR, ZI, PROD
    asl PROD+0
    rol PROD+1
    rol PROD+2
    rol PROD+3
    clc
    lda PROD+0
    adc CI+0
    sta ZI+0
    lda PROD+1
    adc CI+1
    sta ZI+1
    lda PROD+2
    adc CI+2
    sta ZI+2
    lda PROD+3
    adc CI+3
    sta ZI+3

    sec
    lda ZR2+0
    sbc ZI2+0
    sta ZR+0
    lda ZR2+1
    sbc ZI2+1
    sta ZR+1
    lda ZR2+2
    sbc ZI2+2
    sta ZR+2
    lda ZR2+3
    sbc ZI2+3
    sta ZR+3
    clc
    lda ZR+0
    adc CR+0
    sta ZR+0
    lda ZR+1
    adc CR+1
    sta ZR+1
    lda ZR+2
    adc CR+2
    sta ZR+2
    lda ZR+3
    adc CR+3
    sta ZR+3

    dec ITER
    beq @no_escape
    jmp @iter

@no_escape:
    lda #$01                ; interior: near-black blue (NOT $00 -- that would
    jmp @plot               ; be clipped/transparent in COPYT experiments)
@escaped:
    lda #MAX_ITER
    sec
    sbc ITER
    tax
    lda color_table,x
@plot:
    ldy #0
    sta (TEXLO),y
    inc TEXLO
    bne @tex_ok
    inc TEXHI
@tex_ok:
    ADD32I CR, SX_STEP
    dec COLCNT
    beq @row_done
    jmp @pixel
@row_done:
    ADD32I CI, SY_STEP
    dec ROWCNT
    beq @done
    jmp @row
@done:
    rts

upload_texture_to_fb:
    lda #TEX_FB_BANK
    sta VIC_FB_BANK
    lda #<TEXTURE
    sta SRCLO
    lda #>TEXTURE
    sta SRCHI
    lda #<TEX_FB_WIN
    sta DSTLO
    lda #>TEX_FB_WIN
    sta DSTHI
    lda #16                 ; 16 * 256 = 4096 bytes
    sta ROWCNT
    ldy #0
@page:
    lda (SRCLO),y
    sta (DSTLO),y
    iny
    bne @page
    inc SRCHI
    inc DSTHI
    dec ROWCNT
    bne @page
    lda #0
    sta VIC_FB_BANK
    rts

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

.segment "RODATA"
color_table:
    .byte $40,$80,$A0,$E0,$E4,$E8,$FC,$BC
    .byte $1C,$1D,$1F,$17,$13,$03,$47,$87
    .byte $8B,$CF,$EF,$FB,$DB,$9B,$5B,$1B
    .byte $2F,$6F,$AF,$F3,$F7,$FF,$B6,$6D

; cube vertices, 16-bit signed +/-CUBE_S:
;   0=(-,-,-) 1=(+,-,-) 2=(+,+,-) 3=(-,+,-)
;   4=(-,-,+) 5=(+,-,+) 6=(+,+,+) 7=(-,+,+)
vertx_lo: .byte <(-CUBE_S), <CUBE_S, <CUBE_S, <(-CUBE_S), <(-CUBE_S), <CUBE_S, <CUBE_S, <(-CUBE_S)
vertx_hi: .byte >(-CUBE_S), >CUBE_S, >CUBE_S, >(-CUBE_S), >(-CUBE_S), >CUBE_S, >CUBE_S, >(-CUBE_S)
vertz_lo: .byte <(-CUBE_S), <(-CUBE_S), <(-CUBE_S), <(-CUBE_S), <CUBE_S, <CUBE_S, <CUBE_S, <CUBE_S
vertz_hi: .byte >(-CUBE_S), >(-CUBE_S), >(-CUBE_S), >(-CUBE_S), >CUBE_S, >CUBE_S, >CUBE_S, >CUBE_S
; vy*TILT_COS precomputed: y = -CUBE_S -> -10120, y = +CUBE_S -> +10120
vycb_lo:  .byte <(-CUBE_S*TILT_COS), <(-CUBE_S*TILT_COS), <(CUBE_S*TILT_COS), <(CUBE_S*TILT_COS)
          .byte <(-CUBE_S*TILT_COS), <(-CUBE_S*TILT_COS), <(CUBE_S*TILT_COS), <(CUBE_S*TILT_COS)
vycb_hi:  .byte >(-CUBE_S*TILT_COS), >(-CUBE_S*TILT_COS), >(CUBE_S*TILT_COS), >(CUBE_S*TILT_COS)
          .byte >(-CUBE_S*TILT_COS), >(-CUBE_S*TILT_COS), >(CUBE_S*TILT_COS), >(CUBE_S*TILT_COS)

; faces as (P0, Pu, Pv) vertex indices, outward winding (see prototype)
fp0: .byte 0, 5, 1, 4, 4, 3
fpu: .byte 1, 4, 5, 0, 5, 2
fpv: .byte 3, 6, 2, 7, 0, 7

; 128 + 127.5*sin(2*pi*k/256), 256 entries
sintab:
    .byte $80,$83,$86,$89,$8C,$8F,$92,$95,$98,$9B,$9E,$A2,$A5,$A7,$AA,$AD
    .byte $B0,$B3,$B6,$B9,$BC,$BE,$C1,$C4,$C6,$C9,$CB,$CE,$D0,$D3,$D5,$D7
    .byte $DA,$DC,$DE,$E0,$E2,$E4,$E6,$E8,$EA,$EC,$ED,$EF,$F1,$F2,$F4,$F5
    .byte $F6,$F7,$F9,$FA,$FB,$FC,$FC,$FD,$FE,$FE,$FF,$FF,$FF,$FF,$FF,$FF
    .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FE,$FE,$FD,$FC,$FC,$FB,$FA,$F9,$F7
    .byte $F6,$F5,$F4,$F2,$F1,$EF,$ED,$EC,$EA,$E8,$E6,$E4,$E2,$E0,$DE,$DC
    .byte $DA,$D7,$D5,$D3,$D0,$CE,$CB,$C9,$C6,$C4,$C1,$BE,$BC,$B9,$B6,$B3
    .byte $B0,$AD,$AA,$A7,$A5,$A2,$9E,$9B,$98,$95,$92,$8F,$8C,$89,$86,$83
    .byte $80,$7D,$7A,$77,$74,$71,$6E,$6B,$68,$65,$62,$5E,$5B,$59,$56,$53
    .byte $50,$4D,$4A,$47,$44,$42,$3F,$3C,$3A,$37,$35,$32,$30,$2D,$2B,$29
    .byte $26,$24,$22,$20,$1E,$1C,$1A,$18,$16,$14,$13,$11,$0F,$0E,$0C,$0B
    .byte $0A,$09,$07,$06,$05,$04,$04,$03,$02,$02,$01,$01,$01,$01,$01,$01
    .byte $01,$01,$01,$01,$01,$01,$01,$02,$02,$03,$04,$04,$05,$06,$07,$09
    .byte $0A,$0B,$0C,$0E,$0F,$11,$13,$14,$16,$18,$1A,$1C,$1E,$20,$22,$24
    .byte $26,$29,$2B,$2D,$30,$32,$35,$37,$3A,$3C,$3F,$42,$44,$47,$4A,$4D
    .byte $50,$53,$56,$59,$5B,$5E,$62,$65,$68,$6B,$6E,$71,$74,$77,$7A,$7D

.segment "VECTORS"
    .word irq_stub
    .word RESET
    .word irq_stub
