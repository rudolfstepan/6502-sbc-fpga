; disk.s — D64 GoDrive low-level + directory + PRG loader routines.
;
; Read-only Version 1 API for the FPGA D64 drive (see disk.inc, docs/D64_DRIVE.md).
; Designed to be reused by test ROMs and the kernel; include disk.inc first.
;
; Zero-page scratch this module owns (see ZEROPAGE segment below):
;   dsk_ptr      2  general 16-bit pointer (filename / copy target)
;   dsk_dst      2  PRG load destination pointer
;   dsk_blocks   2  file-chain block guard counter
;   dsk_tmp      1  scratch
;   dsk_entry   32  current directory entry copy (type/track/sector/name/size)
;   dsk_end      2  PRG end address (last byte written + 1)
;
; Conventions: carry clear = success, carry set = failure. On failure the cause
; is in DISK_RESULT or a routine-specific code; see each routine.

.include "disk.inc"

.exportzp dsk_ptr, dsk_dst, dsk_blocks, dsk_tmp
.export   dsk_entry, dsk_end, dsk_start

.segment "ZEROPAGE"
dsk_ptr:    .res 2
dsk_dst:    .res 2
dsk_blocks: .res 2
dsk_tmp:    .res 1

.segment "BSS"
dsk_entry:  .res 32         ; copy of the current directory entry
dsk_start:  .res 2          ; PRG load start address (embedded load address)
dsk_end:    .res 2          ; PRG load end address (last byte written + 1)

.segment "CODE"

; ── disk_reset: clear controller state (keeps any mounted image) ────────────
.export disk_reset
disk_reset:
    lda #CMD_RESET
    sta DISK_COMMAND
    jmp disk_wait_ready

; ── disk_wait_ready: spin until BUSY clears ─────────────────────────────────
; Clobbers A.
.export disk_wait_ready
disk_wait_ready:
@wait:
    lda DISK_STATUS
    and #STATUS_BUSY
    bne @wait
    rts

; ── disk_is_mounted: carry clear if mounted, set if not ─────────────────────
.export disk_is_mounted
disk_is_mounted:
    lda DISK_STATUS
    and #STATUS_MOUNTED
    beq @no
    clc
    rts
@no:
    sec
    rts

; ── disk_mount: scan FAT32 + mount the first .d64 ───────────────────────────
; Output: carry clear on success (image mounted), carry set on failure.
;         DISK_RESULT holds the cause on failure.
.export disk_mount
disk_mount:
    lda #CMD_MOUNT
    sta DISK_COMMAND
    jsr disk_wait_ready
    lda DISK_STATUS
    and #STATUS_ERROR
    bne @err
    ; confirm MOUNTED actually set
    jsr disk_is_mounted
    bcs @err
    clc
    rts
@err:
    sec
    rts

; ── disk_read_sector: read D64 (A=track, X=sector) into the buffer ──────────
; Output: carry clear on success, carry set on error (DISK_RESULT has cause).
;         The 256-byte sector is then available via the DATA port (pointer 0).
.export disk_read_sector
disk_read_sector:
    sta DISK_TRACK
    stx DISK_SECTOR
    lda #CMD_READ_SECTOR
    sta DISK_COMMAND
    jsr disk_wait_ready
    lda DISK_STATUS
    and #STATUS_ERROR
    bne @err
    clc
    rts
@err:
    sec
    rts

; ── disk_copy_buffer: copy the 256-byte sector buffer to (dsk_ptr) ──────────
; Input: dsk_ptr = destination (256 bytes). Resets the buffer pointer first.
; Clobbers A, Y.
.export disk_copy_buffer
disk_copy_buffer:
    lda #0
    sta DISK_PTR_LO        ; rewind buffer pointer
    ldy #0
@loop:
    lda DISK_DATA          ; auto-increments the pointer
    sta (dsk_ptr),y
    iny
    bne @loop
    rts

; ── disk_seek_buffer: set the buffer read pointer to A ──────────────────────
.export disk_seek_buffer
disk_seek_buffer:
    sta DISK_PTR_LO
    rts

; ── disk_raw_read / disk_raw_read_hi: debug — read one 256-byte half of a raw
;    card LBA into the buffer (DATA port).
; Input: A=LBA byte0 (LSB), X=LBA byte1, Y=LBA byte2. LBA byte3 forced 0
;        (cards used here are well under 16M sectors).
;   disk_raw_read    -> lower half (block bytes 0..255)
;   disk_raw_read_hi -> upper half (block bytes 256..511)
; Output: carry clear on success.
.export disk_raw_read, disk_raw_read_hi
disk_raw_read:
    pha
    lda #0
    sta DISK_TRACK         ; half-select = lower
    pla
    jmp raw_go
disk_raw_read_hi:
    pha
    lda #1
    sta DISK_TRACK         ; half-select = upper
    pla
raw_go:
    sta DISK_RAW_LBA0
    stx DISK_RAW_LBA1
    sty DISK_RAW_LBA2
    lda #0
    sta DISK_RAW_LBA3
    lda #CMD_RAW_READ
    sta DISK_COMMAND
    jsr disk_wait_ready
    clc
    rts

; ────────────────────────────────────────────────────────────────────────────
;  Directory reader
; ────────────────────────────────────────────────────────────────────────────
.segment "BSS"
dir_track:  .res 1          ; current directory sector track
dir_sector: .res 1          ; current directory sector
dir_index:  .res 1          ; next entry index within the sector (0..7)

.segment "CODE"

; ── disk_dir_open: start a directory walk at T18/S1 ─────────────────────────
; Reads the first directory sector. Carry set on read error.
.export disk_dir_open
disk_dir_open:
    lda #DIR_TRACK
    sta dir_track
    lda #DIR_FIRST_SECTOR
    sta dir_sector
    lda #0
    sta dir_index
    lda dir_track
    ldx dir_sector
    jsr disk_read_sector
    rts                     ; carry from read_sector

; ── disk_dir_next: fetch the next non-deleted entry into dsk_entry ──────────
; Output: carry clear -> dsk_entry holds a valid entry (type/track/sector/name).
;         carry set   -> no more entries (end of chain) or a read error.
; Follows the directory-sector chain across sectors.
.export disk_dir_next
disk_dir_next:
@scan:
    lda dir_index
    cmp #8
    bcc @have_slot
    ; sector exhausted: follow chain (next track/sector at buffer bytes 0,1)
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; next track (buffer[0])
    sta dsk_tmp
    lda DISK_DATA          ; next sector (buffer[1])
    tax
    lda dsk_tmp
    beq @end               ; next track 0 -> end of directory
    sta dir_track
    stx dir_sector
    ; X already = next sector; A = next track
    jsr disk_read_sector
    bcs @end               ; read error -> stop
    lda #0
    sta dir_index
    jmp @scan
@have_slot:
    ; compute buffer offset of this entry: 2 + index*32
    lda dir_index
    asl
    asl
    asl
    asl
    asl                     ; index * 32
    clc
    adc #2                  ; skip next-track/next-sector header
    sta DISK_PTR_LO
    ; copy 32 bytes into dsk_entry
    ldy #0
@copy:
    lda DISK_DATA
    sta dsk_entry,y
    iny
    cpy #32
    bne @copy
    inc dir_index
    ; skip deleted entries (type byte == 0)
    lda dsk_entry+DE_TYPE
    beq @scan
    clc
    rts
@end:
    sec
    rts

; ── disk_entry_is_prg: carry clear if dsk_entry is a (closed) PRG ───────────
.export disk_entry_is_prg
disk_entry_is_prg:
    lda dsk_entry+DE_TYPE
    and #FT_TYPE_MASK
    cmp #FT_PRG
    bne @no
    clc
    rts
@no:
    sec
    rts

; ── disk_find_prg: find a PRG by name -> dsk_entry ──────────────────────────
; Input: dsk_ptr = pointer to a name (uppercase ASCII, up to 16 chars, the
;        comparison stops at the first $00 in the search name and treats the
;        rest of the D64 name field as padding).
; Output: carry clear -> dsk_entry is the match; carry set -> not found.
.export disk_find_prg
disk_find_prg:
    jsr disk_dir_open
    bcs @nf
@next:
    jsr disk_dir_next
    bcs @nf
    jsr disk_entry_is_prg
    bcs @next
    jsr cmp_name
    bcs @next
    clc
    rts
@nf:
    sec
    rts

; cmp_name: compare (dsk_ptr) against dsk_entry+DE_NAME.
; Match rule: compare until the search name's terminating $00; the D64 name byte
; must equal the search byte. Carry clear if equal so far AND the D64 name's next
; byte is $A0 (pad) or end. Carry set on mismatch. Clobbers A, Y.
cmp_name:
    ldy #0
@loop:
    lda (dsk_ptr),y
    beq @name_end          ; end of search name
    cmp dsk_entry+DE_NAME,y
    bne @mismatch
    iny
    cpy #16
    bne @loop
    ; matched all 16 chars
    clc
    rts
@name_end:
    ; search name ended; the D64 name must end here too ($A0 pad or 16 chars)
    cpy #16
    beq @ok
    lda dsk_entry+DE_NAME,y
    cmp #$A0
    bne @mismatch
@ok:
    clc
    rts
@mismatch:
    sec
    rts

; ────────────────────────────────────────────────────────────────────────────
;  PRG loader
; ────────────────────────────────────────────────────────────────────────────
.segment "BSS"
ld_track:   .res 1          ; track of the block to read next
ld_sector:  .res 1          ; sector of the block to read next
ld_count:   .res 1          ; payload bytes to copy from the current block

.segment "CODE"

; ── disk_load_prg_from_ts: load a PRG file chain starting at A=track, X=sector
; Input: A=first track, X=first sector.
; Behaviour: reads the first block, takes the embedded load address from
;   buffer[2..3], copies the payload there, follows the chain, and honours the
;   last block's byte count. On success dsk_start = load addr, dsk_end = end+1.
; Output: carry clear on success; carry set on error (DISK_RESULT / bad chain).
.export disk_load_prg_from_ts
disk_load_prg_from_ts:
    sta ld_track
    stx ld_sector
    lda #<683              ; block guard
    sta dsk_blocks
    lda #>683
    sta dsk_blocks+1

    ; ── first block ────────────────────────────────────────────────────────
    lda ld_track
    ldx ld_sector
    jsr disk_read_sector
    bcc @fb_ok
    jmp @err
@fb_ok:

    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; buffer[0] next track
    sta ld_track
    lda DISK_DATA          ; buffer[1] next sector (or last-index if last block)
    sta ld_sector
    lda DISK_DATA          ; buffer[2] load addr lo
    sta dsk_dst
    sta dsk_start          ; keep the original load (start) address
    lda DISK_DATA          ; buffer[3] load addr hi
    sta dsk_dst+1
    sta dsk_start+1

    ; payload of the first block starts at buffer[4]
    lda ld_track
    bne @first_full
    ; single-block file: last valid index = ld_sector; count = ld_sector - 3
    lda ld_sector
    sec
    sbc #3
    sta ld_count
    lda #4
    sta DISK_PTR_LO
    jsr copy_payload
    jmp @done
@first_full:
    lda #252               ; buffer[4..255]
    sta ld_count
    lda #4
    sta DISK_PTR_LO
    jsr copy_payload

    ; ── following blocks ─────────────────────────────────────────────────────
@chain:
    ; guard against runaway chains
    lda dsk_blocks
    bne @dec
    lda dsk_blocks+1
    bne @dec2
    jmp @err               ; counter hit 0 -> too long
@dec2:
    dec dsk_blocks+1
@dec:
    dec dsk_blocks

    lda ld_track
    ldx ld_sector
    jsr disk_read_sector
    bcc @cb_ok
    jmp @err
@cb_ok:
    lda #0
    sta DISK_PTR_LO
    lda DISK_DATA          ; next track
    sta ld_track
    lda DISK_DATA          ; next sector / last index
    sta ld_sector
    lda ld_track
    bne @block_full
    ; last block: last valid index = ld_sector; count = ld_sector - 1
    lda ld_sector
    sec
    sbc #1
    sta ld_count
    lda #2
    sta DISK_PTR_LO
    jsr copy_payload
    jmp @done
@block_full:
    lda #254               ; buffer[2..255]
    sta ld_count
    lda #2
    sta DISK_PTR_LO
    jsr copy_payload
    jmp @chain

@done:
    lda dsk_dst
    sta dsk_end
    lda dsk_dst+1
    sta dsk_end+1
    clc
    rts
@err:
    sec
    rts

; copy_payload: copy ld_count bytes from the DATA port to (dsk_dst), advancing
; dsk_dst. DISK_PTR_LO must already point at the first byte. Clobbers A, X, Y.
copy_payload:
    ldx ld_count
    beq @end
    ldy #0
@loop:
    lda DISK_DATA          ; auto-increments the buffer pointer
    sta (dsk_dst),y
    inc dsk_dst
    bne @noc
    inc dsk_dst+1
@noc:
    dex
    bne @loop
@end:
    rts

; ── disk_load_prg_by_name: find a PRG by name and load it ───────────────────
; Input: dsk_ptr = pointer to a name. Output: carry clear on success (dsk_start =
;        load addr, dsk_end = end+1); carry set on failure.
.export disk_load_prg_by_name
disk_load_prg_by_name:
    jsr disk_find_prg
    bcs @nf
    lda dsk_entry+DE_TRACK
    ldx dsk_entry+DE_SECTOR
    jmp disk_load_prg_from_ts
@nf:
    sec
    rts
