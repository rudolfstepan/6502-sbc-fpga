# Native C64 Virtual 1541 UART Technote

This note records the bring-up path for the native C64 virtual-1541 UART loader
and the READY hang that appeared while testing `LOAD "$",8`.

## Current Stable Path

The stable hardware flow is:

1. Build and flash a C64 bitstream whose KERNAL has the guarded `$FFD5` patch.
2. Upload `roms/v1541_hook.prg` through the FPGA UART monitor.
3. Type `RUN` once on the C64 to install the RAM hook at `$C000`.
4. Start the PC virtual drive:

   ```powershell
   python tools/virtual_1541/c64_1541_uart_gui.py --port COM15 --folder E:\Emulatoren\C64\Games
   ```

5. Use normal KERNAL-style C64 commands:

   ```basic
   LOAD"$",8
   LIST
   LOAD"PROGRAM",8,1
   RUN
   ```

This has been verified stable for directory loading and a normal named game PRG
load from a mounted D64.

The current RAM hook talks to the PC virtual drive through the 1541-like UART
channel layer. A KERNAL load on device 8 opens channel 2 with the requested
filename, reads 128-byte blocks until a short block or EOF, and closes the
channel again. The older offset-based `LOAD_CHUNK` shortcut remains available in
the PC server for tests, but is no longer the production hook path.

## UART/Monitor Split

The Tang C64 top shares the CH340 UART between two roles:

- normal C64 mode: host-disk UART at `$DE00/$DE01`
- monitor mode: FPGA RAM/ROM upload/debug monitor

The monitor is entered with the four-byte wake sequence:

```text
A5 5A C3 3C
```

A single wake byte was unsafe once the same UART started carrying arbitrary
binary D64/PRG traffic. The sequence prevents random game or disk bytes from
accidentally entering the monitor.

The C64-side host-disk registers are:

| Address | Direction | Meaning |
| --- | --- | --- |
| `$DE00` | read/write | UART data byte; reading consumes one received byte |
| `$DE01` | read | bit 0 RX byte available, bit 1 TX busy, bit 2 RX overflow |

The C64 core has a 256-byte RX FIFO behind `$DE00`; the PC server still paces
large responses in small chunks.

## READY Hang Root Cause

The first KERNAL patch changed `$FFD5` to:

```asm
JMP ($0330)
```

The RAM hook then installed itself by writing `$0330/$0331`. This worked until
KERNAL/BASIC vector initialization restored `$0330/$0331` to the default
`$F4A5`. After `LOAD "$",8` and READY, the cursor blinked a few times and then
the system appeared frozen.

The UART monitor probe confirmed the problem:

```text
$0330: A5 F4 ...
```

That meant the hook vector had been reset even though the hook code at `$C000`
was still intact.

## Stable KERNAL Patch

The current KERNAL patch avoids relying on `$0330` as the primary dispatch
point. `$FFD5` now jumps to a small guard stub in unused KERNAL space:

```asm
$FFD5: JMP $ECB9

$ECB9: LDA $C000
       CMP #$78       ; SEI, first byte of the RAM hook
       BNE stock
       JMP $C02C      ; hook LOAD entry
stock: JMP $F49E      ; original KERNAL LOAD routine
```

This keeps cold boot and uninstalled-hook behavior safe, while making the
installed hook independent from later `$0330/$0331` resets.

The patch tool is:

```powershell
python tools/patch_c64_kernal_load_vector.py
```

The Make targets are:

```powershell
make c64-kernal-load-vector-patch
make c64-roms
```

## Diagnostics

`tools/c64_uart_monitor_probe.py` can enter the monitor after a hang and dump
CPU/RAM state without cooperation from the C64 program:

```powershell
python tools/c64_uart_monitor_probe.py --port COM15 --verbose
```

The probe records:

- monitor register snapshot (`R` command)
- zero page `$0000-$00FF`
- stack `$0100-$01FF`
- BASIC input/editor area `$0200-$02FF`
- vectors `$0300-$033F`
- screen RAM `$0400-$07FF`
- BASIC program area `$0800-$08FF`
- hook RAM `$C000-$C4FF`

The monitor `R` command snapshots the CPU debug taps at monitor entry, before
the monitor hold state can distort RDY/status.

## Limits

The virtual 1541 is not a cycle-accurate IEC/1541 implementation. It supports
host-side D64 directory and PRG chain handling over a simple UART protocol. It is
good enough for KERNAL `LOAD` users and some part-loader cases. Custom
fastloaders, copy protection, and software that overwrites `$C000` still need
deeper support.
