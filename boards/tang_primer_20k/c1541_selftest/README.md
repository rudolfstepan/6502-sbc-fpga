# Tang Primer 20K 1541 Selftest

Standalone hardware test for the virtual 1541 D64 write path.  This project
does not instantiate the C64 core or IEC bus.  The top-level generates a known
GCR data block, feeds it through `c1541_static_dir_gcr`, lets
`c1541_sd_d64_sector_source` flush it to the SD card, then reads the same D64
sector back and verifies all 256 bytes.

Important: use a disposable SD image.  The test assumes a packed `.d64` file at
SD LBA 0 and overwrites track 35, sector 0.

This is the hardware-only companion to the normal native C64 path documented in
`boards/tang_primer_20k/c64/README.md`: the C64 build verifies real `SAVE`,
while this project verifies the floppy writeback chain without C64, IEC timing,
BASIC or KERNAL in the loop.

## Simulation

Run the focused GHDL writeback checks from the repository root:

```powershell
make test-c1541-sd-write
```

The simulations exercise the GCR write capture and the SD D64
read-modify-write path before a Gowin bitstream is needed.

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
