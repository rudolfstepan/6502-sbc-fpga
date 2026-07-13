# GoRV32 Plus Linux programmieren (Tang Console 138K)

Der aktuelle Stand verwendet **ZSBL v12 SD-first**. Nach dem
Power-on startet die CPU den ZSBL aus dem XIP-Fenster bei CPU-Adresse
`0x80000000`. Der ZSBL laedt normalerweise den GRV1-Container von SD-LBA 0;
Flash `0x510000` ist der Rueckfallpfad.

Der XTX XT25F64B besitzt 8 MiB (JEDEC `0x0b4017`). Adressen ab `0x800000`
liegen ausserhalb des Chips und koennen auf den Bitstream zurueckspiegeln.

## Flash- und SD-Layout

| Ziel | Inhalt | Datei |
| --- | --- | --- |
| Flash `0x000000` | FPGA-Bitstream | `project/impl/pnr/tang138k_system16_gorv32plus.fs` |
| Flash `0x500000` | XIP-ZSBL | `linux/zsbl/zsbl.bin` |
| Flash `0x510000` | optionaler GRV1-Rueckfall | profilabhaengige `.bin`, siehe unten |
| SD LBA 0 | primaerer GRV1-Container | Anfang von `gorv32-linux-sd.img` |
| SD LBA 16384 | Rescue-only CMD24-Scratch-Sektor | ungenutzte Luecke; kein Dateisystem |
| SD LBA 32768 | 512-MiB-ext2-RootFS | Rest von `gorv32-linux-sd.img` |

`0x500000` muss zugleich als `Flash_Burn_Address=500000` im GoRV32-Plus-IP
stehen. Der GRV1-Platz von `0x510000` bis `0x7fffff` ist `0x2f0000` Bytes
gross. Die Image-Werkzeuge brechen mit `--require-flash-fit` ab, wenn er nicht
ausreicht.

## Welche GRV1-Datei kann als Flash-Rueckfall nach `0x510000`?

| Profil | Datei | Zweck |
| --- | --- | --- |
| `flash` | `build/gorv32-linux-flash/gorv32-linux-flash.bin` | kleinstes initramfs-Linux |
| `rescue` | `build/gorv32-linux-rescue/gorv32-linux-rescue.bin` | initramfs plus read-only SD-Treiber; isolierter CMD24-Scratch-Test |
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

Das ist der schnelle Rueckfallweg: FPGA-Bitstream und ZSBL muessen nicht neu
geschrieben werden. Eine gueltige GRV1-Datei auf SD-LBA 0 hat wegen SD-first
jedoch Vorrang. Fuer den folgenden CMD24-Test muss deshalb auch der neue
Rescue-Container an SD-LBA 0 liegen.

## 4. Rescue-CMD24-Scratch-Test

Der erste Test darf nur mit einer entbehrlichen oder vollstaendig geklonten
Karte erfolgen. Er ist kein Freigabetest fuer beschreibbares ext2. In einer
Administrator-PowerShell den Rescue-Container mit dem abgesicherten Writer raw
an LBA 0 schreiben:

```powershell
& boards/tang_mega_138k/system16/tools/write_sd_image.ps1 `
  -ImagePath build/gorv32-linux-rescue/gorv32-linux-rescue.bin `
  -DiskNumber <NUMMER> -ExpectedSerial '<SERIENNUMMER>' `
  -ExpectedSize <GROESSE_IN_BYTES>
```

Der Writer schreibt und verifiziert nur die Laenge der Rescue-Datei. Durch das
Flash-fit-Limit endet sie vor LBA 8192. Der Scratch-Sektor LBA 16384 und das
ext2-RootFS ab LBA 32768 werden vom Rescue-Overlay nicht beruehrt; die genaue
letzte belegte Boot-LBA ist buildabhaengig und wird nicht fest angenommen.

Unmittelbar **nach** diesem Overlay den SHA-256 ueber die komplette Karte als
Baseline erfassen. Der Helper liest ausschliesslich, validiert erneut USB,
Seriennummer, Groesse sowie Boot-/System-Flags und benoetigt eine
Administrator-PowerShell:

```powershell
& boards/tang_mega_138k/system16/tools/hash_sd_device.ps1 `
  -DiskNumber <NUMMER> -ExpectedSerial '<SERIENNUMMER>' `
  -ExpectedSize <GROESSE_IN_BYTES> `
  -OutputPath build/gorv32-linux-rescue/sdcard-baseline.txt
```

Dann genau einmal vom Rescue-GRV1 booten, UART vollstaendig mitschneiden, auf
die PASS-Zeile warten und ausschalten. Nach erneutem Einlegen den gespeicherten
`SHA256`-Wert aus `sdcard-baseline.txt` als `-ExpectedHash` uebergeben. Nur die
Meldung `Full-card hash matches the expected baseline.` ist ein Vollvergleich.

Die Baseline darf nicht vor dem Rescue-Overlay entstehen, da sonst der
beabsichtigte Austausch des Boot-Containers als Abweichung erscheint. Der Hash
umfasst insbesondere die Sentinels LBA 0, 16383, 16385 und 32770 sowie
Scratch-LBA 16384. Bei `failed`, einer Sentinel-Aenderung,
`RESTORE FAILED`, Stromausfall oder fehlender PASS-Zeile sofort ausschalten,
die Karte nicht mounten und zuerst das Raw-Abbild und das UART-Log sichern.

## 5. SD-RootFS einmalig schreiben

Nur bei der ersten Bereitstellung oder nach einer RootFS-Aenderung:

```powershell
make -C boards/tang_mega_138k/system16 rootfs-sd-wsl
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-image
```

`build/gorv32-linux-sd/gorv32-linux-sd.img` mit einem Raw-Writer auf das
**gesamte SD-Geraet** schreiben. Es gibt absichtlich keine MBR-/GPT-Tabelle.
`tools/write_sd_image.ps1` kann dafuer in einer Administrator-PowerShell
verwendet werden; der Writer prueft Nummer, USB-Seriennummer und Groesse des
Ziels und verifiziert den geschriebenen Bereich danach per SHA-256.
Spaetere Kernel-/Treiber-Aenderungen brauchen kein neues Kartenabbild:

```powershell
make -C boards/tang_mega_138k/system16 kernel-sd-wsl
make -C boards/tang_mega_138k/system16 gorv32-sd-boot-image
```

Dann nur `gorv32-linux-sd-boot.bin` raw ab SD-LBA 0 aktualisieren. Der
ext2-Bereich ab LBA 32768 bleibt dabei unveraendert.

## Erwartete UART-Ausgabe

Terminal: **115200 8N1**.

```text
FPGA BOOT OK
System16 GoRV32 ZSBL v12 SD-first
boot from SD
copy $00000000 len $...
copy $003F0000 len $...
copy $00400000 len $...
checksum ok, jump to OpenSBI
OpenSBI v1.8
Linux version 6.12.95 ...
Machine model: System16 GoRV32 Plus Linux FPGA (rescue)
gorv32-sd f0600000.sdhost: auto calibration: testing ...
gorv32-sd f0600000.sdhost: auto calibration selected ...
gorv32-sd f0600000.sdhost: CMD24 scratch self-test at physical LBA 16384; root window stays read-only
gorv32-sd f0600000.sdhost: CMD24 scratch self-test PASS at physical LBA 16384; original restored
gorv32-sd f0600000.sdhost: read benchmark: ... 0 retries, 0 FIFO-full events
```

Hardwaremessung vom 2026-07-12: 1 Bit, Divider 9 (`2.5 MHz`), 16 Sektoren
in 42 ms (`190 KiB/s`), keine Retries und kein FIFO-full. Der Wert wird bei
jedem Boot neu bestimmt und kann mit einer anderen Karte abweichen.

Nach dem Login muss zusaetzlich gelten:

```sh
cat /sys/block/gorv32sd/ro
# Ausgabe: 1
```

Der Rescue-Test liest das Original und Sentinel-Sektoren zweimal, schreibt
genau ein Testmuster, liest es zweimal, stellt das Original mit genau einem
CMD24 wieder her, liest es zweimal und prueft danach die Sentinels. Ein CMD24
wird wegen seines mehrdeutigen Fehlerfalls nie automatisch wiederholt.

## Aktuelle Sicherheitsgrenze

Der Linux-Treiber ist im Rescue- und SD-DTB mit `gowin,read-only` gesperrt.
CMD17-Lesen ist bestaetigt. Nur das Rescue-DTB erlaubt den isolierten
Save/Test/Restore-Lauf auf physischem LBA 16384; `/dev/gorv32sd` bleibt auch
nach PASS read-only. Allgemeine CMD24-Schreibzugriffe, beschreibbares ext2 und
Swap auf der echten Hardware sind weiterhin nicht freigegeben.
