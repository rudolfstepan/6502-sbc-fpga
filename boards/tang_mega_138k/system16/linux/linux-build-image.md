# Linux-Images fuer System16 GoRV32 Plus bauen

Diese Anleitung beschreibt den reproduzierbaren Stand vom 2026-07-12. Der
Bootpfad ist **SD-first**: ZSBL liegt bei Flash `0x500000` und laedt den
primaeren GRV1-Container von SD-LBA 0. Flash `0x510000` bleibt der Rueckfall;
das grosse ext2-RootFS beginnt bei SD-LBA 32768.

## Profile und Reifegrad

| Profil | Userspace/root | Ergebnis | Hardwarestatus |
| --- | --- | --- | --- |
| `flash` | BusyBox-initramfs im Kernel | `build/gorv32-linux-flash/gorv32-linux-flash.bin` | bestaetigt |
| `rescue` | dasselbe initramfs plus SD-Treiber | `build/gorv32-linux-rescue/gorv32-linux-rescue.bin` | bestaetigt, bevorzugter SD-Test |
| `sd` | ext2 ab physischem LBA 32768 | `build/gorv32-linux-sd/gorv32-linux-sd-boot.bin` und `.img` | Lesen bestaetigt, RootFS absichtlich read-only |
| `qemu-sd` | dasselbe ext2 ueber virtio | WSL-Buildausgabe | RootFS-/Toolchain-Test ohne Board-Hardware |

CMD17-Lesen ist auf dem FPGA bestaetigt. Beide SD-DTBs enthalten
`gowin,read-only`, weil CMD24-Schreiben noch nicht zuverlaessig ist. Das
Buildroot-Image enthaelt zwar Swap und einen nativen GCC, aber beschreibbares
ext2, Swap und Compilerbetrieb sind auf der echten Hardware noch nicht
freigegeben. QEMU kann diese Inhalte unabhaengig vom Board-SD-Host pruefen.

## 1. Voraussetzungen

In WSL installieren:

```sh
sudo apt update
sudo apt install -y \
  build-essential bc bison flex cpio file git rsync unzip wget curl \
  libssl-dev libelf-dev device-tree-compiler e2fsprogs \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu qemu-system-riscv
```

Linux 6.12.95 wird vom Buildskript standardmaessig im ignorierten
Repository-Pfad `third_party/linux-6.12.95` erwartet:

```sh
cd /mnt/d/Development/6502-sbc-fpga
mkdir -p third_party
cd third_party
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.95.tar.xz
tar xf linux-6.12.95.tar.xz
```

OpenSBI 1.8.1 einmalig nach WSL-Home klonen:

```sh
git clone --branch v1.8.1 --depth 1 \
  https://github.com/riscv-software-src/opensbi.git ~/opensbi-system16
```

Buildroot 2025.02 wird von den RootFS-Helfern bei Bedarf automatisch nach
`~/buildroot-2025.02` geladen. Die folgenden `make`-Befehle werden in Windows
PowerShell aus dem Repository-Stamm ausgefuehrt.

## 2. Gemeinsame Boot-Firmware

ZSBL aus den versionierten Quellen bauen:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-zsbl-wsl
```

Ausgabe: `boards/tang_mega_138k/system16/linux/zsbl/zsbl.bin`. Der ZSBL ist
fuer CPU-XIP-Adresse `0x80000000` gelinkt und wird physisch bei Flash
`0x500000` programmiert. `Flash_Burn_Address=500000` im GoRV32-Plus-IP muss
dazu passen.

OpenSBI bauen:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-opensbi-wsl
```

Der Helfer baut RV32IMA mit `zicsr`/`zifencei`, wendet die lokale pre-MDT-
Anpassung idempotent an und verwendet:

| Inhalt | Adresse |
| --- | ---: |
| OpenSBI/`FW_TEXT_START` | `0x00000000` |
| DTB/`FW_JUMP_FDT_ADDR` | `0x003f0000` |
| Linux/`FW_JUMP_ADDR` | `0x00400000` |

## 3. Flash-Profil

Das kleine statische BusyBox-initramfs bauen:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-flash-wsl
```

Es entsteht in WSL unter
`~/buildroot-2025.02/output/images/rootfs.cpio`. Der absolute Pfad in
`linux/system16-flash.config` muss zum WSL-Benutzer passen.

Kernel und GRV1 bauen:

```powershell
make -C boards/tang_mega_138k/system16 kernel-flash-wsl
make -C boards/tang_mega_138k/system16 gorv32-flash-image
```

Ausgabe:

```text
build/gorv32-linux-flash/gorv32-linux-flash.bin
```

Der Packer prueft, dass das komplette GRV1 in den `0x2f0000` Byte grossen
Flashbereich `0x510000..0x7fffff` passt.

## 4. Rescue-Profil: schneller Hardwaretest

Das Rescue-Profil kombiniert das funktionierende initramfs mit dem Board-SD-
Treiber. Userspace startet auch dann, wenn keine Karte steckt oder der Treiber
die Kalibrierung verweigert. Falls das cpio aus Abschnitt 3 noch nicht gebaut
wurde, zuerst einmal `rootfs-flash-wsl` ausfuehren.

```powershell
make -C boards/tang_mega_138k/system16 kernel-rescue-wsl
make -C boards/tang_mega_138k/system16 gorv32-rescue-image
```

Nur diese Datei bei Flash `0x510000` programmieren:

```text
build/gorv32-linux-rescue/gorv32-linux-rescue.bin
```

Die SD-Karte, der Bitstream und ZSBL bleiben unveraendert. Das ist der
empfohlene Ablauf fuer jede weitere SD-Treiberaenderung.

## 5. Automatische SD-Kalibrierung

`linux/kernel/gorv32_sd.c` wird fuer `rescue` und `sd` als built-in Treiber in
Linux 6.12.95 eingefuegt. Beim Probe:

1. Karte mit 200 kHz initialisieren und bei 1 Bit/1 MHz eine Referenz bilden;
   bei Bedarf folgt ein 758-kHz-Fallback.
2. 16 Sektoren zweimal bytegenau und ohne Retry/FIFO-full lesen.
3. Alle 50 Modi testen: 1 und 4 Bit, Divider 0..24, also 25..1 MHz.
4. Kandidaten bei Fehler, Retry, RX-FIFO-full oder Datenabweichung verwerfen.
5. Die drei schnellsten Modi ueber je 64 Sektoren messen und den Sieger erneut
   pruefen.
6. Bei einem spaeteren Retry oder FIFO-full den Takt automatisch halbieren.

Hardwaremessung vom 2026-07-12:

```text
auto calibration selected 1-bit divider 9 (2500000 Hz, 161 KiB/s); 29/50 sweep modes, 3 long-run modes passed
read benchmark: 16 sectors in 42 ms (190 KiB/s), 0 retries, 0 FIFO-full events
1048576 sectors at physical LBA 32768, 1-bit, native word order
```

Die Auswahl wird bei jedem Boot neu gemessen und ist nicht fest vorgegeben.

## 6. SD-RootFS mit Buildroot erstellen

Das versionierte `linux/buildroot/` ist ein BR2_EXTERNAL-Baum. Es erzeugt ein
512-MiB-ext2 mit BusyBox, GNU make, binutils, uClibc-Entwicklungsdateien und
einem nativen RV32-GCC:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-sd-wsl
```

Erwartete Datei:

```text
~/system16-buildroot-sd/images/rootfs.ext2
```

Das Image enthaelt auch eine reale 64-MiB-Datei `/swapfile`. Sie ist fuer den
spaeteren beschreibbaren Betrieb vorgesehen; mit dem aktuellen read-only DTB
wird sie auf der Hardware nicht aktiviert.

Kernel bauen:

```powershell
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
```

Der DTB verwendet aktuell:

```text
root=/dev/gorv32sd ro rootwait rootfstype=ext2
```

Linux sieht nur die 1048576 RootFS-Sektoren. Logischer Sektor 0 von
`/dev/gorv32sd` entspricht physischem SD-LBA 32768; der Bootbereich kann nicht
ueber dieses Blockgeraet ueberschrieben werden.

## 7. QEMU-RootFS-/Toolchain-Test

QEMU verwendet virtio statt des Gowin-Hosts und kann deshalb Dateisystem und
Compiler pruefen, ohne Aussagen ueber das FPGA-SD-Timing zu machen:

```powershell
make -C boards/tang_mega_138k/system16 qemu-sd-test
```

Ein erfolgreicher Lauf endet mit:

```text
QEMU_ROOTFS_OK
QEMU_GCC_OK
QEMU PASS: SD rootfs mounted and native GCC executed a test program
```

## 8. Komplettes SD-Abbild erzeugen

Nur fuer die erste Kartenbereitstellung oder nach RootFS-Aenderungen:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-sd-image
```

Ausgabe:

```text
build/gorv32-linux-sd/gorv32-linux-sd.img
```

Layout:

| Physischer Bereich | Inhalt |
| --- | --- |
| LBA 0 | primaerer GRV1-Header fuer ZSBL v12 |
| ab LBA 1 | sektor-ausgerichtete OpenSBI-/DTB-/Kernel-Daten |
| bis LBA 32767 | reservierter Bootbereich (16 MiB) |
| LBA 32768..1081343 | 512-MiB-ext2-RootFS |

Es gibt keine MBR-/GPT-Partitionstabelle. Das `.img` mit einem Raw-Writer auf
das gesamte SD-Geraet schreiben. Der mitgelieferte PowerShell-Writer verlangt
Datentraegernummer, Seriennummer und exakte Groesse als Schutz gegen ein
falsches Ziel und liest den geschriebenen Bereich anschliessend vollstaendig
fuer einen SHA-256-Vergleich zurueck. Er muss in einer Administrator-Shell
gestartet werden:

```powershell
& boards/tang_mega_138k/system16/tools/write_sd_image.ps1 `
  -ImagePath build/gorv32-linux-sd/gorv32-linux-sd.img `
  -DiskNumber <NUMMER> -ExpectedSerial '<SERIENNUMMER>' `
  -ExpectedSize <GROESSE_IN_BYTES>
```

Der Befehl ueberschreibt den angegebenen Datentraeger ohne Rueckfrage.

## 9. Schnelle Kernel-/Treiber-Iteration

Wenn das RootFS bereits auf der Karte liegt:

```powershell
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-boot-image
```

Danach nur `build/gorv32-linux-sd/gorv32-linux-sd-boot.bin` raw ab SD-LBA 0
schreiben. Das ersetzt nur den Bootbereich vor LBA 32768; `gorv32-sd-image`
ist dafuer nicht noetig und wuerde das grosse Kartenabbild erneut erzeugen.

## 10. Typische Fehler

- **`No working init found`:** Das Flash-initramfs fehlt oder der absolute
  `CONFIG_INITRAMFS_SOURCE`-Pfad passt nicht.
- **`Waiting for root device /dev/gorv32sd`:** Treiberprobe/Kalibrierung ist
  fehlgeschlagen oder der SD-DTB wurde nicht geladen. Zuerst das Rescue-Profil
  verwenden und die `gorv32-sd`-Meldungen sichern.
- **`No such file or directory` fuer `/dev/gorv32sd`:** Bei manueller
  `init=/bin/sh`-Diagnose zuerst `mount -t devtmpfs devtmpfs /dev` ausfuehren.
- **`bad extended attribute` oder Superblock-I/O-Fehler:** Karte neu mit dem
  kompletten `.img` schreiben und bis zur Freigabe von CMD24 nur read-only
  mounten.
- **Kalibrierung findet keinen Modus:** Sie akzeptiert absichtlich keine
  Retries oder FIFO-full-Ereignisse. Rescue-Linux bleibt trotzdem benutzbar.
- **Flash-Fallback zu gross:** Nur die optionale GRV1-Datei bei Flash
  `0x510000` muss unter `0x2f0000` Bytes bleiben; der primaere SD-Boot ist
  nicht an diese Flash-Grenze gebunden.

Die exakten Programmer-Einstellungen stehen in
[gorv32-brennen.md](gorv32-brennen.md).
