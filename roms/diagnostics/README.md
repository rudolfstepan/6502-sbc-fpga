# C64 Diagnostic PRGs

This folder contains generated C64 PRGs used for hardware bring-up and virtual
1541 debugging. They are intentionally separated from normal demo/game PRGs so
the root `roms/` folder stays readable.

## CPU/IRQ Hang Diagnostics

These PRGs isolate READY/IRQ/stack hangs without using the virtual drive:

| PRG | Purpose |
| --- | --- |
| `spin_diag.prg` | Absolute no-stack spin loop. Proves the CPU can keep running after `RUN`. |
| `hang_loop_diag.prg` | No-drive/no-IRQ CPU loop using normal subroutines and stack. |
| `cli_noirq_diag.prg` | Runs with CIA/VIC IRQs masked, then enables CPU IRQ handling. |
| `rti_diag.prg` | Manual RTI stack-frame diagnostic. |
| `hang_raw_irq_diag.prg` | KERNAL CINV heartbeat; validates the ROM IRQ entry calling convention. |
| `hang_diag.prg` | READY/IRQ hang diagnostic with on-screen state. |

Build them with:

```powershell
make c64-spin-diag-prg c64-hang-loop-diag-prg c64-cli-noirq-diag-prg
make c64-rti-diag-prg c64-hang-raw-irq-diag-prg c64-hang-diag-prg
```

Upload scripts live in `roms/upload/` and point back to this folder.

## Virtual 1541 Smoke Tests

These PRGs exercise the `$DE00/$DE01` host-disk UART and the KERNAL `LOAD` hook:

| PRG | Purpose |
| --- | --- |
| `v1541_ping.prg` | Sends a binary `PING` request to `tools/virtual_1541/c64_1541_uart_gui.py`. |
| `v1541_loadfirst.prg` | Loads the first PRG from the mounted D64 without patching KERNAL `LOAD`. |
| `v1541_hook_diag.prg` | Installs the RAM hook and prints KERNAL `LOAD` return diagnostics. |
| `v1541_hook_dummy_diag.prg` | Uses an embedded dummy drive; no PC server required after upload. |

Build them with:

```powershell
make c64-v1541-ping-prg c64-v1541-loadfirst-prg
make c64-v1541-hook-diag-prg c64-v1541-hook-dummy-diag-prg
```

The production hook remains at `roms/v1541_hook.prg` because it is part of the
normal virtual-1541 workflow:

```powershell
python tools/c64_uart_prg_loader.py roms/v1541_hook.prg --port COM15
```

After `RUN`, start the virtual drive server and use normal C64 commands such as
`LOAD "$",8`, `LIST`, and `LOAD "PROGRAM",8,1`.

## Monitor Probe

If the machine hangs, do not reset immediately. Enter the FPGA monitor and dump
state with:

```powershell
python tools/c64_uart_monitor_probe.py --port COM15 --verbose
```

The probe logs CPU/debug state, zero page, stack, BASIC input buffer, screen RAM,
vectors, and the hook area at `$C000`. See `docs/C64_V1541_UART_TECHNOTE.md` for
the root-cause notes behind the guarded KERNAL `LOAD` patch.
