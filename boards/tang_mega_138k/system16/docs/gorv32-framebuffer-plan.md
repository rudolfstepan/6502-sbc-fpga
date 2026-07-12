# GoRV32 Plus: Framebuffer als Grafikkarte - Architekturplan

Ziel: Linux-Konsole und Grafik auf HDMI statt nur UART. Der Plan ist
zweistufig - erst ein BSRAM-Framebuffer mit dem fertigen Kernel-Treiber
`simple-framebuffer` (kein eigener Linux-Treiber), danach optional der
Ausbau auf DDR3 mit Blitter. Stand der Ueberlegung: 2026-07-11, nach dem
erfolgreichen SD-Boot-Bring-up.

Umsetzungsstand: Die Stufe-1-Hardware liegt als
`rtl/sys16_fb_ram8.vhd` und `rtl/sys16_hdmi_fb.vhd` vor. Der GoRV32-IP
wurde mit `Enable_AXI_Slave=true` regeneriert und der zweite AXI-Pfad im
Top verdrahtet. Der hardwarebestaetigte Isolation-Build verwendet jedoch
weiterhin `sys16_hdmi_720p` und beantwortet Zugriffe auf das neue Fenster
nur mit Nullen. Damit sind CPU, SD-Boot und das neue IP-Interface gemeinsam
getestet, ohne den noch unbestaetigten Framebuffer-Scanout zu aktivieren.
Die eigentliche Framebuffer-Instanz sowie die Linux-Anbindung stehen noch
aus.

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
| `0xE8000000-0xE80707FF` | Pixeldaten, linear, Stride 1280 Bytes |
| `0xE8800000` | ID/Version (RO) |
| `0xE8800004` | CTRL: Bit0 Enable, Bit1 Testbild |
| `0xE8800008` | STATUS: Bit0 VSync-Flag (RO, fuer Tearing-freie Updates) |

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
    reg = <0xe8000000 0x70800>;
    width = <640>; height = <360>; stride = <1280>;
    format = "r5g6b5";
};
```

Kernel-Optionen zusaetzlich zur bestehenden `system16.config`:

```text
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_FB=y
CONFIG_FB_SIMPLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FONT_SUPPORT=y
CONFIG_FONT_8x16=y
```

`CONFIG_VT` steht heute bewusst auf `n` und muss fuer fbcon auf `y`;
das vergroessert den Kernel etwas (SD-Boot unkritisch, Flash-Fallback
ggf. pruefen). `console=tty0` zusaetzlich zu `console=ttyS0,115200n8`
in den bootargs spiegelt die Konsole auf beide.

Ausgabe auf HDMI, Eingabe weiterhin ueber UART (kein USB-Host im SoC) -
Login bleibt getty auf ttyS0, HDMI zeigt Log + Konsole; `/dev/fb0`
steht Userspace per mmap offen.

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
aber Framebuffer im On-Board-DDR3 statt BSRAM:

- Wiederverwendung der SBC-Erfahrung: Gowin-DDR3-IP, der
  Byte-Bridge-CDC-Fix (3-stufige ram_ready-Synchronisation),
  Framebuffer-Controller mit Full-Line-Fetch in Zeilen-FIFO.
- Bringt: echtes 720p RGB565 (1,8 MB), Doppelpufferung ueber
  PAN-Register, mehrere Framebuffer.
- Blitter-Port aus dem SBC/C64-Projekt (Rect-Copy/Fill/COPYT) als
  Beschleuniger; Linux-Anbindung zunaechst als simples mmap+ioctl
  (uio), kein DRM-Treiber.
- Bekannte Risiken: DDR3-Kalibrierung/Timing auf diesem Board,
  Toolchain-Empfindlichkeit - deshalb erst nach stabiler Stufe 1.

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
