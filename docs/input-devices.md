# Input Devices

This page documents the current input path for the FPGA C64 core: PS/2 keyboard
matrix input, RESTORE/NMI, and numeric-keypad joystick emulation.

## Native C64 Input Path

The native C64 core uses [`rtl/c64/c64_keyboard_matrix.vhd`](../rtl/c64/c64_keyboard_matrix.vhd)
as its PS/2 front end. Unlike the SBC text console keyboard path, this module
tracks current key-down state and presents a passive 8x8 C64 keyboard matrix to
CIA1.

CIA1 scans the keyboard exactly like a C64:

| CIA1 port | Address | Role |
| --- | --- | --- |
| Port A | `$DC00` | Keyboard matrix columns, joystick port 2 |
| Port B | `$DC01` | Keyboard matrix rows, joystick port 1 |

The matrix is active-low. A pressed key connects one column to one row; if the
CIA drives a column low, the matching row reads low.

## PS/2 Keyboard Matrix

The keyboard receiver handles PS/2 Set-2 make/break frames directly:

- `F0` marks the next key code as a release.
- `E0` marks extended keys.
- Normal letter, digit, punctuation, shift, control, and function-key codes map
  to the C64 keyboard matrix.
- The separate PC cursor-key cluster remains mapped to C64 cursor keys where
  implemented.

RESTORE is mapped separately from the matrix. `E0 7D` (Page Up on a PC keyboard)
drives the C64 RESTORE/NMI line while held.

## Joystick Emulation

Many C64 games use joystick port 2, which is read through CIA1 port A at `$DC00`.
The numeric keypad cursor legends now emulate that port directly. These keys do
not interfere with the normal PC cursor-key cluster.

Joystick port 2 is active-low:

| `$DC00` bit | C64 joystick signal | PS/2 keypad key |
| --- | --- | --- |
| bit 0 | Up | KP8 |
| bit 1 | Down | KP2 |
| bit 2 | Left | KP4 |
| bit 3 | Right | KP6 |
| bit 4 | Fire | KP0 or KP5 |

The fire buttons are OR-style in user terms and active-low electrically: holding
either KP0 or KP5 pulls bit 4 low, and bit 4 returns high only after both are
released.

The implementation is intentionally kept inside the keyboard-matrix module. It
ANDs the active-low joystick bits onto the CIA1 Port-A readback path, matching
how real external joystick lines pull CIA pins low.

## Practical Use

For games loaded through the C64 UART PRG/D64 path, use the numeric keypad:

```text
KP8     up
KP4     left
KP6     right
KP2     down
KP0/5   fire
```

If a game asks for port 1 instead of port 2, it may not respond yet. The current
emulation targets port 2 because that is the default for many C64 games.

## Verification

Run the focused input test:

```bash
make test-c64-input
```

This builds and runs [`sim/tb/tb_c64_keyboard_matrix_joystick.vhd`](../sim/tb/tb_c64_keyboard_matrix_joystick.vhd).
The test sends PS/2 Set-2 make/break frames for KP8, KP6, KP0, and KP5, then
checks that the corresponding `$DC00` bits go low while pressed and return high
after release.

The native C64 core analysis should also include the updated keyboard matrix:

```bash
ghdl -a --std=08 --ieee=synopsys rtl/c64/c64_keyboard_matrix.vhd rtl/c64/c64_core.vhd
```

In practice, use the existing project-level C64 analysis command or hardware
build flow so all dependencies are analyzed in order.

## Known Limitations

- Only joystick port 2 is emulated.
- There is no runtime switch between joystick port 1 and port 2 yet.
- Diagonal movement is represented by multiple held direction bits, as on a real
  joystick.
- Num Lock behavior depends on the PS/2 keyboard. The implemented codes are the
  non-extended keypad Set-2 codes normally sent by the numeric keypad cursor
  legends; the separate cursor-key cluster uses `E0` codes and remains keyboard
  input.
- The keyboard layout remains a first-pass positional C64 mapping.
