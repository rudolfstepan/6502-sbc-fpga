; ============================================================
; chainload.inc -- load another PRG from the data D64 and run it.
;
; For multi-part games: one part (e.g. an intro) loads the next part by name and
; jumps to it.  The next part may load to the SAME address as the caller, because
; the actual mount/load/jump runs from a small stub relocated to $5F00 -- which
; neither the kernel disk code (it uses only zero page $F2/$F4/$F7, page 3
; $0340-$037D and the $8824-$882F ports) nor a sub-$5F00 part overwrites.
;
; Usage (the named file must be UPPERCASE, as stored in the D64 directory):
;     lda #<NAME
;     ldy #>NAME
;     jsr chainload          ; does NOT return on success (runs the loaded part)
;     ; ... only reached on load failure (stub falls back to BASIC) ...
;
; Requires the standard kernel ($F000) -- i.e. the part runs as a RAM PRG under
; the EhBASIC/kernel ROM, not as a standalone replacement ROM.  Parts must load
; and run below $5F00 (the bitmap window starts at $6000 anyway).
; ============================================================

CL_DK_PTR   = $F2            ; kernel name pointer
CL_DK_START = $0365          ; kernel: loaded PRG's load address (= entry)
CL_KMOUNT   = $F01E          ; DISK_MOUNT (idempotent)
CL_KLOAD    = $F024          ; DISK_LOAD  (DK_PTR -> name; C=0 ok)
CL_KBASIC   = $F015          ; start BASIC (failure fallback)
CL_STUB     = $5F00          ; safe relocation target for the load+jump stub

chainload:
    sta CL_DK_PTR
    sty CL_DK_PTR+1
    ldx #(cl_stub_end - cl_stub)
@copy:
    lda cl_stub-1,x
    sta CL_STUB-1,x
    dex
    bne @copy
    jmp CL_STUB

; The stub is position-independent: kernel/zero-page references are absolute and
; the only branch (bcs) is relative, so it runs correctly once copied to $5F00.
cl_stub:
    jsr CL_KMOUNT
    bcs @fail
    jsr CL_KLOAD
    bcs @fail
    jmp (CL_DK_START)        ; run the loaded part (entry = load address)
@fail:
    jmp CL_KBASIC
cl_stub_end:
