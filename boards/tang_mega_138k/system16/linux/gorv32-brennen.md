# GoRV32 Plus Linux: Brenn-Anleitung (Tang Console 138K)

Das Linux (OpenSBI + DTB + Kernel als GRV1-Image) bootet von der
SD-Karte; im Flash bleiben nur Bitstream und ZSBL. Der Resetvektor der
CPU zeigt fest ins Flash-XIP-Fenster, deshalb ist der kleine ZSBL im
Flash nicht verhandelbar.

Der Flash auf diesem Board ist ein XTX XT25F64B: 64 Mbit = **8 MB**
(JEDEC-ID 0x0B4017, vom Programmer gemeldet). Alle Adressen muessen
unter 0x800000 bleiben; der unkomprimierte GW5AST-138-Bitstream belegt
~4,9 MB ab 0. Daraus ergibt sich:

| Nr. | Ziel | Datei | Operation |
| --- | --- | --- | --- |
| 1 | Flash `0x000000` | `project/impl/pnr/tang138k_system16_gorv32plus.fs` | exFlash Erase, Program |
| 2 | Flash `0x500000` | `linux/zsbl/zsbl.bin` | exFlash C Bin Erase, Program, Verify |
| 3 | SD-Karte, roh ab Sektor 0 | `build/gorv32-linux/gorv32-flash.bin` | Raw-Writer (wie beim VexRiscv-Flow) |
| (4) | Flash `0x510000`, optional | `gorv32-flash.bin` als Fallback ohne SD-Karte | exFlash C Bin Erase, Program |

`0x500000` ist zugleich die "Flash Burn Address" im IP Core Generator -
beide muessen immer uebereinstimmen, sonst zeigt das XIP-Fenster der CPU
auf die falsche Stelle. Der ZSBL versucht zuerst die SD-Karte (eigener
Treiber fuer den Vendor-SD-Host). Die Identifikation laeuft mit 200 kHz; fuer
die Datenphase werden konservative 1 MHz verwendet. Wenn ACMD6 erfolgreich
ist, nutzt der Treiber vier Datenleitungen, sonst arbeitet er mit einer
Leitung weiter. Bei fehlender Karte oder ungueltigem GRV1-Image faellt er auf
das Flash-Fenster zurueck.

Die Flash-Bereiche ueberlappen nicht; die Reihenfolge ist egal, jeder
Vorgang loescht nur die eigenen Sektoren.

## Vorgang 1: Bitstream

Gowin Programmer, Board per USB-JTAG verbunden, Device GW5AST-138C.
Doppelklick auf die Geraetezeile (oder Edit > Configure Device):

- Access Mode: **External Flash Mode 5A** (Arora V)
- Operation: **exFlash Erase, Program 5A** (oder mit Verify)
- Programming Options > File name: die `.fs`-Datei
- External Flash Options > Device: **Generic Flash**
- External Flash Options > Start Address: **0x000000**

Dann Edit > Program/Configure (Play-Knopf).

## Vorgang 2: ZSBL

Gleiche Geraetezeile, Konfiguration aendern:

- Access Mode: **External Flash Mode 5A**
- Operation: **exFlash C Bin Erase, Program, Verify 5A**
- External Flash Options > Device: **Generic Flash**
- External Flash Options > Start Address: **0x500000**
  (= Flash Burn Address aus dem IP Core Generator; Hex, sechs Nullen -
  0x8000000 statt 0x800000 war hier schon einmal der Fehler, und
  Adressen ab 0x800000 liegen auf diesem Chip ausserhalb)
- FW/MCU/Binary Input Options > Firmware/Binary File: `zsbl.bin`

Program/Configure ausfuehren. Die Verify-Stufe bestaetigt, dass der
Inhalt wirklich im Flash steht.

## Vorgang 3: Linux-Image auf die SD-Karte

`gorv32-flash.bin` roh ab Sektor 0 auf die Karte schreiben (kein
Dateisystem, kein MBR) - gleiche Methode wie beim VexRiscv-SD-Image.
Karte in den TF-Slot stecken.

Optional als Fallback ohne Karte: dasselbe Image per
"exFlash C Bin Erase, Program" bei **0x510000** in den Flash brennen.

## Danach

Board stromlos machen und neu einschalten (Power-on laedt den Bitstream
aus dem Flash). Terminal auf **115200 8N1**. Erwartete Sequenz:

```text
FPGA BOOT OK                  <- Board-Shell (Probe)
System16 GoRV32 ZSBL v10      <- ZSBL laeuft XIP aus dem Flash
boot from SD                  <- Karte erkannt (sonst: boot from flash)
copy $00000000 len $...       <- OpenSBI -> SDRAM
copy $003F0000 len $...       <- DTB -> SDRAM
copy $00400000 len $...       <- Kernel -> SDRAM
checksum ok, jump to OpenSBI
OpenSBI v1...                 <- OpenSBI-Banner
[    0.000000] Linux version  <- Kernel-Log
```

Der ZSBL meldet SD-Fehler im Klartext ("SD init failed at step N",
"SD read error", Checksum-Soll/Ist) und probiert danach das
Flash-Fenster.

Der HDMI-Statusstreifen (oberste 48 Zeilen) zeigt die Diagnose:
rot = CPU stumm (QSPI-Fetch tot), blau = nur DDR-Reads (CPU fuehrt
Muell aus), magenta = DDR-Writes ohne UART (UART-Pfad defekt),
gelb = UART ohne DDR, gruen = UART + Writes (Kette gesund).

`linux/system16.config` bindet das von `make rootfs-wsl` erzeugte BusyBox-cpio
als initramfs ein. Damit endet der bestaetigte Minimal-Boot an einer
benutzbaren Shell. Fehlt die dort angegebene cpio-Datei beim Kernel-Build,
oder wurde ein Kernel ohne initramfs verwendet, endet der Boot stattdessen
erwartungsgemaess mit `no working init`.

## Im Entwicklungsalltag

- Nur Linux geaendert (Kernel/DTB/OpenSBI): `make gorv32-flash-image`,
  Image neu auf die SD-Karte schreiben - kein Programmer noetig.
- Nur ZSBL geaendert: `make gorv32-zsbl-wsl`, dann nur Vorgang 2.
- Bitstream-Iterationen: weiter wie gewohnt per JTAG ins SRAM laden
  (`make gorv32plus-program`) - der ZSBL im Flash bleibt davon
  unberuehrt. Der Flash-Bitstream (Vorgang 1) ist nur fuer den
  autonomen Power-on-Boot noetig.
- Der Bitstream-Bereich waechst nie ueber ~4,9 MB (unkomprimiert ist
  die Groesse geraeteabhaengig konstant), das Layout bleibt stabil.
  Auf der SD-Karte gibt es keine Groessengrenze; nur der optionale
  Flash-Fallback ist auf 2,9 MB begrenzt (Packer-Guard).
