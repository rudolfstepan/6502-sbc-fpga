# GoRV32 Plus Linux programmieren (Tang Console 138K)

Der hardwarebestaetigte Stand verwendet **ZSBL v11 flash-first**. Nach dem
Power-on startet die CPU den ZSBL aus dem XIP-Fenster bei CPU-Adresse
`0x80000000`. Der ZSBL laedt normalerweise den GRV1-Container aus Flash
`0x510000`; SD-LBA 0 ist nur noch der Rueckfallpfad.

Der XTX XT25F64B besitzt 8 MiB (JEDEC `0x0b4017`). Adressen ab `0x800000`
liegen ausserhalb des Chips und koennen auf den Bitstream zurueckspiegeln.

## Flash- und SD-Layout

| Ziel | Inhalt | Datei |
| --- | --- | --- |
| Flash `0x000000` | FPGA-Bitstream | `project/impl/pnr/tang138k_system16_gorv32plus.fs` |
| Flash `0x500000` | XIP-ZSBL | `linux/zsbl/zsbl.bin` |
| Flash `0x510000` | primaerer GRV1-Container | profilabhaengige `.bin`, siehe unten |
| SD LBA 0 | optionaler GRV1-Fallback | Anfang von `gorv32-linux-sd.img` |
| SD LBA 32768 | 512-MiB-ext2-RootFS | Rest von `gorv32-linux-sd.img` |

`0x500000` muss zugleich als `Flash_Burn_Address=500000` im GoRV32-Plus-IP
stehen. Der GRV1-Platz von `0x510000` bis `0x7fffff` ist `0x2f0000` Bytes
gross. Die Image-Werkzeuge brechen mit `--require-flash-fit` ab, wenn er nicht
ausreicht.

## Welche GRV1-Datei kommt nach `0x510000`?

| Profil | Datei | Zweck |
| --- | --- | --- |
| `flash` | `build/gorv32-linux-flash/gorv32-linux-flash.bin` | kleinstes initramfs-Linux |
| `rescue` | `build/gorv32-linux-rescue/gorv32-linux-rescue.bin` | initramfs plus read-only SD-Treiber; empfohlener Bring-up |
| `sd` | `build/gorv32-linux-sd/gorv32-linux-sd-boot.bin` | Kernel fuer das externe read-only ext2-RootFS |

Alle drei Container laden OpenSBI nach `0x00000000`, den DTB nach
`0x003f0000` und Linux nach `0x00400000`.

## 1. Bitstream programmieren

Im Gowin Programmer:

- Target Cable: `USB Debugger A/1/4625/null@2MHz`
- Device: `GW5AST-138C`
- Access Mode: **External Flash Mode 5A**
- Operation: **exFlash Erase, Program, Verify 5A**
- Start Address: `0x000000`
- File: `project/impl/pnr/tang138k_system16_gorv32plus.fs`

Der Bitstream muss nur nach FPGA-/IP-Aenderungen neu programmiert werden.

## 2. ZSBL programmieren

ZSBL bauen:

```powershell
make -C boards/tang_mega_138k/system16 gorv32-zsbl-wsl
```

Programmer-Einstellungen:

- Access Mode: **External Flash Mode 5A**
- Operation: **exFlash C Bin Erase, Program, Verify 5A**
- Start Address: `0x500000`
- Firmware/Binary File: `linux/zsbl/zsbl.bin`

Die `.bin`-Endung ist wichtig; andere Endungen interpretiert der Programmer
unter Umstaenden als HEX-Datei und programmiert dann keine Nutzdaten.

## 3. Linux-Payload programmieren

Fuer den sicheren SD-Treibertest:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-flash-wsl  # einmalig
make -C boards/tang_mega_138k/system16 kernel-rescue-wsl
make -C boards/tang_mega_138k/system16 gorv32-rescue-image
```

Danach im Programmer:

- Operation: **exFlash C Bin Erase, Program, Verify 5A**
- Start Address: `0x510000`
- Firmware/Binary File:
  `build/gorv32-linux-rescue/gorv32-linux-rescue.bin`

Das ist der schnelle Entwicklungsweg: Weder SD-Karte noch FPGA-Bitstream oder
ZSBL muessen dabei neu geschrieben werden.

## 4. SD-RootFS einmalig schreiben

Nur bei der ersten Bereitstellung oder nach einer RootFS-Aenderung:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-sd-wsl
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-image
```

`build/gorv32-linux-sd/gorv32-linux-sd.img` mit einem Raw-Writer auf das
**gesamte SD-Geraet** schreiben. Es gibt absichtlich keine MBR-/GPT-Tabelle.
Spaetere Kernel-/Treiber-Aenderungen brauchen kein neues Kartenabbild:

```powershell
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-boot-image
```

Dann nur `gorv32-linux-sd-boot.bin` bei Flash `0x510000` aktualisieren.

## Erwartete UART-Ausgabe

Terminal: **115200 8N1**.

```text
FPGA BOOT OK
System16 GoRV32 ZSBL v11 flash-first
boot from flash
copy $00000000 len $...
copy $003F0000 len $...
copy $00400000 len $...
checksum ok, jump to OpenSBI
OpenSBI v1.8
Linux version 6.12.95 ...
gorv32-sd f0600000.sdhost: auto calibration: testing ...
gorv32-sd f0600000.sdhost: auto calibration selected ...
gorv32-sd f0600000.sdhost: read benchmark: ... 0 retries, 0 FIFO-full events
```

Hardwaremessung vom 2026-07-12: 1 Bit, Divider 9 (`2.5 MHz`), 16 Sektoren
in 42 ms (`190 KiB/s`), keine Retries und kein FIFO-full. Der Wert wird bei
jedem Boot neu bestimmt und kann mit einer anderen Karte abweichen.

## Aktuelle Sicherheitsgrenze

Der Linux-Treiber ist im Rescue- und SD-DTB mit `gowin,read-only` gesperrt.
CMD17-Lesen ist bestaetigt; CMD24-Schreiben, beschreibbares ext2 und Swap auf
der echten Hardware sind noch nicht freigegeben. Das Rescue-Profil bleibt
deshalb der bevorzugte Testweg.
