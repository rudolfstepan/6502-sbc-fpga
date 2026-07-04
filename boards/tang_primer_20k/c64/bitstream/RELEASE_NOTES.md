# Bitstream-Releases -- Native C64 auf Tang Primer 20K

Neuester Eintrag oben. Die versionierten `.fs`-Dateien in diesem Ordner sind
auf der Hardware getestete Staende; `tang_c64.fs` ohne Suffix ist jeweils eine
Arbeitskopie ohne Garantie. Die `.fs`-Dateien liegen nur lokal (nicht in git):
sie enthalten die einsynthetisierten Commodore-ROMs und das Repo ist
oeffentlich. Die SHA256-Summen hier identifizieren die lokalen Dateien.

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
