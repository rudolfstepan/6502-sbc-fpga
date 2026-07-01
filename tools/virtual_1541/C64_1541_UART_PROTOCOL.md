# C64 Virtual 1541 UART Protocol

The PC GUI `tools/virtual_1541/c64_1541_uart_gui.py` accepts binary frames and
newline ASCII commands.

## Existing Shortcuts

These commands are host-side helpers and do not model the 1541 channel API:

```text
PING
IMAGES
MOUNT <d64>
DIR
LOAD <name>
LOADFIRST
LOADCHUNK <offset> <length> <name>
LOADFIRSTCHUNK <offset> <length>
SECTOR <track> <sector>
STATUS
```

## 1541-Like Channel Layer

The native C64 KERNAL hook `sw/c64_v1541_kernal_hook.s` uses this layer for
device 8 loads:

1. `OPEN 2,<kernal filename>`
2. repeated `READ 2,128`
3. `CLOSE 2`

The first bytes read from a PRG are still the normal C64 load address. The hook
uses that address for `LOAD"name",8,1` and keeps the caller's requested address
for `LOAD"name",8`.

Binary command IDs:

```text
$30 SECTOR  payload: track byte, sector byte
$40 DOS     payload: command bytes
$41 OPEN    payload: channel byte, file/command name bytes
$42 CLOSE   payload: channel byte
$43 READ    payload: channel byte, length lo, length hi
$44 WRITE   payload: channel byte, bytes to write
```

The Tang MiSTer C64 probe 1541 backend uses `$30 SECTOR` directly from FPGA
logic. A request frame for track/sector data is:

```text
C6 30 02 00 <track> <sector> <checksum>
checksum = (30 + 02 + 00 + track + sector) & FF
```

The response is the normal binary response frame:

```text
64 30 <status> <len_lo> <len_hi> <payload...> <checksum>
checksum = (30 + status + len_lo + len_hi + sum(payload)) & FF
```

For a successful sector read, `status` is `$00`, length is `256`, and the
payload is exactly one D64 sector.

ASCII test commands:

```text
DOS I
DOS UJ
DOS B-R: 2 0 18 0
DOS B-P: 2 2
OPEN 2 $
READ 2 256
CLOSE 2
OPEN 15
READ 15 80
WRITE 15 I
```

Implemented read-only behaviour:

- `OPEN <channel> "$"` opens the directory as a BASIC PRG.
- `OPEN <channel> "<name>,P,R"` opens a file from the mounted D64. KERNAL-load
  matching accepts `PRG`, `SEQ`, and `USR`, including `0:`/`:` drive prefixes,
  `,P`/`,S`/`,U` type suffixes, and `*`/`?` wildcards.
- `OPEN <channel> "#"` opens a direct-access buffer channel.
- `READ` advances the current channel position.
- Channel 15 returns the current DOS status string.
- DOS commands `I`, `UJ`, `UI`, `V`, `B-R`, and `B-P` are supported.
- Mutating commands (`N:`, `S:`, `R:`, `C:`, `B-W`, `B-A`, `B-F`, `M-W`,
  `M-E`) return `26,WRITE PROTECT ON,00,00`.

This is not yet a cycle-accurate IEC implementation. It is a 1541-compatible
command/file abstraction for the C64-side UART client.
