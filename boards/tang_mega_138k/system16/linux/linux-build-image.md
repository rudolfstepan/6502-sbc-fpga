# Linux-Image fuer System16 GoRV32 Plus bauen

Diese Anleitung erzeugt genau das Linux-Image, das der aktuelle System16-
GoRV32-Plus-Bootloader erwartet. Das Ergebnis ist
`build/gorv32-linux/gorv32-flash.bin`: ein GRV1-Container mit OpenSBI,
Device Tree und Linux-Kernel samt eingebettetem BusyBox-initramfs.

Das Image wird primaer roh ab LBA 0 auf die SD-Karte geschrieben. Dieselbe
Datei kann optional bei Flash-Adresse `0x510000` als Fallback abgelegt werden.
Sie ist kein Dateisystem-Image und enthaelt weder MBR noch Partitionstabelle.

## 1. Verzeichnis- und Versionskonventionen

Die vorhandenen Hilfsskripte verwenden folgende Pfade in der Standard-WSL-
Distribution:

| Komponente | Version/Pfad |
| --- | --- |
| Linux | 6.12.95, Quelle `~/linux-6.12.95` |
| Linux-Ausgabe | `~/system16-out` |
| Buildroot | 2025.02, `~/buildroot-2025.02` |
| BusyBox-cpio | `~/buildroot-2025.02/output/images/rootfs.cpio` |
| OpenSBI | 1.8.1, Quelle `~/opensbi-system16` |
| OpenSBI-Ausgabe | `~/opensbi-system16/build-gorv32` |
| Windows-Import | Repository `build/gorv32-linux` |

Die folgenden Beispiele gehen davon aus, dass das Repository unter
`D:\Development\6502-sbc-fpga` liegt. In WSL ist dasselbe Verzeichnis unter
`/mnt/d/Development/6502-sbc-fpga` sichtbar.

## 2. Voraussetzungen in WSL installieren

In WSL ausfuehren:

```sh
sudo apt update
sudo apt install -y \
  build-essential bc bison flex cpio file git rsync unzip wget curl \
  libssl-dev libelf-dev device-tree-compiler \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
  qemu-system-riscv
```

Danach muessen mindestens diese Programme gefunden werden:

```sh
riscv64-linux-gnu-gcc --version
dtc --version
qemu-system-riscv32 --version
```

Der `riscv64-linux-gnu`-Compiler erzeugt mit `-march=rv32...` und
`-mabi=ilp32` den benoetigten 32-Bit-Code. Ein separater RV32-Compiler ist
nicht erforderlich.

## 3. Linux- und OpenSBI-Quellen vorbereiten

Einmalig in WSL:

```sh
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.95.tar.xz
tar xf linux-6.12.95.tar.xz

git clone --depth 1 --branch v1.8.1 \
  https://github.com/riscv-software-src/opensbi.git \
  ~/opensbi-system16
```

Buildroot wird im naechsten Schritt automatisch heruntergeladen. Bereits
vorhandene Verzeichnisse muessen nicht erneut angelegt werden.

## 4. Kleines Root-Dateisystem erzeugen

In Windows PowerShell vom Repository-Stamm aus:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-wsl
```

Das Skript erstellt mit Buildroot ein statisch gelinktes RV32IMA-BusyBox auf
Basis von uClibc-ng. Das relevante Ergebnis ist:

```text
/home/rudolf/buildroot-2025.02/output/images/rootfs.cpio
```

Genau dieser absolute Pfad steht momentan in
`linux/system16.config` unter `CONFIG_INITRAMFS_SOURCE`. Wird unter einem
anderen WSL-Benutzer gebaut, muss diese eine Zeile vor dem Kernel-Build auf
dessen Home-Verzeichnis angepasst werden. Fehlt die cpio-Datei, kann der
Kernel zwar starten, endet aber mit `No working init found`.

Pruefung in WSL:

```sh
ls -lh ~/buildroot-2025.02/output/images/rootfs.cpio
```

## 5. Linux-Kernel bauen

In WSL:

```sh
cd /mnt/d/Development/6502-sbc-fpga/boards/tang_mega_138k/system16/linux

KERNEL_SRC=~/linux-6.12.95 \
KERNEL_OUT=~/system16-out \
CROSS_COMPILE=riscv64-linux-gnu- \
./build-kernel.sh
```

Das Skript beginnt mit `allnoconfig`, mischt anschließend
`linux/system16.config` ein und baut einen kleinen, statisch konfigurierten
RV32IMA-Kernel. Unter anderem sind aktiviert:

- RV32 mit MMU/Sv32 und SBI;
- ein CPU-Hart, ohne SMP;
- 8250/16550-Konsole und SBI-Earlycon;
- eingebettetes gzip-initramfs;
- procfs, sysfs und tmpfs;
- keine Module, Netzwerk-, Grafik-, Audio-, USB- oder PCI-Treiber.

Erwartete Ausgaben:

```text
~/system16-out/arch/riscv/boot/Image
~/system16-out/system16-rv32.dtb
```

Der zweite DTB gehoert zum experimentellen VexRiscv-Profil. Der passende
GoRV32-Plus-DTB wird spaeter beim Import direkt aus `gorv32plus.dts` erzeugt.

Pruefung:

```sh
ls -lh ~/system16-out/arch/riscv/boot/Image
grep '^CONFIG_INITRAMFS_SOURCE=' ~/system16-out/.config
```

## 6. Kernel optional mit QEMU pruefen

In Windows PowerShell:

```powershell
make -C boards/tang_mega_138k/system16 qemu-test
```

Der Test startet das gerade gebaute `~/system16-out/.../Image` auf QEMUs
RV32-`virt`-Maschine und erwartet die Meldung `Linux version`. Damit werden
Kernel und initramfs geprueft, nicht jedoch die System16-spezifischen QSPI-,
SD-, UART- und SDRAM-Pfade.

## 7. ZSBL bauen

Der Zero Stage Boot Loader ist kein externes Binaerpaket. Seine benoetigten
Quellen gehoeren zum Repository und muessen zusammen mit dem restlichen
System16-Stand ausgecheckt sein:

| Datei | Aufgabe |
| --- | --- |
| `linux/zsbl/crt.S` | Reset-Einstieg, Stackaufbau, Hart-0/Hart-1-Behandlung |
| `linux/zsbl/main.c` | UART, SD-Initialisierung, GRV1-Lader, Flash-Fallback und Pruefsumme |
| `linux/zsbl/zsbl.lds` | XIP-Linkerlayout ab CPU-Adresse `0x80000000` |
| `linux/zsbl/build.sh` | reproduzierbarer freestanding RV32IMA-Build |

Der Windows-Helper `tools/build_gorv32_zsbl_wsl.py` ruft dieses `build.sh` in
WSL auf. Als einzige externe Voraussetzung wird derselbe
`riscv64-linux-gnu`-Cross-Compiler wie fuer OpenSBI verwendet.

In Windows PowerShell:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-zsbl-wsl
```

Ergebnis:

```text
boards/tang_mega_138k/system16/linux/zsbl/zsbl.bin
boards/tang_mega_138k/system16/linux/zsbl/zsbl.elf
```

`zsbl.bin` ist das zu programmierende Raw-Binaerabbild. `zsbl.elf` enthaelt
Symbole und Sections fuer Disassemblierung und Fehlersuche. Beide Dateien sind
erzeugte Artefakte und werden nicht committed; die vier Quelldateien oben
werden versioniert.

Der ZSBL ist fuer CPU-Adresse `0x80000000` gelinkt und wird bei physischer
Flash-Adresse `0x500000` programmiert. Diese Adresse muss mit
`Flash_Burn_Address=500000` in der GoRV32-Plus-IPC uebereinstimmen.

## 8. OpenSBI fuer GoRV32 Plus bauen

In Windows PowerShell:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-opensbi-wsl
```

Der Helper passt OpenSBI fuer die vom Core implementierte pre-MDT-Privilege-
Architektur an und baut `fw_jump` mit diesen entscheidenden Adressen:

| Option | Wert |
| --- | ---: |
| `FW_TEXT_START` | `0x00000000` |
| `FW_JUMP_ADDR` | `0x00400000` |
| `FW_JUMP_FDT_ADDR` | `0x003f0000` |
| ISA | `rv32ima_zicsr_zifencei` |

Erwartete Dateien in WSL:

```text
~/opensbi-system16/build-gorv32/platform/generic/firmware/fw_jump.elf
~/opensbi-system16/build-gorv32/platform/generic/firmware/fw_jump.bin
```

Die Entry-Adresse muss null sein:

```sh
riscv64-linux-gnu-readelf -h \
  ~/opensbi-system16/build-gorv32/platform/generic/firmware/fw_jump.elf \
  | grep 'Entry point'
```

Erwartet wird `Entry point address: 0x0`.

## 9. GRV1-Image erzeugen

In Windows PowerShell:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-flash-image
```

Dieses Target fuehrt zwei Schritte aus:

1. `gorv32-import` kontrolliert die OpenSBI-Entry-Adresse, importiert
   `fw_jump.bin` und den Kernel aus WSL und kompiliert `gorv32plus.dts`.
2. `make_gorv32_flash_image.py` packt die drei Nutzdaten in den
   sektor-ausgerichteten GRV1-Container und berechnet die Pruefsumme.

Die Ladeadressen sind fest:

| Record | SDRAM-Adresse |
| --- | ---: |
| OpenSBI | `0x00000000` |
| GoRV32-Plus-DTB | `0x003f0000` |
| Linux mit initramfs | `0x00400000` |

Das fertige Image liegt hier:

```text
build/gorv32-linux/gorv32-flash.bin
```

Beim dokumentierten erfolgreichen Build waren die Artefakte:

```text
fw_jump.bin        270360 Bytes
gorv32plus.dtb       1699 Bytes
Image             2552320 Bytes
gorv32-flash.bin  2825728 Bytes
```

Die Groessen koennen sich nach Konfigurationsaenderungen verschieben. Der
Packer verweigert Ueberlappungen und meldet, wenn das Image groesser als der
optionale Flash-Fallback-Bereich von `0x2f0000` Bytes ist. Fuer den SD-Boot
gilt diese engere Flash-Grenze nicht; Kernel und initramfs muessen aber immer
in das SDRAM-Fenster bis `0x00ffffff` passen.

## 10. Image verwenden

Fuer den normalen Start wird `gorv32-flash.bin` mit einem Raw-Writer auf das
gesamte SD-Geraet ab Sektor 0 geschrieben. Nicht in eine Partition und nicht
als normale Datei auf ein FAT-Dateisystem kopieren.

Die FPGA-/Flash-Belegung ist:

| Ziel | Datei | Adresse |
| --- | --- | ---: |
| FPGA-Bitstream | `tang138k_system16_gorv32plus.fs` | Flash `0x000000` |
| ZSBL | `linux/zsbl/zsbl.bin` | Flash `0x500000` |
| primaeres Linux-Image | `gorv32-flash.bin` | SD ab LBA 0 |
| optionaler Fallback | `gorv32-flash.bin` | Flash `0x510000` |

Die genauen Gowin-Programmer-Einstellungen stehen in
[gorv32-brennen.md](gorv32-brennen.md).

## 11. Erwartete Bootmeldungen

Bei erfolgreichem SD-Boot:

```text
FPGA BOOT OK
System16 GoRV32 ZSBL v10
SD v2 card
boot from SD
copy $00000000 len $...
copy $003F0000 len $...
copy $00400000 len $...
checksum ok, jump to OpenSBI
OpenSBI v1.8
[    0.000000] Linux version ...
```

Kann der ZSBL das GRV1-Image nicht von SD lesen, meldet er den Fehler und
versucht automatisch den Inhalt ab Flash `0x510000`. Die Meldung lautet dann
`boot from flash`.

## 12. Was muss nach einer Aenderung neu gebaut werden?

| Geaendert | Erforderliche Schritte |
| --- | --- |
| BusyBox/rootfs | `rootfs-wsl`, Kernel, `gorv32-flash-image` |
| Kernel-Konfiguration oder Kernel | Kernel, `gorv32-flash-image` |
| `gorv32plus.dts` | nur `gorv32-flash-image` |
| OpenSBI | `gorv32-opensbi-wsl`, `gorv32-flash-image` |
| ZSBL | `gorv32-zsbl-wsl`, danach nur ZSBL neu flashen |
| FPGA-RTL oder GoRV32-IP | `gorv32plus-build`, Bitstream neu laden/flashen |

Fuer normale Kernel-, DTB- oder OpenSBI-Iterationen muessen weder FPGA noch
ZSBL neu gebaut werden. Es genuegt, das neue GRV1-Image auf die SD-Karte zu
schreiben.

## Typische Fehler

- **`No working init found`:** Das initramfs fehlte beim Kernel-Build oder
  `CONFIG_INITRAMFS_SOURCE` zeigt auf den falschen WSL-Benutzer.
- **OpenSBI-Entry nicht `0x0`:** `gorv32-opensbi-wsl` erneut ausfuehren; nicht
  das fuer VexRiscv bei `0x2000` gelinkte `fw_jump.bin` verwenden.
- **ZSBL startet nicht:** `zsbl.bin` liegt nicht bei `0x500000` oder die
  `Flash_Burn_Address` der IPC stimmt nicht damit ueberein.
- **`no GRV1 image on SD`:** Image wurde nicht roh ab LBA 0 geschrieben.
- **Image passt nicht in den Flash-Fallback:** SD-Boot verwenden oder Kernel/
  initramfs verkleinern. Niemals ueber die physische 8-MB-Flash-Grenze bei
  `0x800000` schreiben.
