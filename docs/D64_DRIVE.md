# D64 GoDrive

A D64-compatible virtual disk drive for the FPGA 6502 SBC. The second SD card
(the `sd2_*` data disk) is FAT32-formatted and holds `.d64` disk images. The
FPGA mounts one image and exposes its 256-byte D64 sectors to the 6502; the 6502
believes it is talking to a simple block device and never parses FAT32.

> Version 1 is **read-only** (directory listing + PRG loading). Write/SAVE is out
> of scope. This is a practical D64 block device, not a cycle-accurate 1541.

## A borrowed format, not C64 compatibility

This is a **trivial loader device that borrows the D64 on-disk structure** — it
is *not* a Commodore-compatible disk system, and the programs it loads are *not*
C64 programs.

What we reuse from D64 / Commodore:

- the **D64 image layout** (35 tracks, the track/sector zone geometry, BAM on
  track 18 sector 0, the linked directory starting at track 18 sector 1);
- the **directory entry format** (32-byte entries, `$82` = closed PRG, first
  track/sector, `$A0`-padded name, block count);
- the **PRG block chain** (next-track/next-sector link in bytes 0/1, the 2-byte
  load address at the start of the first block, the last-block byte count).

We picked this because it is a well-documented, easy-to-generate container with
existing host tooling — nothing more. **What we deliberately do *not* inherit:**

- **Programs are this system's own code, not C64 code.** The CPU is the same
  6502, but there is no VIC-II, no CIA, no C64 KERNAL, and the BASIC is EhBASIC
  (different tokens and zero-page layout), so a real C64 `.prg` will not run.
- **Load addresses are ours.** PRGs are loaded to the address embedded in the
  file; that address targets *this* machine's memory map (linear RAM
  `$0000-$5FFF`, I/O at `$88xx`, etc.), not the C64's.
- **No IEC bus, no 1541, no DOS commands, no fastloaders, no copy protection.**
- **No PETSCII semantics beyond name padding.** Names are plain uppercase ASCII;
  we only honour the `$A0` directory padding.

In short: the `.d64` is just a convenient file container for programs *built for
this FPGA SBC*.  The host tools in `tools/d64/` create images whose PRGs are
linked for this machine (see `tools/build_sid_prg.py` for the SID-player PRGs on
the test disk).  Do not expect to drop arbitrary C64 disk images in and run them.

## Architecture

```
SD2 (FAT32, .d64 files)
  └─ sd_card_top (sd2)              raw 512-byte SD read channel  [unchanged]
       └─ d64_subsystem             6502 register interface @ $8824 (DEV_DISK)
            ├─ fat32_reader         MBR→BPB→root→first .D64→start LBA + verify
            └─ d64_drive            D64 track/sector → LBA + 256-byte sector buffer
```

The first SD card (the ROM loader, `sd_*` pins) is untouched. `d64_subsystem`
replaces the old raw `sd_disk_ctrl` on the sd2 channel and is the sole sd2 read
master; the two internal engines are mutually exclusive in time (FAT scan during
MOUNT, sector reads during READ_SECTOR) and share the channel via a small
arbiter.

## Register map (DEV_DISK, base `$8824`)

| Addr   | Off | Name    | R/W | Meaning |
|--------|-----|---------|-----|---------|
| `$8824`| 0   | STATUS  | R   | bit0 BUSY, bit1 DONE, bit2 ERROR, bit3 MOUNTED, bit4 WRITE_PROTECT, bit6 IMAGE_READY |
| `$8825`| 1   | COMMAND | W   | see commands below |
| `$8826`| 2   | TRACK   | RW  | READ_SECTOR input track (1-based) |
| `$8827`| 3   | SECTOR  | RW  | READ_SECTOR input sector (0-based) |
| `$8828`| 4   | RESULT  | R   | DISK_RESULT code of the last command |
| `$8829`| 5   | DATA    | R   | sector-buffer data port; each read auto-increments the pointer |
| `$882A`| 6   | PTR_LO  | RW  | buffer pointer (0..255) |
| `$882B`| 7   | PTR_HI  | R   | reserved (always 0; buffer is 256 bytes) |

### Commands (write to COMMAND)

| Code  | Name        | Action |
|-------|-------------|--------|
| `$00` | NOP         | no operation |
| `$01` | READ_SECTOR | read D64 (TRACK, SECTOR) into the sector buffer |
| `$03` | MOUNT       | scan FAT32 for the first `.d64`, verify it, mount it |
| `$04` | UNMOUNT     | clear the mounted image |
| `$0A` | RESET       | clear BUSY/result, keep the mount |

### Result codes (DISK_RESULT)

| Code  | Meaning |
|-------|---------|
| `$00` | OK |
| `$01` | NO_IMAGE_MOUNTED |
| `$02` | INVALID_TRACK |
| `$03` | INVALID_SECTOR |
| `$04` | SD_READ_ERROR |
| `$06` | UNSUPPORTED_IMAGE (fragmented `.d64`) |
| `$0A` | INVALID_COMMAND |
| `$0B` | DIRECTORY_ERROR (no `.d64` / unusable FAT) |

## Kernel jump table — LOAD lives in the kernel, BASIC just calls it

The disk routines live in the **kernel ROM** (`sw/kernel.s`, $F000-$FFFF) and are
reached through fixed jump-table entries.  BASIC (and apps) only call these — no
program talks to the `$8824` registers directly.

| Entry | Routine | Action |
|-------|---------|--------|
| `$F01E` | `DISK_MOUNT` | scan FAT32, mount the first `.d64` (C=0 ok) |
| `$F021` | `DISK_DIR`   | print the directory of the mounted image |
| `$F024` | `DISK_LOAD`  | load a PRG by name (`DK_PTR` → name) to its embedded address |
| `$F027` | `DISK_SAVE`  | reserved — write support not yet implemented |

`EhBASIC LOAD "NAME"` (`sw/ehbasic_fpga.s`) is a thin wrapper: it mounts (via the
kernel), evaluates the string argument, copies the name to a buffer, and calls
`DISK_LOAD ($F024)`.  All disk-format logic stays in the kernel.

### Listing the directory and running a program from BASIC

```basic
LOAD "!"          : REM interactive .d64 select menu (cursor keys + Enter)
LOAD "$"          : REM 1541-style: print the directory to the screen
LOAD "ZOIDS"      : REM kernel mounts + loads the PRG to its embedded address
CALL 6912         : REM jump to the program's entry (here $1B00)
```

`LOAD "!"` opens an arrow-key menu of every `.d64` on the FAT32 card and mounts
the one you pick (see the menu section below), then prints its directory.

`LOAD "$"` prints the directory of the mounted disk and returns to BASIC without
touching the program in memory.  (It does *not* load `$` as a program to be
`LIST`ed; it prints immediately.)

The listing is printed **indented 4 spaces**, with each file line as
`____"NAME" PRG` (no leading block count).  This is so you can run a program
straight from the listing the C64 way: move the cursor to the start of a file
line, type `LOAD` over the four spaces so the line reads `LOAD"NAME" PRG`, and
press Enter.  The kernel's screen-edit replay rebuilds the edited line and the
LOAD hook evaluates `"NAME"` (the trailing type label is ignored).  See
[SCREEN_EDITOR_REPLAY.md](./SCREEN_EDITOR_REPLAY.md).

`LOAD "NAME"` only loads; it does not auto-run.  On success it prints the entry
address to use, e.g.:

```
LOADED CALL 8192
```

so you just type that `CALL` to run it.  By convention every PRG built for this
system has its **entry point at its load address**, so the kernel simply reports
the load address.  The test-disk PRGs all load at `$2000`, so they all run with
`CALL 8192`.

> Because this is not C64-compatible (see above), a loaded BASIC-style program is
> not relinked into EhBASIC's program area; PRGs are machine-code-style payloads
> started with `CALL`.

## Multi-part games: chain-loading the next part

A program loaded from the disk can itself load and run another PRG — so a game
can ship as several parts (intro, main, levels…) on one `.d64`, each loading the
next.  The mechanism is just `DISK_LOAD` followed by a jump to the loaded part's
entry (every PRG's entry = its load address):

```asm
    lda #<NAME            ; NAME = uppercase, null-terminated (e.g. "PART2")
    ldy #>NAME
    sta DK_PTR            ; $F2
    sty DK_PTR+1
    jsr $F01E             ; DISK_MOUNT (idempotent)
    jsr $F024             ; DISK_LOAD  -> DK_START ($0365) = load address
    bcs load_failed
    jmp (DK_START)        ; run the next part
```

**The self-overwrite trap.** If the next part loads to the *same* address as the
loader (the usual case — every part is the "current" program at `$2000`), the
load overwrites the loader's own code while the kernel is copying it.  When
`DISK_LOAD` returns, the `jmp (DK_START)` instruction has been clobbered → crash.

**`sw/chainload.inc`** solves this: it copies a tiny position-independent
mount/load/jump stub to **`$5F00`** and runs it there.  The kernel disk code
touches only zero page (`$F2/$F4/$F7`), page 3 (`$0340-$037D`) and the
`$8824-$882F` ports — never `$5F00` — and parts live below the bitmap window
(`$6000`), so the stub survives the load and jumps cleanly into the new part.

```asm
    lda #<part2name
    ldy #>part2name
    jsr chainload         ; loads + runs the named PRG; never returns on success
    ; reached only if the load failed (the stub falls back to BASIC)

.include "chainload.inc"
```

Parts must load and run **below `$5F00`** (16 KB above `$2000` is plenty; the
bitmap window already caps RAM at `$6000`).  Each part may itself `chainload` the
next, so any number of parts can chain.

### Demo: `roms/test_d64/multipart.d64`

`make multipart-d64` builds two RAM PRGs ([`sw/mp_part1.s`](../sw/mp_part1.s),
[`sw/mp_part2.s`](../sw/mp_part2.s)) and packs them into `multipart.d64`.  PART1
prints a banner and, on a key press, chain-loads PART2 (which loads at the same
`$2000` and just runs):

```basic
LOAD "PART1"      : REM the "intro" part
CALL 8192         : REM run it -> press a key -> PART2 auto-loads and runs
```

## Standalone 6502 API (`sw/disk.s`)

`sw/disk.inc` + `sw/disk.s` provide the same read-only routines as a reusable
library (the kernel mirrors them).  Carry clear = success, carry set = failure.

| Routine | In | Out |
|---------|----|----|
| `disk_mount` | – | mounts the first `.d64`; C=0 on success |
| `disk_read_sector` | A=track, X=sector | reads the 256-byte sector into the buffer |
| `disk_dir_open` / `disk_dir_next` | – | walk the directory; each `_next` fills `dsk_entry` |
| `disk_load_prg_by_name` | `dsk_ptr`=name | finds + loads a PRG to its embedded address |
| `disk_raw_read` / `disk_raw_read_hi` | A/X/Y=LBA | debug: read a raw card sector half |

`sw/disk_test.s` is a self-contained exerciser ROM (split map, upload with
`--split-rom`): it mounts, peeks the BAM, lists the directory, and loads the
first tune by name, printing each step to the UART.

```sh
make -C sw disk-test          # build sw/disk_test.rom
make -C sw upload-disk-test   # build + upload over the UART monitor
```

## Usage from the 6502 (raw registers)

```
; mount the first .d64 on the card
LDA #$03         ; MOUNT
STA $8825
@wait1:
LDA $8824        ; STATUS
AND #$01         ; BUSY
BNE @wait1
LDA $8824
AND #$08         ; MOUNTED
BEQ mount_failed

; read track 18, sector 1 (first directory sector)
LDA #18
STA $8826        ; TRACK
LDA #1
STA $8827        ; SECTOR
LDA #$01         ; READ_SECTOR
STA $8825
@wait2:
LDA $8824
AND #$01
BNE @wait2
LDA $8824
AND #$04         ; ERROR
BNE read_failed

; stream the 256 sector bytes through the DATA port
LDA #0
STA $882A        ; PTR_LO = 0
LDX #0
@copy:
LDA $8829        ; DATA (auto-increments the pointer)
STA buffer,X
INX
BNE @copy
```

`MOUNT` runs the FAT32 scan and the D64 contiguity check entirely in hardware;
the 6502 only polls STATUS. For Version 1 the kernel issues `MOUNT` once at
startup (there is no fabric boot menu — see the limitations below).

## Supported images

- Standard 35-track D64: 683 sectors × 256 bytes = **174848 bytes**, no error
  bytes. Other variants (40/42 track, error bytes) are not supported in V1.
- The `.d64` file on the FAT32 card must be **contiguous** (unfragmented). A
  freshly copied file on a clean card is contiguous; `fat32_reader` verifies the
  FAT chain at MOUNT and returns `UNSUPPORTED_IMAGE` if it is not.
- One `.d64` per mount; `fat32_reader` mounts the first `.D64` it finds in the
  root directory (no long-filename / subdirectory support).

## Tooling

| Tool | Purpose |
|------|---------|
| `tools/d64/d64_common.py` | shared track/sector geometry (RTL twin: `d64_sector_map.vhd`) |
| `tools/d64/create_test_d64.py` | build the deterministic `roms/test_d64/testdisk.d64` |
| `tools/d64/list_d64.py` | print a D64 directory |
| `tools/d64/extract_prg.py` | extract a PRG (file-chain reference for the loader) |
| `tools/d64/make_fat32_card.py` | build a FAT32 card image embedding a `.d64` (for sims) |

```sh
make test-d64            # host-side mapping unit tests
make test-d64-map        # GHDL: d64_sector_map
make test-d64-drive      # GHDL: d64_drive against a real testdisk.d64
make test-fat32          # GHDL: fat32_reader against a FAT32 card image
make test-d64-subsystem  # GHDL: full MOUNT + READ end-to-end
```

(The Makefile defaults `GHDL` to a machine-specific path; use `make <target>
GHDL=ghdl` if GHDL is on your PATH.)

## Putting it on hardware

1. FAT32-format the second SD card (a normal Windows quick-format works — the
   card is "superfloppy" with no MBR, which `fat32_reader` detects).
2. Copy a contiguous 35-track `.d64` (e.g. `roms/test_d64/testdisk.d64`) to it.
3. Build/flash the Tang Primer 20K bitstream (the D64 modules are in the board
   project file lists: `build.tcl` and `tang_sbc.gprj`).
4. From the 6502, `MOUNT` then `READ_SECTOR` per the usage example.

## FAT32 layouts handled

- Both **MBR-partitioned** cards and **superfloppy** cards (BPB at LBA 0, no MBR
  — what Windows produces for SD cards). `fat32_reader` checks byte 0 of LBA 0:
  an `EB`/`E9` jump means the BPB is at LBA 0.
- The whole first root-directory cluster is scanned, so the `.d64` is found even
  when entries like `System Volume Information` precede it.
- The `.d64` must be contiguous; `fat32_reader` verifies the FAT chain and
  returns `UNSUPPORTED_IMAGE` ($06) otherwise.

## RTL / toolchain notes

- Gowin synthesis (`gw_sh`) compiles VHDL as 1076-2002, **not** 2008. Avoid
  VHDL-2008-only constructs in synthesizable RTL — in particular conditional
  signal assignments (`x <= a when c else b`) *inside a process*; use plain
  `if/else`. (Concurrent `when/else` outside a process is fine.)
- The DATA-port pointer auto-increments once per CPU access via falling-edge
  detect, because a CPU bus cycle spans two system clocks here (`cpu_enable`
  toggles every clock). Incrementing on the level would skip every other byte.

## Status

Hardware-verified on the Tang Primer 20K: a Windows-formatted (superfloppy)
32 GB FAT32 card with a `.d64` mounts; the kernel reads the BAM and directory,
`LOAD "NAME"` loads a PRG, and `CALL <addr>` runs it (the SID test disk plays).

## Limitations / not yet done

- **No write support / SAVE** (read-only).  `SAVE` returns "not implemented";
  adding it needs BAM allocation + directory write in the kernel.
- **No fabric boot menu:** the 6502 issues `MOUNT`; the engine mounts the first
  `.d64` found.  Runtime image selection / multiple drives are future work.
- **Loaded programs are started manually with `CALL`** and run to completion in
  their own loop; there is no relink into EhBASIC's program area and no
  IRQ-driven background play.
- **Not C64-compatible** — only the D64 container structure is borrowed (see the
  section near the top).
