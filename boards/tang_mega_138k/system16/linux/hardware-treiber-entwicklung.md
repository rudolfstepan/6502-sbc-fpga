# System16: Linux für neue Hardware und Treiber bauen

Dieses Handbuch beschreibt den Entwicklungsweg für neue System16-Hardware am
GoRV32-Plus-Linux-System auf dem Tang Mega 138K. Als Beispiele dienen ein
allgemeiner Koprozessor und der vorhandene REIST-Divisionskern. Es ergänzt die
reine Image-Bauanleitung in [linux-build-image.md](linux-build-image.md).

Die aktuelle Bildausgabe benutzt die System16-Hardware-Textkonsole. Sie ist
kein Linux-Framebuffer im DDR3-Speicher. DDR3 enthält weiterhin Linux und seine
Arbeitsdaten; Textzellen und Konsolenregister sind eigene MMIO-Geräte.

## 1. Was für eine Änderung neu gebaut werden muss

| Änderung | Erforderlicher Neubau |
| --- | --- |
| Verilog/VHDL, Adressdekoder oder Verdrahtung | Bitstream |
| Device Tree | Kernel-Profil und GRV1-Boot-Image |
| eingebauter Linux-Treiber oder Kernel-Konfiguration | Kernel-Profil und GRV1-Boot-Image |
| Programm im Initramfs | Flash-Rootfs, Kernel und GRV1-Boot-Image |
| Programm im ext2-Rootfs | SD-Rootfs beziehungsweise einzelne Datei auf einem später beschreibbaren Rootfs |
| OpenSBI | OpenSBI und GRV1-Boot-Image |
| ZSBL/Bootverfahren | ZSBL |

Ein neuer MMIO-Koprozessor erfordert normalerweise Bitstream, Device Tree,
Treiber, Kernel und Boot-Image. OpenSBI und ZSBL bleiben unverändert.

## 2. Verzeichnisstruktur und Werkzeuge

Die maßgeblichen Dateien liegen hier:

```text
boards/tang_mega_138k/system16/
|-- rtl/sys16_gorv32plus_top.v       GoRV32-Top, Busdekoder, Geräte
|-- project/                         Gowin-Projekt und IP-Konfiguration
|-- linux/
|   |-- build-kernel.sh              profileabhängiger Kernelbau
|   |-- gorv32plus*.dts              Device Trees
|   |-- system16-*.config            Kernel-Konfigurationsfragmente
|   `-- kernel/                       boardeigene Linux-Treiber und Kconfig
|-- tools/                            WSL-Bau- und Image-Hilfen
`-- Makefile                          aufrufbare Windows-Ziele

third_party/linux-6.12.95/            verwendeter Linux-Quellbaum
rtl/reist/                            REIST-Kerne und Dividierer
sim/tb/tb_reist_*.vhd                 REIST-Testbenches
```

Die vom Build erzeugten Linux-Verzeichnisse liegen standardmäßig in WSL:

| Profil | Ausgabeverzeichnis |
| --- | --- |
| `flash` | `~/system16-out` |
| `rescue` | `~/system16-out-rescue` |
| `sd` | `~/system16-out-sd` |
| `qemu-sd` | `~/system16-out-qemu-sd` |

Im WSL-System werden mindestens diese Pakete benötigt:

```sh
sudo apt update
sudo apt install build-essential bc bison flex cpio file git rsync unzip \
  wget curl libssl-dev libelf-dev device-tree-compiler e2fsprogs \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu qemu-system-riscv
```

Der Kernel wird mit `ARCH=riscv` und
`CROSS_COMPILE=riscv64-linux-gnu-` als RV32-Kernel gebaut. Die genaue
Ersteinrichtung für Linux 6.12.95, OpenSBI 1.8.1 und Buildroot 2025.02 steht in
[linux-build-image.md](linux-build-image.md).

## 3. Die vier Linux-Profile

- `flash`: kleines, eingebettetes Initramfs; hardwareverifiziert.
- `rescue`: Initramfs plus read-only SD-Treiber. Dieses Profil ist für neue
  Hardware und Treiber am sichersten, weil ein defekter SD-Treiber das
  Starten der Shell nicht verhindert. Nur dieses Profil enthält zusätzlich
  den eng begrenzten CMD24-Scratch-Test auf physischem LBA 16384.
- `sd`: experimentelles, read-only ext2-Rootfs auf der SD-Karte.
- `qemu-sd`: prüft den generischen RV32-Kernel und das Rootfs, aber keine
  System16-MMIO-Hardware.

Für einen neuen Koprozessor wird zuerst `rescue` verwendet. Erst nach einem
stabilen Probe-, Register- und Fehlertest wird derselbe Treiber im `sd`-Profil
aktiviert.

## 4. Reproduzierbarer Basis-Build

Alle PowerShell-Befehle werden aus dem Repository-Wurzelverzeichnis gestartet.
Ein unveränderter Basis-Build zeigt, ob Toolchain und Arbeitsbaum funktionieren:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-flash-wsl
make -C boards/tang_mega_138k/system16 kernel-rescue-wsl
make -C boards/tang_mega_138k/system16 gorv32-rescue-image
```

Das Ergebnis ist:

```text
boards/tang_mega_138k/system16/build/gorv32-linux-rescue/
  gorv32-linux-rescue.bin
```

Dieses GRV1-Image wird am Flash-Offset `0x510000` programmiert. Ein
Kernel-/Treiber-Neubau ändert nicht den FPGA-Bitstream am Offset `0x000000`
und nicht den ZSBL am Offset `0x500000`.

Bei SD-Treiberarbeiten ist die SD-first-Reihenfolge wichtig: Eine gültige
GRV1-Datei an SD-LBA 0 wird vor dem Flash-Rückfall gestartet. Für den
Rescue-CMD24-Test muss deshalb das neu gebaute Rescue-GRV1 zusätzlich raw an
LBA 0 geschrieben werden; es endet vor LBA 8192, der Scratch-Sektor liegt bei
LBA 16384 und ext2 beginnt bei LBA 32768. Der Test sichert Original und
Sentinels, schreibt ein Muster, liest es zweimal, restauriert das Original mit
einem einzigen CMD24, liest es zweimal und vergleicht die Sentinels. CMD24 wird
nie automatisch wiederholt und `/dev/gorv32sd` bleibt read-only.

Der erste Lauf erfolgt nur mit einer entbehrlichen oder vollständig geklonten
Karte. Nach dem Rescue-Overlay wird ein vollständiges Raw-Abbild als Baseline
erstellt; nach genau einem Boot und der UART-PASS-Zeile wird die ganze Karte
erneut gelesen und mit dieser Baseline verglichen. Zusätzlich muss
`cat /sys/block/gorv32sd/ro` den Wert `1` ausgeben. Allgemeine Schreibzugriffe
sind damit ausdrücklich noch nicht freigegeben.

Der vollständige SD-Build lautet:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-sd-wsl
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-image
```

Er erzeugt
`build/gorv32-linux-sd/gorv32-linux-sd.img`. Das Image wird roh auf das
gesamte SD-Gerät geschrieben, nicht in eine Partition kopiert. Wenn nur
Kernel, Treiber oder DTB geändert wurden, genügt später:

```powershell
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-boot-image
```

## 5. Schnittstelle für einen neuen MMIO-Koprozessor

Der GoRV32-Plus-Core führt seinen 32-Bit-Slave-AXI-Port über
`sys16_axi32_to_bus32` auf einen einfachen internen Bus. Die bestehende
Dekodierung befindet sich in
`rtl/sys16_gorv32plus_top.v`. Ein neues Gerät sollte mindestens diese Signale
besitzen:

```text
req       eine Busanforderung liegt an
we        Schreibzugriff
addr      Registeradresse
be[3:0]   Byte-Schreibmasken
wdata     32-Bit-Schreibdaten
rdata     32-Bit-Lesedaten
ready     Zugriff beendet
```

Wichtige Regeln:

1. Jeder dekodierte Zugriff muss zuverlässig mit `ready` beendet werden.
   Andernfalls bleibt der GoRV32-AXI-Port und damit Linux stehen.
2. Eine lang laufende Division hält den Bus nicht offen. Der START-Schreibzugriff
   endet sofort; Linux fragt anschließend ein BUSY-/DONE-Register ab.
3. Ergebnisse bleiben stabil, bis ein neuer Auftrag angenommen oder ein
   dokumentiertes Acknowledge geschrieben wird.
4. Resetwerte, Byte-Masken, ungültige Register und START während BUSY werden
   explizit definiert und getestet.
5. MMIO liegt außerhalb des DDR3-Adressraums. Datenregister werden über MMIO
   übertragen; DMA kommt erst nach einem separaten Kohärenz- und
   Speicherbesitzkonzept hinzu.

Eine noch freie Beispieladresse für dieses System ist `0xe8800200` mit einer
Fenstergröße von `0x100` Byte. Vor der endgültigen Vergabe muss mit `rg` geprüft
werden, dass keine andere Hardware oder DTS-Datei sie benutzt:

```powershell
rg -n "e8800200|800200" boards/tang_mega_138k/system16
```

Die Auswahl geschieht im Topmodul anhand des vom AXI-Adapter gelieferten
Offsets, analog zur vorhandenen USB-Auswahl. `rdata` und `ready` müssen dann
zwischen Textkonsole, USB und Koprozessor gemultiplext werden. Ein
überlappender oder unvollständiger Dekoder ist ein Systemfehler, kein
Treiberfehler.

## 6. Konkretes REIST-Registermodell

Für einen ersten REIST-Divisionsbeschleuniger ist dieses kleine ABI sinnvoll:

| Offset | Name | Zugriff | Bedeutung |
| ---: | --- | --- | --- |
| `0x00` | `ID` | RO | feste Hardwarekennung und ABI-Version |
| `0x04` | `CTRL` | RW | Bit 0: START; optional später IRQ_ENABLE |
| `0x08` | `STATUS` | RO/W1C | BUSY, DONE, ERROR; DONE optional W1C |
| `0x0c` | `INPUT` | RW | Dividend beziehungsweise REIST-Eingang |
| `0x10` | `DIVISOR` | RW | Divisor beziehungsweise Modulus |
| `0x14` | `QUOTIENT` | RO | Quotient/Ergebnis |
| `0x18` | `REMAINDER` | RO | Rest oder zentrierter Rest |
| `0x1c` | `CYCLES` | RO | Laufzeit des letzten Auftrags |

Die Kennung verhindert, dass ein Treiber mit dem falschen Bitstream arbeitet.
Zusätzlich zur Kennung sollte die ABI-Version in einem festen Bitfeld stehen.
Die Breite und das Vorzeichen jedes Operanden sowie das Verhalten bei Division
durch null müssen Teil der ABI sein.

Im Repository sind bereits zwei Implementierungen relevant:

- `rtl/reist/seq_divider.vhd`: synthetisierbarer sequenzieller Dividierer.
- `rtl/reist/ip_divider.vhd`: Verhaltensmodell für Simulationen.
- `rtl/reist/ip_divider_ip.vhd`: Wrapper um den Gowin-Divisions-IP-Core.
- `rtl/core/peripherals/math_copro.vhd`: bestehendes Koprozessor-Beispiel aus
  dem 6502-System; sein Registerprotokoll ist nicht unverändert für Linux zu
  übernehmen, sein Datapath ist aber wiederverwendbar.

Pro Build darf nur die zum Ziel passende IP-Divider-Variante eingebunden
werden. Vor der Einbindung in System16 werden die vorhandenen Tests ausgeführt:

```powershell
make reist GHDL=<vollständiger-Pfad-zu-ghdl.exe>
```

Dieser Lauf prüft `tb_reist_core` und `tb_reist_bench`. Danach kommt ein neuer
Bus-Testbench hinzu, der mindestens Reset, Teilwortzugriffe, START, BUSY,
DONE, Division durch null, Back-to-back-Aufträge und jeden Registeroffset
prüft. Erst dann wird der Block in das Gowin-Projekt aufgenommen.

Der Bitstream wird mit folgendem Ziel erzeugt:

```powershell
make -C boards/tang_mega_138k/system16 gorv32plus-build
```

Ausgabe:

```text
boards/tang_mega_138k/system16/project/impl/pnr/
  tang138k_system16_gorv32plus.fs
```

## 7. Hardware zunächst ohne Treiber prüfen

BusyBox stellt im Entwicklungs-Rootfs `devmem` bereit. Nach dem Boot des neuen
Bitstreams wird zuerst nur lesend geprüft:

```sh
busybox devmem 0xE8800200 32
busybox devmem 0xE8800208 32
```

Erwartet werden die dokumentierte ID und `BUSY=0`. Danach kann ein einzelner
Testauftrag geschrieben werden:

```sh
busybox devmem 0xE880020C 32 100
busybox devmem 0xE8800210 32 7
busybox devmem 0xE8800204 32 1
busybox devmem 0xE8800208 32
busybox devmem 0xE8800214 32
busybox devmem 0xE8800218 32
```

Die Zahlen werden vom jeweiligen BusyBox-`devmem` interpretiert; für eindeutig
hexadezimale Werte wird `0x...` verwendet. Ein Timeout, Busstillstand oder eine
falsche ID wird auf RTL-/Dekoderebene behoben, bevor ein Linux-Treiber entsteht.

`devmem` ist nur ein Bring-up-Werkzeug. Produktivcode darf nicht unkoordiniert
auf physische Adressen zugreifen.

## 8. Device-Tree-Knoten hinzufügen

Der Kernel erzeugt ein Plattformgerät aus einem DTS-Knoten. Für das obige
Registerfenster:

```dts
reist0: accelerator@e8800200 {
        compatible = "rudolf,system16-reist-v1";
        reg = <0xe8800200 0x100>;
        status = "okay";
};
```

Der Knoten kommt in `gorv32plus-rescue.dts` und nach erfolgreichem Bring-up
auch in `gorv32plus.dts` und `gorv32plus-sd.dts`. `compatible` ist das stabile
Hardware-ABI; es muss exakt mit der OF-Tabelle des Treibers übereinstimmen.
Eine inkompatible Registeränderung erhält `...-v2`, statt unbemerkt dieselbe
Kennung weiterzuverwenden.

Aktuell ist `EXT_INT` im GoRV32-Topmodul mit null verbunden. Deshalb beginnt
der Treiber im Pollingbetrieb und der DTS-Knoten enthält noch kein
`interrupts`. Für Interruptbetrieb sind später drei getrennte Änderungen nötig:

1. IRQ-Ausgang im RTL mit einem freien `EXT_INT`-Eingang verbinden.
2. Die tatsächliche Zuordnung dieses Eingangs im GoRV32/PLIC verifizieren.
3. Erst dann `interrupt-parent` und die verifizierte Interruptnummer im DTS
   sowie `platform_get_irq()` im Treiber ergänzen.

Eine Interruptnummer darf nicht aus der UART-Nummer abgeleitet oder geraten
werden.

## 9. Linux-Plattformtreiber anlegen

Boardeigene Treiber bleiben in
`boards/tang_mega_138k/system16/linux/kernel/`. Für einen Koprozessor ist ein
Platform-Treiber mit `miscdevice` ein einfacher erster ABI-Träger:

```c
struct sys16_reist {
        void __iomem *base;
        struct miscdevice misc;
        struct mutex lock;
};

static const struct of_device_id sys16_reist_of_match[] = {
        { .compatible = "rudolf,system16-reist-v1" },
        { }
};
MODULE_DEVICE_TABLE(of, sys16_reist_of_match);

static int sys16_reist_probe(struct platform_device *pdev)
{
        struct sys16_reist *reist;

        reist = devm_kzalloc(&pdev->dev, sizeof(*reist), GFP_KERNEL);
        if (!reist)
                return -ENOMEM;

        reist->base = devm_platform_ioremap_resource(pdev, 0);
        if (IS_ERR(reist->base))
                return PTR_ERR(reist->base);

        if (readl(reist->base + 0x00) != SYS16_REIST_EXPECTED_ID)
                return dev_err_probe(&pdev->dev, -ENODEV,
                                     "unexpected hardware ID\n");

        /* mutex, miscdevice, file_operations und private data einrichten */
        return 0;
}
```

Das ist bewusst nur das Probe-Grundgerüst. Die Dateioperationen müssen zum
gewählten Userspace-ABI passen. Für einzelne Rechenaufträge eignet sich ein
`ioctl` mit einer Struktur aus `__u32`-Feldern. Der Treiber:

- serialisiert parallele Aufträge mit einem Mutex,
- benutzt ausschließlich `readl()` und `writel()` für MMIO,
- wartet mit einem festen Timeout statt endlos auf DONE,
- liefert `-EBUSY`, `-ETIMEDOUT`, `-EINVAL` und Hardwarefehler sauber zurück,
- kopiert Userspace-Daten mit `copy_from_user()`/`copy_to_user()`,
- prüft vor jedem Auftrag die ABI-/Hardwarekennung,
- gibt keine physischen Register über einen unkontrollierten `mmap` frei.

Für größere Datenmengen wird erst nach einer messbaren Notwendigkeit ein
DMA-Design ergänzt. Dazu gehören Busmaster, Adressbreite, Cache-Kohärenz,
Pinning, Fehlerbehandlung und Speichergrenzen; ein nackter Userspace-Zeiger ist
niemals eine gültige Hardwareadresse.

## 10. Kconfig, Makefile und Build-Skript

Eine neue Datei `kernel/Kconfig.reist` kann so beginnen:

```kconfig
config SYS16_REIST
        bool "System16 REIST accelerator"
        depends on OF && RISCV
        help
          Platform driver for the System16 REIST MMIO accelerator.
```

Im Kernel-Makefile wird daraus:

```make
obj-$(CONFIG_SYS16_REIST) += sys16_reist.o
```

Die bestehende Projektkonvention kopiert die boardeigene Quelle beim Build
idempotent in den externen Kernelbaum. In `build-kernel.sh` wird analog zu
`gorv32_usb_hid.c`, `s16text_con.c` und `gorv32_sd.c` ergänzt:

1. `sys16_reist.c` in ein passendes Linux-Unterverzeichnis kopieren, zum
   Beispiel `drivers/misc/`.
2. `Kconfig.reist` dorthin kopieren.
3. Die Kconfig-`source`-Zeile nur ergänzen, wenn sie noch fehlt.
4. Die `obj-$(CONFIG_SYS16_REIST)`-Zeile nur ergänzen, wenn sie noch fehlt.

Anschließend kommt

```text
CONFIG_SYS16_REIST=y
```

in `system16-rescue.config` beziehungsweise das gemeinsame
`system16-flash.config` und nach der Freigabe in `system16-sd.config`. Die
Treiber sind hier fest in den Kernel eingebaut; `CONFIG_MODULES` ist nicht der
normale System16-Entwicklungsweg.

`build-kernel.sh` führt danach automatisch aus:

```text
allnoconfig
merge_config.sh
olddefconfig
make Image
dtc DTS -> DTB
```

Darum werden manuelle Änderungen in `~/system16-out*/.config` beim nächsten
Build überschrieben. Dauerhafte Optionen gehören in ein versioniertes
`system16-*.config`-Fragment.

## 11. Entwicklungs- und Testschleife

Die empfohlene Reihenfolge verhindert, dass mehrere Fehlerquellen gleichzeitig
untersucht werden müssen:

1. REIST/Datapath isoliert mit GHDL testen.
2. MMIO-Wrapper und Dekoder in einer RTL-Testbench prüfen.
3. Bitstream bauen, Timingbericht und Synthesewarnungen kontrollieren.
4. Nur den neuen Bitstream programmieren und die ID mit `devmem` lesen.
5. Device Tree und minimalistischen Pollingtreiber hinzufügen.
6. `rescue`-Kernel und GRV1-Image bauen und Offset `0x510000` erneuern. Bei
   einem SD-Treibertest wegen SD-first auch das Rescue-GRV1 an SD-LBA 0
   aktualisieren; die Klon-/Baseline-Regel oben beachten.
7. Probe-Log mit `dmesg` prüfen und einen Userspace-Selbsttest ausführen.
8. Fehlerfälle testen: Divisor null, Timeout, START während BUSY, falsche ID,
   mehrere Prozesse und wiederholte Aufträge.
9. Erst danach SD-Profil und optional Interruptbetrieb aktivieren.

Nützliche Prüfungen auf dem Ziel:

```sh
dmesg | grep -i reist
cat /proc/iomem
ls -l /dev/reist0
```

Der Userspace-Selbsttest sollte bekannte Vektoren, Randwerte und zufällige
Vektoren gegen eine Software-Referenz vergleichen. Bei REIST gehören dazu
auch zentrierte Reste an beiden Grenzwerten und die im Paper definierten
Vorzeichenregeln.

## 12. Typische Fehler und ihre Ursache

| Symptom | Wahrscheinliche Ursache |
| --- | --- |
| Linux friert beim ersten Registerzugriff ein | `ready` fehlt, Dekoder überlappt oder falsche Adresse |
| `probe` erscheint nicht in `dmesg` | DTS-Knoten fehlt, falsches `compatible` oder Config nicht `=y` |
| `probe` meldet falsche ID | alter Bitstream, falscher Offset oder falsche Endianness/ABI |
| Treiber kompiliert, ist aber nicht im Kernel | Quelle/Makefile nicht durch `build-kernel.sh` eingebunden |
| Option verschwindet nach Neubau | nur `.config` geändert statt `system16-*.config` |
| sporadisch falsche Resultate | Ergebnis zu früh gelesen, CDC-Fehler oder fehlende Auftragsserialisierung |
| Kernel hängt bei defekter Hardware | Polling ohne Timeout oder Buszugriff wird nicht beendet |
| QEMU-Test ist grün, Hardware funktioniert nicht | QEMU bildet System16-MMIO und Gowin-IP nicht nach |

Bei der Diagnose werden UART-Log, `dmesg`, Device Tree, Bitstream-Zeitstempel
und gelesene Hardware-ID gemeinsam notiert. Damit lässt sich insbesondere ein
alter Bitstream von einem neuen Treiberfehler unterscheiden.

## 13. Fertig-Kriterien für neue Hardware

Ein Koprozessor gilt erst als integriert, wenn:

- RTL- und Bus-Testbenches reproduzierbar bestehen,
- Gowin-Synthese und Timing ohne neue kritische Warnung abschließen,
- Registerkarte und ABI-Version dokumentiert sind,
- jeder Buszugriff terminiert und jeder Pollingpfad einen Timeout besitzt,
- DTS, Kconfig, Treiber und Konfigurationsfragmente versioniert sind,
- der Rescue-Boot auch bei absichtlich fehlerhaftem Auftrag bedienbar bleibt,
- der Userspace-Test Hardware und Software über Rand- und Zufallsvektoren
  vergleicht,
- der exakt dazugehörige Bitstream, Kernel/GRV1 und Teststand festgehalten
  sind.

Generierte Gowin-`impl/`-Dateien, WSL-Kernel-Ausgabebäume und temporäre Images
werden nicht als Quellen behandelt. Eingecheckt werden RTL, Projektquellen,
DTS, Konfigurationsfragmente, Treiber, Tests und Dokumentation.
