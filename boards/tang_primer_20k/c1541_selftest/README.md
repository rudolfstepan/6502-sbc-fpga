# Tang Primer 20K 1541 Selftest

Standalone hardware test for the virtual 1541 D64 write path.  This project
does not instantiate the C64 core or IEC bus.  The top-level generates a known
GCR data block, feeds it through `c1541_static_dir_gcr`, lets
`c1541_sd_d64_sector_source` flush it to the SD card, then reads the same D64
sector back and verifies all 256 bytes.

Important: use a disposable SD image.  The test assumes a packed `.d64` file at
SD LBA 0 and overwrites track 35, sector 0.

## Build

From `boards/tang_primer_20k/c1541_selftest/project`:

```powershell
& 'C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe' build.tcl
```

The bitstream is generated as:

```text
impl/pnr/tang_c1541_selftest.fs
```

## Status

UART is 115200 8N1 on the CH340 link.

Expected UART sequence:

```text
C1541 SELFTEST
SD OK
WRITE COMMIT
PASS
```

LEDs are active-low:

- LED0 on: waiting for SD init
- LED1 on: GCR write or SD flush active
- LED2 on: readback/verify active
- LED3 on: pass
- all LEDs blinking: fail

Failure messages are `FAIL $xx`; `$80-$ff` means readback mismatch at
offset `xx & $7f`.
