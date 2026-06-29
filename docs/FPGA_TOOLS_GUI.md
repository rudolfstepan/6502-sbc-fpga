# PIX16 FPGA Tools — GUI Launcher

`fpga/tools/fpga_tools_gui.py` ist ein grafisches Frontend für alle Python-Werkzeuge im `fpga/tools/`-Verzeichnis.  Es ersetzt das manuelle Aufrufen der CLI-Skripte und bündelt Build, Upload, SD-Image-Erzeugung und Utilitys in einer einzigen Oberfläche.

## Starten

```powershell
python fpga/tools/fpga_tools_gui.py
```

Python 3.6+ und `tkinter` (in der Standard-Python-Distribution enthalten) sind die einzigen Abhängigkeiten.

## Aufbau der Oberfläche

```
┌──────────────────────────────────────────┐
│  PIX16 FPGA Tools          [Titelzeile]  │
├──────────────────────────────────────────┤
│  [ Build ] [ Upload ] [ SID Tunes ] [ SD Card ] [ Utilities ] │
│  ┌────────────────────────────────────┐  │
│  │  Sektionen mit Optionen & Buttons  │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│  OUTPUT                          [Clear] │
│  ┌────────────────────────────────────┐  │
│  │  gestreamte Prozessausgabe         │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│  Status …                    [■  Stop]   │
└──────────────────────────────────────────┘
```

Das Fenster ist zweigeteilt: oben ein Notebook mit fünf Tabs, unten ein scrollbares Ausgabe-Konsolenfenster.  Der **Stop**-Button bricht den laufenden Prozess jederzeit ab.  Es kann immer nur ein Prozess gleichzeitig laufen.

---

## Tab: Build

### Build EhBASIC ROM

Ruft `build_fpga_ehbasic.py` auf und assembliert `ehbasic_fpga.s` + `kernel.rom` zu einem physischen 16-KB-Image. EhBASIC liegt bei `$A000–$CFFF`, der Kernel bei `$F000–$FFFF`; zusätzlich entstehen zwei Upload-Segmente.

| Option | Flag | Beschreibung |
|---|---|---|
| Upload to board | `--upload --port PORT` | Lädt das ROM nach dem Build per UART-Monitor hoch |
| Run after upload | `--run` | Startet nach beiden Segmenten mit `G A000` |
| Also generate SD image | `--sd-image` | Erzeugt zusätzlich ein SD-Boot-Image (`.img`) |
| Verbose | `--verbose` | Zeigt Monitor-Antworten im Konsolenbereich |
| Port | `--port` | Serieller Port, z. B. `COM15` |
| Baud | `--baud` | Baudrate, Standard `115200` |

### Build SDRAM Diagnostic ROM

Ruft `build_diag_sdram.py` auf und assembliert `diag_sdram.s` → `diag_sdram.rom` (16 KB).  Testet den CPU→SDRAM-Schreibpfad auf der Hardware.

| Option | Flag | Beschreibung |
|---|---|---|
| Upload to board | `--upload --port PORT` | Hochladen nach Build |
| Verbose | `--verbose` | Ausführliche Ausgabe |
| Port | (Eingabefeld) | Serieller Port |

### Build Upload Demo ROM

Ruft `make_upload_demo_rom.py` ohne weitere Argumente auf.  Erzeugt `upload_demo.rom` mit LED-Blink, VGA-Text und UART-Banner.

---

## Tab: Upload

### Upload via UART Monitor

Ruft `upload_monitor_hex.py` (oder `upload_monitor_hex_enter.py` wenn *Send ENTER* aktiviert) auf.

> **Voraussetzung:** Zuerst die Monitor-Taste drücken (**KEY1** beim aktuellen Tang-Aufbau).

> **Split-ROM-Hinweis:** Der generische Upload-Tab übergibt weiterhin genau eine
> Adresse und ist daher nicht für das kombinierte EhBASIC-Image oder die
> SID-Split-ROMs geeignet. EhBASIC über den Build-Tab hochladen; SID-Tunes über
> den **SID Tunes**-Tab (siehe unten), der intern `--split-rom` verwendet. Ein
> zusammenhängender 16-KB-Upload ab `$C000` wird vom Uploader absichtlich
> abgelehnt.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| ROM Image | (Pfadauswahl) | `.rom`-  oder `.bin`-Datei; Standardpfad `fpga/roms/fpga_ehbasic_16kb.rom` |
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate |
| Address | `--address` | Zieladresse im RAM, Standard `0xC000` |
| Run after upload | `--run` | Springt nach dem Upload zur Adresse (`G <addr>`) |
| Send ENTER after run | — | Wechselt zum `_enter`-Skript, das nach dem Start ein CR sendet (EhBASIC Cold-Start) |
| Verbose | `--verbose` | Monitor-Antworten anzeigen |
| Build demo ROM first | `--build-demo` | Baut zuerst das Demo-ROM, dann Upload |

### Upload BASIC Program

Ruft `upload_basic_uart.py` auf.  EhBASIC muss bereits auf dem Board laufen und am Prompt warten.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| BASIC File | (Pfadauswahl) | `.bas`-Datei |
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate |
| Send NEW before upload | `--new` | Löscht das aktuelle Programm |
| Send RUN after upload | `--run` | Startet das Programm direkt |
| Verbose | `--verbose` | BASIC-Antworten anzeigen |

---

## Tab: SID Tunes

Wählt eine native SID-Tune-ROM aus `roms/sound_*.rom` und lädt sie auf den
SID-Kern. Ruft `upload_monitor_hex.py … --split-rom --run` auf (dasselbe wie die
`roms/upload/sound_*.bat`-Skripte). Die ROMs werden mit
`build_all_sid_roms.py` aus `sid_orig/` erzeugt (siehe [SOUND.md](./SOUND.md)).

> **Voraussetzung:** Zuerst die Monitor-Taste am Board drücken (Monitor-Modus).

| Feld / Option | Beschreibung |
|---|---|
| Filter | Tippt man Text ein, wird die Liste live gefiltert (Name oder Dateiname) |
| ↻ Refresh | Liest `roms/sound_*.rom` neu ein (z. B. nach einem Bulk-Build) |
| Tunes-Liste | Alle gefundenen SID-ROMs; **Doppelklick lädt direkt hoch** |
| Port / Baud | Serieller Port und Baudrate |
| Verbose | Monitor-Antworten anzeigen (`--verbose`) |
| ▶ Upload Selected SID | Lädt die markierte Tune hoch und startet sie bei `$A000` |

### C64 UART SID PRGs

Wählt eine RUN-loadbare C64-SID-PRG aus `roms/c64_uart_sid/` und lädt sie über
den nativen C64-UART-Monitor. Ruft intern `c64_uart_prg_loader.py` auf; nach dem
Upload wird die C64-Umgebung freigegeben, danach am C64-Prompt `RUN` eingeben.

Wenn zur PRG eine `*.prg.segments.json`-Sidecar-Datei existiert, nutzt der
Loader diese automatisch und überspringt große Null-Lücken zwischen BASIC-Stub
und SID-Player/Payload. Die Liste zeigt dann beide Größen an, z. B.
`22529 B -> 4237 B`.

| Feld / Option | Beschreibung |
|---|---|
| Filter | Filtert die C64-SID-PRG-Liste nach Titel oder Dateiname |
| ↻ Refresh | Liest `roms/c64_uart_sid/*.prg` neu ein |
| C64 SID PRG-Liste | Alle gefundenen RUN-PRGs; **Doppelklick lädt direkt hoch** |
| Port / Baud | Serieller Port und Baudrate für den C64-UART-Monitor |
| Wake byte | Monitor-Magic-Byte, Standard `0xA5` |
| Bytes/line / Line delay | Pacing für den monitorseitigen Hex-Upload; Standard `16` / `0` für schnelle C64-PRG-Uploads |
| Verbose | Monitor-Antworten anzeigen (`--verbose`) |
| Stay in FPGA monitor | Nach Upload nicht mit `G` zurück zur C64-Umgebung springen |
| ▶ Upload Selected C64 SID PRG | Lädt die markierte C64-SID-PRG hoch |
| ↻ Rebuild C64 SID PRGs | Ruft `make c64-sid-prgs` auf und erzeugt PRGs plus Segment-Sidecars neu |

---

## Tab: SD Card

### Create SD Boot Image

Ruft `make_sd_boot_image.py` auf und erzeugt ein rohes Disk-Image:

- **Sektor 0** — Boot-Header: Magic `SBCROM01` + CRC32
- **Sektoren 1–32** — 16 KB ROM-Payload

| Feld | Beschreibung |
|---|---|
| ROM File | Eingabe-ROM (`.rom`/`.bin`), Pfad-Browser verfügbar |
| Output Image | Ausgabepfad für das `.img`-File, Speichern-Dialog verfügbar |

Tipp: An den ROM-Pfad `@0x0000` anhängen, um das ROM an einem bestimmten Offset zu platzieren.

### Write to SD Card

Anleitungen zum Schreiben des Images auf eine SD-Karte (nur Anzeige, kein Button):

```
Linux / macOS:  dd if=fpga_ehbasic_16kb.img of=/dev/sdX bs=512
Windows:        Win32DiskImager  oder  tools\write_sd.bat <image>
```

---

## Tab: Utilities

### C64 D64 Game Upload

Scannt rekursiv einen D64-Ordner, standardmäßig `E:\Emulatoren\C64\Games` wenn
dieser Pfad existiert, sonst `roms/test_d64/`. Die markierte `.d64` wird auf dem
PC gelesen; die GUI ruft intern `c64_d64_prg_loader.py` auf, extrahiert das erste
PRG oder ein benanntes PRG und lädt es danach über den nativen
C64-UART-Monitor. Nach dem Upload am C64-Prompt `RUN` eingeben.

Dieser Weg ist absichtlich pragmatisch: er funktioniert für viele Single-load-
oder gecrackte Onefile-D64s. Multi-load-Spiele, Fastloader und echte
IEC/1541-Kompatibilität brauchen später den KERNAL/IEC/1541-Ladepfad.

| Feld / Option | Beschreibung |
|---|---|
| D64 folder | Root-Ordner mit `.d64`-Images; Unterordner werden mitgescannt |
| Filter | Filtert nach relativem Pfad oder Dateiname |
| D64-Liste | Alle gefundenen Images; **Doppelklick lädt direkt hoch** |
| PRG name (optional) | Exakter oder eindeutiger Teilname eines PRG-Eintrags; leer = erstes PRG |
| Port / Baud | Serieller Port und Baudrate für den C64-UART-Monitor |
| Wake byte | Monitor-Magic-Byte, Standard `0xA5` |
| Bytes/line / Line delay | Pacing für den monitorseitigen Hex-Upload; Standard `16` / `0` für schnelle C64-PRG-Uploads |
| Verbose | Monitor-Antworten anzeigen (`--verbose`) |
| Stay in FPGA monitor | Nach Upload nicht mit `G` zurück zur C64-Umgebung springen |
| ▶ Upload Selected D64 PRG | Extrahiert und lädt das ausgewählte D64-PRG |

### News to UART

Ruft `news_to_uart.py` auf.  Holt RSS/Atom-Schlagzeilen und sendet sie fortlaufend an die UART-Konsole des Boards.  EhBASIC oder ein UART-fähiges ROM muss laufen.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate, Standard `115200` |
| Interval (s) | `--interval` | Pause zwischen zwei Schlagzeilen in Sekunden |
| Refresh (s) | `--refresh` | Feed-Aktualisierungsintervall in Sekunden |
| Send one batch and exit | `--once` | Einmalig senden, dann beenden |

---

## Ausgabe-Konsole

Die Konsole streamt die Ausgabe des laufenden Prozesses in Echtzeit.  Farbkodierung:

| Farbe | Bedeutung |
|---|---|
| Grün | Erfolg / Exit-Code 0 |
| Rot | Fehler / Exit-Code ≠ 0 |
| Gelb | Warnungen |
| Blau (Accent) | Prozess-Header |
| Grau (dim) | Kommandozeile / Trennlinien |

Der **Clear**-Button leert die Konsole.

---

## Gleichzeitige Prozesse

Es läuft immer nur **ein Prozess** gleichzeitig.  Wird ein zweiter gestartet, bevor der erste beendet ist, erscheint eine Warnung in der Konsole.  Der **Stop**-Button (`■  Stop`) in der Statuszeile bricht den aktuellen Prozess ab (`SIGTERM`).

---

## Verwandte Werkzeuge (CLI)

| Skript | Funktion |
|---|---|
| `build_fpga_ehbasic.py` | EhBASIC-ROM assemblieren + optional hochladen |
| `build_diag_sdram.py` | SDRAM-Diagnose-ROM assemblieren |
| `make_upload_demo_rom.py` | Demo-ROM erzeugen |
| `upload_monitor_hex.py` | ROM per UART-Monitor hochladen |
| `upload_monitor_hex_enter.py` | Wie oben + automatisches CR nach Start |
| `upload_basic_uart.py` | BASIC-Programm per UART hochladen |
| `make_sd_boot_image.py` | SD-Boot-Image mit Header und CRC erzeugen |
| `build_native_sid_rom.py` | Eine `.sid`-Tune in eine Player-ROM wrappen |
| `build_all_sid_roms.py` | Alle Tunes in `sid_orig/` zu `sound_*.rom` + Upload-Bats bauen |
| `build_sid_prg.py` | Eine `.sid`-Tune als C64-PRG mit BASIC-Header und Segment-Sidecar erzeugen |
| `build_c64_sid_prgs.py` | Alle passenden `.sid`-Tunes als C64-UART-SID-PRGs bauen |
| `c64_uart_prg_loader.py` | C64-PRGs über den nativen C64-UART-Monitor laden; nutzt Segment-Sidecars automatisch |
| `c64_d64_prg_loader.py` | PRG aus einer D64 extrahieren und über den nativen C64-UART-Monitor laden |
| `news_to_uart.py` | RSS-Feed an UART senden |

Alle Skripte lassen sich weiterhin direkt auf der Kommandozeile aufrufen; das GUI ist nur ein bequemer Wrapper.

---

Siehe auch:
- [UART Monitor](./UART_MONITOR.md) — Monitor-Kommandos und Protokoll
- [SD Bootloader](./SD_BOOTLOADER_PLAN.md) — SD-Boot-Image-Format und Boot-Ablauf
- [Building & Synthesis](./03_BUILDING.md) — GHDL-Build und Synthese-Flow
