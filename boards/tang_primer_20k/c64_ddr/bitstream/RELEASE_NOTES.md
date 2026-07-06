# Bitstream-Releases -- Native C64 auf Tang Primer 20K

Neuester Eintrag oben. Die versionierten `.fs`-Dateien in diesem Ordner sind
auf der Hardware getestete Staende; `tang_c64.fs` ohne Suffix ist jeweils eine
Arbeitskopie ohne Garantie. Die `.fs`-Dateien liegen nur lokal (nicht in git):
sie enthalten die einsynthetisierten Commodore-ROMs und das Repo ist
oeffentlich. Die SHA256-Summen hier identifizieren die lokalen Dateien.

## Arbeitsstand 2026-07-06 (`c64_ddr`, nicht versionierte `.fs`)

- Separater Tang-Primer-20K-DDR-Fork unter `boards/tang_primer_20k/c64_ddr`;
  die bestehenden C64-/Probe-/SBC-Projekte bleiben unveraendert.
- Gowin-Kompatibilitaet: `iecdrv_mem` im gemeinsamen MiSTer-IEC-Code hat
  Default-Parameter fuer DATAWIDTH/ADDRWIDTH, damit Gowin die 1541-RAM-Module
  ohne EX3206 elaboriert. Bestehende explizite Instanzen bleiben unveraendert.
- 64K C64-Haupt-RAM laeuft ueber den on-board DDR3-Byte-Bridge-Pfad
  (`ddr3_byte_bridge`) statt ueber C64-BSRAM.
- `VIC_XL => true`: der XL-VIC rendert aus einem lokalen 16K-BSRAM-Shadow der
  aktiven VIC-Bank. CPU-/Monitor-/Cold-Reset-Writes spiegeln in diesen Shadow;
  CIA2-Bankwechsel starten einen DDR-Reload der neuen Bank.
- Grafikstand auf Hardware: 1942/Commando-artige Bitmap-/Charset-Hintergruende
  sind nach Shadow-Write-Through und Reload-Fixes sauber.
- Power-up-Reset: One-Shot-Automatik wartet auf DDR/Bootloader, laesst den C64
  kurz anlaufen, pulst dann einmal die Board-Reset-Schiene wie KEY[0] und bleibt
  danach in `CR_DONE`. Der vorherige Reset-Loop ist damit behoben.
- Timing im letzten Gowin-Build: 0 Setup- und 0 Hold-Verletzungen. Ressourcen
  grob: 78 % Logic, 39/46 BSRAM.
- Die erzeugte Datei liegt lokal unter
  `project/impl/pnr/tang_c64_ddr.fs`; sie wird wegen eingebetteter
  Commodore-ROM-Daten nicht committed.

## Arbeitsstand 2026-07-05 (nicht versionierter `tang_c64.fs`)

- 1541/D64-Writeback im nativen Tang-C64-Build aktiviert:
  `MISTER_1541_BACKEND=3`, `MISTER_1541_SD_WRITE=true`,
  `SD_PACKED_D64_FILE=true`.
- Auf Hardware verifiziert: normales BASIC/KERNAL `SAVE"NAME",8` schreibt in
  die aktuell gemountete zusammenhaengende FAT16-`.d64`; danach erscheint der
  Directory-Eintrag sauber und die Datei laedt wieder.
- Die SD-Floppy schreibt nur innerhalb der gemounteten D64-Datei. Sie legt keine
  FAT-Dateien an und sollte mit Backup/disposable Images benutzt werden.
- Drive-LEDs am Board zeigen 1541 Head Read, 1541 Head Write, drive-owned SD
  Read und drive-owned SD Write Flush.
- D64-Selector: `LOAD"@",8` und der standalone FAT16-Selector zeigen nun 16
  Images pro Seite; Cursor rechts/runter blaettert vor, Cursor links/hoch
  zurueck.
- Hook-Update fuer bestehende FAT16-Karten: `make mister64-sd-hook-block` plus
  `tools/write_sd_hook_block.ps1 -DriveLetter G` schreibt nur den C64HOOK1-Block
  bei LBA 8 und laesst FAT/D64-Daten unveraendert.
- Neue Diagnosepfade:
  - `roms/diagnostics/diagnose.prg` fuer SAVE auf echter Hardware
  - `$DF07`, `$DF0D-$DF0F`, `$DF10-$DF14` als Write-Counter/Trace
  - `make test-c1541-sd-write` fuer GHDL
  - `boards/tang_primer_20k/c1541_selftest` als standalone Floppy-Selftest ohne
    C64-Core
- Wichtige Fixes gegenueber dem defekten Zwischenstand: GCR-Write-Bitfolge und
  Commit-Marker korrigiert, 512-Byte-SD-Block per Read-Modify-Write erhalten,
  SD-CMD24 wartet auf Data-Response und Card-Busy-Ende.
- Noch nicht als stabiler Support deklariert: 1541-Formatierung, Scratch/Rename,
  Non-Standard-D64s, Copy Protection und Custom Fastloader.

## tang_c64_20260704_v1.fs (2026-07-04)

- SHA256: `F748418AE34B33F7AC88C8E08797429B0049DC40426DA31BA415462B1AFDE14A`
- Gowin V1.9.12.03, GW2A-LV18PG256C8/I7
- Logik 18727/20736 (91 %), BSRAM 46/46, 0 Setup- und 0 Hold-Verletzungen
- Auf Hardware getestet: Boot zu `READY.`, UART-PRG-Upload, SD-Zugriff

Aenderungen gegenueber dem eingefrorenen Bring-up-Stand (DEBUG_NOTES,
SHA `D8DB1F8F...`):

### VIC-II XL (rtl/c64/vic_ii_xl.vhd)

Zyklenbasiertes 6569-Modell nach Bauers vic-ii.txt statt des alten
Zeilenpuffer-Renderers (der bleibt als `vic_ii.vhd` erhalten, Umschaltung
ueber das Generic `VIC_XL` in `tang20k_c64_top.vhd`):

- echte Badlines (VC/RC/VCBASE, Badline-Bedingung live -> FLD/Linecrunch),
  BA an den echten Zyklen 12..54 plus Sprite-Fenster
- Registerwirkung sofort (Splits mitten in der Zeile), XSCROLL als echte
  Shift-Register-Reload-Bedingung, YSCROLL/RSEL/CSEL
- Border-Flipflops (Border-Opening, Sprites im Rahmen sichtbar)
- Sprite-DMA nach Bauer 3.8: MC/MCBASE, Y-Crunch, X/Y-Expansion,
  Kollisionsregister mit funktionierenden IRQs, Read-Clear am Zyklusende
- Idle-State $3FFF/$39FF, ungueltige Modi rendern schwarz
- Abweichungen: 64 statt 63 Zyklen/Zeile (CPU exakt 1,000 MHz), eine
  Top-Border-Zeile laeuft pro Frame 1,5x (625 HDMI-Zeilen = 312,5 C64-Zeilen)
- VIC holt Daten ueber eigene Leseports (c64_ram_dp/colour_ram_dp Port B);
  BA emuliert nur noch das 6510-Stall-Timing

### SD-Floppy (wie MiSTer-C64-Probe-Board)

- 1541 (`mister_c1541_iec`) mit `D64_BACKEND=3`: zusammenhaengende .d64 auf
  FAT16-Karte, Mount zur Laufzeit -- gleiche Karte, gleicher SD-Hook und
  gleiches Diskmenue wie beim Probe-Port
- Registerfenster $DF00-$DF0D in I/O2 (Mount-LBA/Strobe, Status,
  Boot-Status, Fastload-Fenster, Raw-Block-Read fuer FAT16-Parsing im C64)
- Power-up-Bootloader laedt den residenten Hook ("C64HOOK1", LBA 8) ueber
  den Monitor-RAM-Port, CPU dabei per RDY geparkt
- SD im SPI-Modus auf PMOD1: SCK=T11, CS=P11, MOSI=T12, MISO=R11
- Der Virtual-1541-UART-Transport (Backend 2) ist in diesem Bitstream nicht
  mehr verdrahtet; die CH340-Leitung ist frei fuer den Monitor

### UART-Monitor

- Der grosse FLAT_64K-Monitor (2,1k LUTs) ist durch den kleinen
  `c64_prg_upload_monitor` ersetzt (Wake-Sequenz A5 5A C3 3C unveraendert):
  - `L aaaa` + Hexbytes + `.`  Upload/Poke
  - `M aaaa bbbb`              Hex-Dump, 8 Bytes/Zeile mit ASCII-Spalte
                               (liest RAM unter ROM/I/O)
  - `G`                        C64 freigeben
- PC-Seite: tools/c64_uart_prg_loader.py (Upload) und
  tools/c64_uart_monitor_wake.py (interaktiv)

### Ressourcen-Umbauten (noetig, damit alles auf den GW2A-18 passt)

- CHARGEN im XL-Pfad zeitgemultiplext (ein ROM-Port statt zwei)
- Colour-RAM distributed, VIC-Zeilenpuffer als BSRAM (syn_ramstyle)
- sec_buf der SD-Sector-Source als echtes RAM inferierbar (Blank-Flag
  statt Bulk-Clear)

### Bekannte Einschraenkungen

- Zyklengezaehlte Demos sind wegen 64 Zyklen/Zeile nicht exakt
- Sprite-Anzeige seitlich auf X 4..363 beschnitten (echter PAL-Rand ist
  breiter); Kollisions-/Prioritaets-Randfaelle vereinfacht
- Lightpen $D013/$D014 sind Konstanten
