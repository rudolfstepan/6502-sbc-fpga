# GoRV32 Plus: Framebuffer als Grafikkarte - Architekturplan

> **Update 2026-07-12 - Pivot zur Hardware-Textkonsole.** Der DDR3-Pixel-
> Framebuffer lief, aber fbcon-Scrollen war zaeh: jeder Full-Screen-Scroll
> ist ein 259-KB-memmove durch das uncachte E8-Fenster, und alle Zugriffe
> teilen sich EIN DDR3-Interface. Fuer eine Linux-Konsole ist ein
> Hardware-Textmodus fundamental schneller (2 Byte/Zeichen statt hunderte
> Pixelbytes; Scroll = Repaint kleiner Zellzahlen). Der aktive HDMI-Pfad
> ist daher jetzt `sys16_hdmi_text` (80x25, 8x16-VGA-Font, kein DDR3) mit
> dem Linux-consw-Treiber `s16text_con.c`; Details in der Memory
> `system16-hdmi-text-console`. Der Framebuffer-Stack unten bleibt als
> Referenz/Grafikoption erhalten (im Top abgekoppelt, per git reversibel).

Ziel: Linux-Konsole und Grafik auf HDMI statt nur UART. Der Plan ist
zweistufig - erst ein BSRAM-Framebuffer mit dem fertigen Kernel-Treiber
`simple-framebuffer` (kein eigener Linux-Treiber), danach optional der
Ausbau auf DDR3 mit Blitter. Stand der Ueberlegung: 2026-07-11, nach dem
erfolgreichen SD-Boot-Bring-up.

Umsetzungsstand: Die Stufe-1-Hardware liegt als `rtl/sys16_fb_ram8.vhd`
und `rtl/sys16_hdmi_fb.vhd` vor. Der GoRV32-IP wurde mit
`Enable_AXI_Slave=true`, `Flash_R_W_Access=false` und `SRAM_Size=32KB`
regeneriert und der zweite AXI-Pfad im Top verdrahtet. Nach einem
Isolations-Build (ohne Framebuffer, nur `sys16_hdmi_720p`) ist die
Framebuffer-Instanz jetzt bei reduzierter Aufloesung reaktiviert:
480x270 RGB565, 2x zentriert in 720p (960x540, Rand schwarz). Das senkt
die BSRAM-Belegung deutlich (190/340 BSRAM laut P&R statt 94 %) und
gibt der CPU-Domaene Routing-Reserve.

Hardware-Test 2026-07-12: Testbild + Streifen sind auf dem Monitor,
und aus dem gebooteten SD-Linux stimmen ID ("S16F"), CTRL (Reset 0x7)
und der Frame-Zaehler (gemessen exakt 60 Hz). Fuer `devmem` musste
CONFIG_DEVMEM=y in die Kernel-Fragmente (sd + flash) - der Build
startet von allnoconfig, fehlende Optionen sind aus. Naechster
Schritt: Pixel-Schreibtest (CTRL=0x5, Wort-/Byte-Writes, Readback),
danach der Wechsel auf das DDR3-Backend (Stufe 2) vor dem
Linux-Ausbau.

## Andockpunkt: das AXI-Slave-Fenster

Der GoRV32 Plus hat ein bisher deaktiviertes AXI-Slave-Extension-
Interface (MUG1532 Kap. 2): CPU als Master, User-Logik als Slave, fest
gemappt auf `0xE8000000-0xEFFFFFFF` (128 MB). Das ist der vorgesehene
Erweiterungsport fuer eigene Peripherie. Aktivierung im IP Core
Generator ("Enable AXI Slave"), danach exportiert das IP einen zweiten
AXI-Master-Portsatz analog zu den `DDR_*`-Ports; exakte Portnamen nach
der Regeneration aus `gowin_gorv32_plus_tmp.v` uebernehmen.

Der vorhandene `sys16_axi32_to_bus32` ist ein generischer
AXI4-Slave-zu-req/ready-Wandler und wird unveraendert ein zweites Mal
instanziert - dahinter haengt statt der SDRAM der Framebuffer-Block.

## Stufe 1: BSRAM-Framebuffer 640x360 RGB565

### Aufloesung und Format

- **640x360, RGB565, 450 KB (0x70800 Bytes)** - exakt 1/2 x 1/2 von
  720p. Der Scanout verdoppelt Pixel und Zeilen (Integer-Skalierung,
  pixelperfekt). 3,7 Mbit BSRAM von ~8 Mbit des GW5AST-138; das IP
  selbst belegt ~50 Bloecke. Muss der P&R-Report bestaetigen.
- Fallback bei BSRAM-Knappheit: 480x270 RGB565 (2,1 Mbit), Skalierung
  dann nicht ganzzahlig zu 720p - eher Aufloesung halten und andere
  Verbraucher pruefen.
- RGB565 statt 8bpp+Palette, weil `simple-framebuffer` nur
  True-Color-Formate kann ("r5g6b5") - 8bpp braeuchte einen eigenen
  fbdev-Treiber mit Palettenregister.

### Adressraum

| CPU-Adresse | Inhalt |
| --- | --- |
| `0xE8000000-0xE803F47F` | Pixeldaten, linear, Stride 960 Bytes (480x270 RGB565) |
| `0xE8800000` | ID/Version (RO), liest "S16F" = 0x53313646 |
| `0xE8800004` | CTRL: Bit0 Enable, Bit1 Testbild, Bit2 Diagnose-Streifen |
| `0xE8800008` | STATUS: Bit0 VBlank, [31:16] Frame-Zaehler (RO) |

Spaeter (Doppelpufferung): PAN-Register mit Basisadresse fuer den
Scanout.

### RTL-Bausteine

| Modul | Status | Aufgabe |
| --- | --- | --- |
| `sys16_axi32_to_bus32` | vorhanden, 2. Instanz | AXI-Slave-Fenster -> req/ready-Bus |
| `sys16_fb_bsram` | neu | True-Dual-Port-BSRAM 115200x32 mit Byte-Enables; Port A CPU (50 MHz), Port B Scanout (74,25 MHz) |
| `sys16_fb_regs` | neu, winzig | CTRL/STATUS/ID-Decoder im selben Fenster |
| `sys16_hdmi_720p` | umbauen | Farbbalken-Generator raus, Zeilen-Fetch + 2x-Verdoppler rein; Diagnose-Streifen bleibt als Overlay (oberste 48 Zeilen, per CTRL abschaltbar) |

Die Dual-Port-BSRAM mit zwei unabhaengigen Takten ist zugleich die
CDC-Grenze - kein Handshake noetig. CTRL-Bits laufen ueber
2FF-Synchronizer in die Pixeldomaene (gleiches Muster wie heute
`status_meta/status_sync`). Byte-Enables: `wstrb` kommt als `be` aus
der Bridge und geht direkt auf die BSRAM-Byte-Write-Enables - fbcon
schreibt auch einzelne Bytes.

Scanout-Budget: durch die 2x-Verdopplung effektiv ein 32-Bit-Lesezugriff
pro zwei Pixeltakte, Zeilen werden fuer die Wiederholung aus einem
kleinen Zeilenpuffer (oder erneutem Fetch) ausgegeben - unkritisch bei
74,25 MHz.

### Timing/Constraints

`pix_clk`/`pix_clk_5x` sind seit dem Timing-Aufraeumen benannte Clocks
mit Async-Gruppe gegen `clk_50mhz` (SDC). Die BSRAM-Ports liegen sauber
je in einer Domaene; neue Constraints sind voraussichtlich nicht noetig.

### Linux-Integration (kein eigener Treiber)

DTS-Node (Variante `gorv32plus-fb.dts`; der Import-Wrapper kann per
`--dts`/`--dtb-name` bereits alternative DTS bauen):

```dts
framebuffer@e8000000 {
    compatible = "simple-framebuffer";
    reg = <0xe8000000 0x3f480>;
    width = <480>; height = <270>; stride = <960>;
    format = "r5g6b5";
};
```

Kernel-Optionen fuer `/dev/fb0` zusaetzlich zur bestehenden Konfiguration:

```text
CONFIG_FB=y
CONFIG_FB_SIMPLE=y
```

Die Hardwareprofile aktivieren `CONFIG_VT`, `CONFIG_VT_CONSOLE`,
`CONFIG_FRAMEBUFFER_CONSOLE` und den 8x16-Font. Kernelmeldungen erscheinen
damit parallel auf fbcon und ttyS0. Buildroot startet zusaetzlich zum
seriellen `console`-Getty einen Getty auf `tty1`, damit die HDMI-Ausgabe
nach dem Wechsel vom Kernel zu `/init` nicht stehen bleibt.

Ausgabe und Login-Prompt stehen auf HDMI und UART bereit; die Eingabe bleibt
ohne einen angeschlossenen Eingabetreiber praktisch auf UART. Anwendungen
koennen weiterhin direkt ueber `/dev/fb0` zeichnen.

### Performance-Erwartung

Das E8-Fenster ist Peripherie-Adressraum, erwartet uncached: jeder
Store einzeln ueber AXI, grob 20-40 MB/s bei 50 MHz. Zeichenrendering
fluessig, Full-Screen-Scroll (450 KB) ~15-25 ms - als Konsole gut
brauchbar. Verifikation des Cache-Verhaltens ist Bring-up-Schritt 3;
waere das Fenster wider Erwarten write-back-gecached, braucht es
fence/Flush-Ueberlegungen (dann fruehzeitig neu bewerten).

### Bring-up-Reihenfolge

1. IP mit "Enable AXI Slave" regenerieren; neue Ports im Top verdrahten
   (Namen aus `gowin_gorv32_plus_tmp.v`).
2. `sys16_fb_bsram` + `sys16_fb_regs` + Scanout-Umbau; Testbild-Bit.
3. **Ohne Linux testen:** ZSBL schreibt ein paar Muster nach
   `0xE8000000` und setzt CTRL - sofort am Monitor sichtbar. Dabei
   auch pruefen: Lesen zurueck (Bridge-Pfad), Byte-Writes, Verhalten
   bei Bursts.
4. DTS-Variante + Kernel-Optionen, fbcon auf HDMI.

### Ressourcen/Risiken Stufe 1

- BSRAM-Budget 640x360: ~205 Bloecke Framebuffer + ~50 IP + Rest;
  P&R-Report entscheidet. Fallback siehe oben.
- Verhalten des AXI-Slave-Ports bei Bursts/Outstanding: die Bridge
  serialisiert (ein Transfer offen) - korrekt, nur langsamer.
- fbcon-Scrollgefuehl bei uncached Stores: akzeptiert; Optimierung
  (Panning, Blitter) ist Stufe 2.

## Stufe 2: DDR3-Backend + Blitter (Ausbau)

Gleiche CPU-Schnittstelle (AXI-Slave-Fenster, gleiche Registermap),
aber Framebuffer im On-Board-DDR3 statt BSRAM. Motivation neben 720p:
die vier BSRAM-Baenke (~116 Bloecke bei 480x270) dominieren
P&R-Laufzeit und Routing-Budget; mit DDR3 schrumpft das auf die
IP-FIFOs (~10 Bloecke) plus einen Zeilenpuffer.

Umsetzungsstand 2026-07-12: implementiert, Build und Hardware-Test
stehen aus. Neu ist `rtl/sys16_fb_ddr3.vhd` (CPU-CDC, Zeilen-Prefetch,
App-Engine); `sys16_hdmi_fb` waehlt per Generic `FB_DDR3` (default
true) zwischen DDR3- und BSRAM-Backend, Registermap und Scanout sind
identisch. Top, CST (Pins + INS_LOC fuer beide PLLs/DLL/fclkdiv), SDC
(ddr_mem/ddr_clk_x1 + PHY-False-Paths) und .gprj sind verdrahtet; die
GHDL-Testbench `sim/tb/tb_sys16_fb_ddr3.vhd` deckt CPU-Handshake
(inkl. Unkalibriert-Ack und Retrigger-Race), Byte-Enables und beide
Zeilenpuffer-Haelften ab. led[0] zeigt jetzt die DDR3-Kalibrierung,
STATUS bit1 meldet sie an Software.

### Wiederverwendung aus boards/tang_mega_138k/sbc

Der 138K-SBC faehrt den kompletten DDR3-Stack bereits (Bring-up nach
dem Sipeed-Referenzdesign, mit Kalibrier-Retry):

| Baustein | Quelle | Anmerkung |
| --- | --- | --- |
| `DDR3_Memory_Interface_Top` | `sbc/project/src/ddr3_memory_interface/` | 32-bit-DDR3; ref 50 MHz, memory 400 MHz, User-Takt `clk_out` = 100 MHz; App-Beats 256 bit, der SBC nutzt davon die unteren 128 bit (obere Haelfte per Mask tot) |
| `Gowin_DDR_PLL` | `sbc/project/src/gowin_pll/gowin_ddr_pll.v` | 50 -> 400 MHz, freilaufend (reset fest '0'), `pll_stop`-Handshake mit dem IP |
| Reset-/Kalibrier-Sequencer | `tang138k_sbc_top.vhd`, Prozess `ddr_reset_seq` | Reset-Hold nach PLL-Lock, Timeout -> automatischer Retry; ersetzt manuelle Reset-Druecke bei marginaler Kalibrierung |
| DDR3-Pinout | `sbc/constraints/tang138k_sbc.cst` | DDR3 sitzt auf dem Core-Modul, Pins fuer Console und Mega-Dock identisch |
| Schreib-/Lese-Engine | `rtl/core/peripherals/vic_fb_ddr3.vhd` | Vorlage fuer maskierte BL8-Einzelbeats (CPU-Pfad) und Zeilen-Fetch; nicht 1:1 uebernehmen (VIC-Geometrien, Palette, Blitter), sondern schlank neu als `sys16_fb_ddr3` |

### Umbau in sys16_hdmi_fb

Registermap, Bus-FSM-Kontrakt und Scanout-Timing bleiben; nur der
Speicher dahinter wechselt (Generic `FB_DDR3`, analog `USE_DDR3` im
SBC-Top; `sys16_fb_ram8` bleibt als BSRAM-Fallback im Baum):

- CPU-Pfad: bus32-Zugriff (50 MHz) -> req/ack-Handshake mit
  3-stufiger Synchronisation (der bekannte ddr3_byte_bridge-Fix) ->
  maskierter BL8-Einzelbeat auf dem App-Interface (100 MHz). `be`
  wird direkt zur Write-Mask, kein Read-Modify-Write noetig.
- Scanout: Zeilen-Fetch waehrend hblank in einen
  Dual-Clock-Zeilenpuffer (1-2 BSRAM), die Pixeldomaene liest wie
  bisher. 480x270: 960 Bytes = 60 Bursts pro Doppelzeile bei
  100 MHz x 16 Byte - weit unter dem hblank-Budget; auch natives
  720p (2560 Bytes/Zeile) waere bandbreitenseitig problemlos.
- Drei Taktdomaenen: 50 (Bus) / 100 (App) / 74,25 (Pixel).
  CDC-Grenzen sind genau der req/ack-Handshake und der Zeilenpuffer.

### Aufloesung

Ohne BSRAM-Limit ist 640x360 RGB565 (integer 2x nach 720p) wieder
das Ziel; erster Schritt bleibt 480x270, weil DTS und Test dafuer
schon stehen (nur Speicherort wechselt, Software merkt nichts).
Natives 720p ist moeglich, aber fbcon-Scroll (1,8 MB uncached) wird
zaeh - erst mit Blitter sinnvoll.

- Bringt weiterhin: Doppelpufferung ueber PAN-Register, mehrere
  Framebuffer, spaeter der Blitter-Port aus dem SBC/C64-Projekt
  (Rect-Copy/Fill/COPYT); Linux-Anbindung zunaechst mmap+ioctl (uio),
  kein DRM-Treiber.
- CPU-Rueckleseweg wird langsamer als BSRAM (voller Umlauf ueber
  beide Domaenen); fbcon liest nur beim Scrollen (memmove) -
  akzeptabel.

### Risiken

- PLL-Haushalt: HDMI-PLL + DDR-PLL + GoRV32-interne Takte im selben
  Design; der SBC loest das mit freilaufender DDR-PLL ohne
  Fabric-Last aus PLL-abgeleiteten Takten im Sequencer.
- DDR3-Kalibrierung am Powerup gelegentlich marginal - der
  Retry-Sequencer deckt das ab.
- Vendor-IP-Pads (QSPI/SD) bleiben unberuehrt; die DDR3-Pads sind
  davon getrennt, kein EX0339-Risiko.

Denkbarer Folgeausbau (separates Vorhaben): auch das DDR-AXI-Fenster
(Linux-Hauptspeicher, heute 16-bit-SDRAM ueber
`sys16_bus32_to_sdram16`) auf das DDR3 legen - braucht einen Arbiter
am App-Interface, hebt aber die CPU-Speicherbandbreite um eine
Groessenordnung.

## Bewusst verworfen

- **Scanout aus der 16-Bit-SDRAM:** 640x360@60 braucht 27 MB/s
  Dauerbandbreite, 720p 110 MB/s; der Single-Beat-Controller liefert
  effektiv 10-20 MB/s und teilt sie mit der CPU. Mit
  Full-Page-Bursts + Arbiter technisch machbar, aber es verhungert
  die ohnehin knappe CPU-Bandbreite. BSRAM entkoppelt vollstaendig.
- **Text-Mode-Hardware (Zeichen-RAM + Font-ROM):** spart RAM, aber
  Linux hat dafuer keinen Standardtreiber - fbcon ueber simplefb ist
  softwareseitig der kleinere Aufwand.
- **8bpp mit Palette:** kein simplefb-Format, braeuchte einen eigenen
  fbdev-Treiber.

## Offene Punkte vor Beginn

1. Exakter ipc-Schluessel fuer den AXI-Slave (analog `Enable_AXI_DDR`;
   nach GUI-Regeneration aus der .ipc ablesen) und die neuen Portnamen.
2. BSRAM-Bestand nach P&R mit 640x360 - Report pruefen.
3. Cache-Verhalten des E8-Fensters empirisch bestaetigen (Schritt 3).
4. Kernel-Groessenzuwachs durch VT/FB fuer den Flash-Fallback messen
   (`--require-flash-fit` im Packer meldet es).
