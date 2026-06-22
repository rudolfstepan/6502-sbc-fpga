# TODO: D64-Compatible Hybrid Disk Drive for the FPGA 6502 Computer

## 1. Project Goal

Implement a D64-compatible hybrid disk drive for the custom FPGA-based 6502 computer.

The SD card shall contain `.d64` disk image files. During the FPGA boot process, the user shall be able to select and mount one of these images from a boot menu, similar to a GoDrive-style workflow.

After mounting, the 6502 system shall access the mounted disk image through a memory-mapped disk controller. The first implementation shall be read-only and shall support directory listing and PRG loading.

This is not a cycle-accurate Commodore 1541 implementation. The goal is a practical D64 block device for this custom 6502 computer.

---

## 2. Important Architectural Principle

Do not make the 6502 directly access FAT32 or raw SD-card sectors.

The 6502 shall see a simple block-oriented drive. SD-card handling, FAT32 handling and D64 mounting shall be handled outside the 6502-visible software layer.

Target architecture:

```text
SD card with FAT32
    |
    v
FPGA boot menu / SD-card service / D64 image selector
    |
    v
Mounted D64 image
    |
    v
D64 sector mapper
    |
    v
Memory-mapped disk controller
    |
    v
6502 kernel disk routines
    |
    v
BASIC / monitor / application programs
```

Responsibilities:

```text
FPGA / host side:
  - initialize SD card
  - read FAT32 directory
  - list .d64 files
  - select and mount one image
  - map D64 track/sector to file byte offset
  - read 512-byte SD sectors
  - expose 256-byte D64 sectors through MMIO
  - later: write sectors and flush changes

6502 side:
  - issue disk commands
  - read disk status
  - parse directory sectors
  - find PRG files
  - follow file block chains
  - load PRG payload into RAM
  - expose LOAD/DIR routines to BASIC or monitor
```

---

## 3. Scope for Version 1

Version 1 shall implement:

```text
read-only D64 mounting
standard 35-track D64 support
memory-mapped sector read
directory listing
PRG loading
same register contract in emulator and FPGA
test image generation
basic documentation
```

Version 1 shall not implement:

```text
D64 write support
SAVE
file deletion
file rename
BAM allocation updates
cycle-accurate 1541 emulation
IEC bus timing
Fastloader compatibility
copy-protection support
G64 support
full C64 compatibility
```

Reason:

The system is a custom homecomputer-like 6502 machine. D64 is used as a convenient, well-known disk-container format. It does not imply full C64 or 1541 compatibility.

---

## 4. D64 Format Support

### 4.1 Required D64 Variant for Version 1

Support this image size first:

```text
35 tracks
683 sectors
256 bytes per sector
174848 bytes total
no error-info bytes
```

Formula:

```text
683 * 256 = 174848
```

### 4.2 Optional Later D64 Variants

Add support later only after Version 1 is stable:

```text
35 tracks with error bytes: 175531 bytes
40 tracks:                  196608 bytes
40 tracks with error bytes: 197376 bytes
42 tracks:                  205312 bytes
42 tracks with error bytes: 206114 bytes
```

### 4.3 Track and Sector Layout

D64 uses 1-based track numbers and 0-based sector numbers.

Required sector counts:

```text
Tracks  1..17: 21 sectors each
Tracks 18..24: 19 sectors each
Tracks 25..30: 18 sectors each
Tracks 31..35: 17 sectors each
```

Optional extended tracks later:

```text
Tracks 36..42: 17 sectors each
```

### 4.4 Important D64 Sectors

```text
Track 18, Sector 0:
  BAM and disk name

Track 18, Sector 1:
  first directory sector
```

Directory sectors are linked. Each directory sector contains a next-track/next-sector pointer followed by eight 32-byte directory entries.

---

## 5. D64 Track/Sector Mapping

### 5.1 Required Sector Index Function

Implement this function in a shared form if possible. The same logic must exist in the emulator and FPGA implementation.

```c
uint32_t d64_sector_index(uint8_t track, uint8_t sector)
{
    if (track >= 1 && track <= 17)
    {
        if (sector >= 21) return 0xFFFFFFFF;
        return (uint32_t)(track - 1) * 21u + sector;
    }

    if (track >= 18 && track <= 24)
    {
        if (sector >= 19) return 0xFFFFFFFF;
        return 357u + (uint32_t)(track - 18) * 19u + sector;
    }

    if (track >= 25 && track <= 30)
    {
        if (sector >= 18) return 0xFFFFFFFF;
        return 490u + (uint32_t)(track - 25) * 18u + sector;
    }

    if (track >= 31 && track <= 35)
    {
        if (sector >= 17) return 0xFFFFFFFF;
        return 598u + (uint32_t)(track - 31) * 17u + sector;
    }

    return 0xFFFFFFFF;
}
```

### 5.2 Offset Calculation

```text
sector_index = d64_sector_index(track, sector)
byte_offset  = sector_index * 256
```

Because SD cards use 512-byte blocks:

```text
sd_file_byte_offset = d64_file_start_byte + byte_offset
sd_block_offset     = sd_file_byte_offset / 512
sector_half         = sd_file_byte_offset & 0x100
```

Interpretation:

```text
sector_half = 0x000:
  D64 sector is in bytes 0..255 of the 512-byte SD block

sector_half = 0x100:
  D64 sector is in bytes 256..511 of the 512-byte SD block
```

### 5.3 Required Mapping Test Cases

Add unit tests for these cases:

```text
Track 1, Sector 0:
  index = 0
  byte offset = 0

Track 1, Sector 20:
  index = 20
  byte offset = 5120

Track 2, Sector 0:
  index = 21
  byte offset = 5376

Track 17, Sector 20:
  index = 356
  byte offset = 91136

Track 18, Sector 0:
  index = 357
  byte offset = 91392

Track 18, Sector 1:
  index = 358
  byte offset = 91648

Track 24, Sector 18:
  index = 489
  byte offset = 125184

Track 25, Sector 0:
  index = 490
  byte offset = 125440

Track 30, Sector 17:
  index = 597
  byte offset = 152832

Track 31, Sector 0:
  index = 598
  byte offset = 153088

Track 35, Sector 16:
  index = 682
  byte offset = 174592
```

Invalid cases:

```text
Track 0, Sector 0:
  invalid

Track 1, Sector 21:
  invalid

Track 18, Sector 19:
  invalid

Track 25, Sector 18:
  invalid

Track 35, Sector 17:
  invalid

Track 36, Sector 0:
  invalid for Version 1
```

---

## 6. Memory-Mapped Disk Controller

### 6.1 Proposed Base Address

Use a dedicated I/O region that does not conflict with existing devices.

Proposed default:

```asm
DISK_BASE = $8A00
```

Sector buffer:

```asm
DISK_BUFFER = $8B00
```

The buffer consumes one full 256-byte page.

If `$8A00/$8B00` conflicts with existing hardware, choose another page and update all emulator, FPGA and 6502 constants together.

### 6.2 Register Map

```text
$8A00 DISK_STATUS
$8A01 DISK_COMMAND
$8A02 DISK_TRACK
$8A03 DISK_SECTOR
$8A04 DISK_ADDR_LO
$8A05 DISK_ADDR_HI
$8A06 DISK_RESULT
$8A07 DISK_IMAGE_INDEX_LO
$8A08 DISK_IMAGE_INDEX_HI
$8A09 DISK_FLAGS

$8A0A DISK_DEBUG_INDEX_LO
$8A0B DISK_DEBUG_INDEX_HI
$8A0C DISK_DEBUG_SD_BLOCK_0
$8A0D DISK_DEBUG_SD_BLOCK_1
$8A0E DISK_DEBUG_SD_BLOCK_2
$8A0F DISK_DEBUG_SD_BLOCK_3

$8B00-$8BFF DISK_BUFFER
```

### 6.3 Register Semantics

#### DISK_STATUS, read-only from 6502 perspective

```text
bit 0 BUSY
bit 1 DONE
bit 2 ERROR
bit 3 MOUNTED
bit 4 WRITE_PROTECT
bit 5 DIRTY
bit 6 IMAGE_LIST_READY
bit 7 reserved
```

Rules:

```text
BUSY:
  set while the controller is executing a command

DONE:
  set after a command completed successfully
  cleared when a new command starts

ERROR:
  set after a command failed
  cleared when a new command starts

MOUNTED:
  set when a valid D64 image is mounted

WRITE_PROTECT:
  set for read-only images or read-only mode

DIRTY:
  later used for write support

IMAGE_LIST_READY:
  optional for boot-menu or runtime image selection
```

#### DISK_COMMAND, write-only command register

```text
$00 NOP
$01 READ_SECTOR
$02 WRITE_SECTOR
$03 MOUNT_IMAGE
$04 UNMOUNT
$05 FLUSH
$06 GET_IMAGE_COUNT
$07 GET_IMAGE_NAME
$08 READ_SECTOR_DMA
$09 WRITE_SECTOR_DMA
$0A RESET_CONTROLLER
```

Version 1 required commands:

```text
$00 NOP
$01 READ_SECTOR
$04 UNMOUNT
$0A RESET_CONTROLLER
```

Optional later:

```text
$02 WRITE_SECTOR
$03 MOUNT_IMAGE
$05 FLUSH
$06 GET_IMAGE_COUNT
$07 GET_IMAGE_NAME
$08 READ_SECTOR_DMA
$09 WRITE_SECTOR_DMA
```

#### DISK_TRACK

```text
Input track number for sector commands.
D64 tracks are 1-based.
Valid Version 1 range: 1..35
```

#### DISK_SECTOR

```text
Input sector number for sector commands.
D64 sectors are 0-based.
Valid range depends on track.
```

#### DISK_ADDR_LO / DISK_ADDR_HI

Version 1 may leave these unused.

Later use:

```text
DMA source/destination address for READ_SECTOR_DMA or WRITE_SECTOR_DMA.
```

#### DISK_RESULT

Result code of the last command.

```text
$00 OK
$01 NO_IMAGE_MOUNTED
$02 INVALID_TRACK
$03 INVALID_SECTOR
$04 SD_READ_ERROR
$05 SD_WRITE_ERROR
$06 UNSUPPORTED_IMAGE
$07 WRITE_PROTECTED
$08 BUSY
$09 INTERNAL_ERROR
$0A INVALID_COMMAND
$0B DIRECTORY_ERROR
$0C FILE_CHAIN_ERROR
$0D LOAD_ADDRESS_INVALID
$0E MEMORY_RANGE_INVALID
```

#### DISK_IMAGE_INDEX_LO / DISK_IMAGE_INDEX_HI

Optional runtime image index selection.

For Version 1, image mounting can happen entirely in the FPGA boot menu. The 6502 does not need to select the image.

#### DISK_FLAGS

Suggested flags:

```text
bit 0 allow writes
bit 1 use embedded PRG load address
bit 2 force load to caller address
bit 3 verbose/debug mode
bit 4 allow overwrite RAM
bit 5 allow overwrite I/O
bit 6 allow overwrite ROM
bit 7 reserved
```

Only use these once the 6502 loader needs them. Keep default safe.

### 6.4 Disk Buffer

```text
$8B00-$8BFF
```

This buffer contains the last sector read by READ_SECTOR.

Rules:

```text
READ_SECTOR success:
  buffer contains exactly 256 bytes from the requested D64 sector

READ_SECTOR error:
  buffer content is unspecified
  safer implementation: leave old buffer unchanged
```

Version 1 recommendation:

```text
Do not modify DISK_BUFFER when READ_SECTOR fails.
```

---

## 7. Disk Controller Command Behavior

### 7.1 General Command State Machine

For each command write:

```text
1. If BUSY is already set:
     ignore command or set RESULT = BUSY
     keep current command running

2. Clear DONE and ERROR.

3. Set BUSY.

4. Execute command.

5. On success:
     RESULT = OK
     DONE = 1
     ERROR = 0

6. On failure:
     RESULT = error code
     DONE = 0
     ERROR = 1

7. Clear BUSY.
```

Important:

```text
The 6502 must never observe BUSY=0 while a command is still modifying DISK_BUFFER.
```

### 7.2 READ_SECTOR

Inputs:

```text
DISK_TRACK
DISK_SECTOR
```

Algorithm:

```text
1. Check MOUNTED.
2. Validate track.
3. Validate sector range for track.
4. Calculate D64 sector index.
5. Calculate byte offset.
6. Calculate SD block and half-sector.
7. Read the 512-byte SD block that contains the requested D64 sector.
8. Copy selected 256 bytes into DISK_BUFFER.
9. Update debug registers.
10. Return OK.
```

Failure cases:

```text
No image mounted:
  RESULT = NO_IMAGE_MOUNTED

Invalid track:
  RESULT = INVALID_TRACK

Invalid sector:
  RESULT = INVALID_SECTOR

SD read error:
  RESULT = SD_READ_ERROR

Internal mapping error:
  RESULT = INTERNAL_ERROR
```

### 7.3 RESET_CONTROLLER

Algorithm:

```text
1. Clear BUSY.
2. Clear DONE.
3. Clear ERROR.
4. Clear RESULT.
5. Keep mounted image if already mounted.
6. Do not clear DISK_BUFFER unless explicitly desired.
```

### 7.4 UNMOUNT

Algorithm:

```text
1. If write support exists and DIRTY is set:
     either reject with DIRTY or flush first, depending on policy.
2. Clear mounted image metadata.
3. Clear MOUNTED.
4. Return OK.
```

For Version 1:

```text
UNMOUNT just clears mounted state.
```

---

## 8. FPGA Boot Menu Requirements

### 8.1 SD Card Directory Scanning

At boot:

```text
1. Initialize SD card.
2. Mount FAT32.
3. Open root directory or configured directory.
4. Search for files ending in .D64 or .d64.
5. Store matching files in an image list.
6. Display list to user.
```

Recommended directory:

```text
/d64
```

Fallback:

```text
root directory
```

### 8.2 Image List Metadata

For each image:

```text
filename
file size
start cluster or file handle
detected D64 variant
read-only flag
valid/invalid flag
```

### 8.3 Boot Menu UX

Menu options:

```text
1. Boot default ROM without disk
2. Mount D64 and boot
3. Rescan SD card
4. Show disk info
```

D64 selection screen:

```text
D64 IMAGES

[00] TESTDISK.D64       174848 OK
[01] DEMOS.D64          174848 OK
[02] BADIMAGE.D64       123456 INVALID
```

On selection:

```text
Mounted: TESTDISK.D64
Tracks: 35
Mode: read-only
```

Then continue booting the 6502 system.

### 8.4 Mount Policy

Version 1:

```text
mount one image at boot time
image remains mounted until reset or unmount
read-only
```

Later:

```text
runtime disk swapping
multiple virtual drives
drive numbers 8, 9, 10, 11
```

### 8.5 Acceptance Criteria

```text
- SD card initializes.
- .d64 files are found.
- Invalid image sizes are shown or rejected.
- User can select one valid image.
- DISK_STATUS reports MOUNTED after boot.
- 6502 can read Track 18/Sector 0 and Track 18/Sector 1.
```

---

## 9. FPGA RTL Module Plan

Actual filenames may be adjusted to the repository structure.

### 9.1 Proposed Module Layout

```text
fpga/
  rtl/
    disk/
      d64_sector_map.v
      d64_controller.v
      d64_mmio.v
      sd_d64_bridge.v
      disk_buffer_ram.v
```

### 9.2 d64_sector_map.v

Responsibility:

```text
Convert D64 track/sector to sector index and validate range.
```

Inputs:

```verilog
input  [7:0] track;
input  [7:0] sector;
```

Outputs:

```verilog
output       valid;
output [9:0] sector_index;
output [7:0] error_code;
```

Notes:

```text
683 sectors fit into 10 bits.
Max index is 682.
```

Combinational logic is sufficient.

Acceptance tests:

```text
- Verify all required mapping test cases.
- Verify invalid sector numbers per track.
- Verify invalid track zero.
- Verify invalid track above 35 for Version 1.
```

### 9.3 disk_buffer_ram.v

Responsibility:

```text
Provide 256-byte sector buffer at $8B00-$8BFF.
```

Requirements:

```text
- 6502 can read buffer.
- Disk controller can write buffer.
- Optional: 6502 can write buffer later for WRITE_SECTOR.
```

Version 1:

```text
- 6502 read-only access is enough.
```

Later write support:

```text
- 6502 writes buffer before WRITE_SECTOR.
```

### 9.4 d64_mmio.v

Responsibility:

```text
Expose disk registers and buffer to the 6502 bus.
```

Inputs:

```text
cpu_addr
cpu_data_in
cpu_read
cpu_write
cpu_select
clock
reset
```

Outputs:

```text
cpu_data_out
command_start
command_code
track
sector
flags
```

Rules:

```text
- CPU writes DISK_COMMAND to start a command.
- CPU reads DISK_STATUS and DISK_RESULT.
- CPU reads DISK_BUFFER.
- Register behavior must match emulator.
```

### 9.5 sd_d64_bridge.v

Responsibility:

```text
Read 512-byte SD blocks and extract selected D64 sector half.
```

Inputs:

```text
mounted image metadata
sector index
read request
```

Outputs:

```text
buffer write data
buffer write address
done
error
```

### 9.6 d64_controller.v

Responsibility:

```text
Top-level disk-controller state machine.
```

States:

```text
IDLE
VALIDATE
MAP_SECTOR
REQUEST_SD_READ
WAIT_SD_READ
COPY_LOWER_HALF
COPY_UPPER_HALF
DONE
ERROR
```

For READ_SECTOR:

```text
IDLE
  wait for command

VALIDATE
  check mounted, track, sector

MAP_SECTOR
  compute sector index and byte offset

REQUEST_SD_READ
  request 512-byte block from SD layer

WAIT_SD_READ
  wait for SD response

COPY_LOWER_HALF or COPY_UPPER_HALF
  copy 256 bytes into DISK_BUFFER

DONE
  set status done

ERROR
  set error status
```

### 9.7 FPGA Integration Points

Identify and modify:

```text
- top-level bus decoder
- memory map constants
- boot menu state machine
- SD-card controller integration
- reset handling
- debug UART or video output
```

Acceptance criteria:

```text
- No conflict with existing sound, video, keyboard or ROM mapping.
- Disk registers decode only in selected I/O range.
- Reads from unmapped addresses remain unaffected.
- Disk buffer is stable while CPU reads it.
```

---

## 10. Emulator Implementation Plan

Implement emulator support before FPGA support if possible. It is easier to debug the 6502-side code in the emulator.

### 10.1 Required Emulator Features

```text
- Load a D64 image from host filesystem.
- Expose same MMIO registers as FPGA.
- Implement READ_SECTOR.
- Fill $8B00-$8BFF buffer.
- Log disk commands.
- Return same status and result codes as FPGA.
```

### 10.2 Suggested CLI Options

```text
--mount-d64 path/to/image.d64
--disk-readonly
--disk-debug
```

Example:

```text
6502-sbc-emulator --rom roms/kernel.rom --mount-d64 roms/test_d64/testdisk.d64 --disk-debug
```

### 10.3 Emulator Module Layout

Adjust naming to repository style.

```text
src/
  devices/
    d64_drive.c/.h or .cpp/.h
    disk_controller.c/.h
```

If the emulator is C++:

```text
class D64Image
{
public:
    bool open(const std::string& path);
    bool isMounted() const;
    bool readSector(uint8_t track, uint8_t sector, uint8_t out[256]);
    uint8_t getLastError() const;

private:
    std::vector<uint8_t> data;
    int tracks;
};
```

```text
class DiskController
{
public:
    uint8_t read(uint16_t address);
    void write(uint16_t address, uint8_t value);

private:
    uint8_t status;
    uint8_t command;
    uint8_t track;
    uint8_t sector;
    uint8_t result;
    uint8_t buffer[256];

    void executeCommand(uint8_t command);
    void readSectorCommand();
};
```

### 10.4 Emulator Debug Output

When debug is enabled:

```text
[D64] MOUNT path=roms/test_d64/testdisk.d64 size=174848 tracks=35
[D64] READ track=18 sector=0 index=357 offset=91392 result=OK
[D64] READ track=18 sector=1 index=358 offset=91648 result=OK
[D64] READ track=35 sector=17 result=INVALID_SECTOR
[D64] UNMOUNT result=OK
```

### 10.5 Emulator Acceptance Criteria

```text
- Emulator can mount a standard 35-track D64.
- Emulator rejects unsupported image sizes.
- Disk registers behave like FPGA spec.
- Sector buffer contains expected bytes.
- Directory sector 18/1 can be read.
- Invalid track/sector returns proper error code.
```

---

## 11. 6502 Kernel Disk API

### 11.1 Constants

Create or extend a disk include file.

Suggested file:

```text
tools/kernel/disk.inc
```

Content:

```asm
DISK_STATUS  = $8A00
DISK_COMMAND = $8A01
DISK_TRACK   = $8A02
DISK_SECTOR  = $8A03
DISK_ADDR_LO = $8A04
DISK_ADDR_HI = $8A05
DISK_RESULT  = $8A06
DISK_FLAGS   = $8A09
DISK_BUFFER  = $8B00

CMD_NOP              = $00
CMD_READ_SECTOR      = $01
CMD_WRITE_SECTOR     = $02
CMD_MOUNT_IMAGE      = $03
CMD_UNMOUNT          = $04
CMD_FLUSH            = $05
CMD_RESET_CONTROLLER = $0A

STATUS_BUSY          = %00000001
STATUS_DONE          = %00000010
STATUS_ERROR         = %00000100
STATUS_MOUNTED       = %00001000
STATUS_WRITE_PROTECT = %00010000
STATUS_DIRTY         = %00100000

DISK_OK              = $00
DISK_NO_IMAGE        = $01
DISK_INVALID_TRACK   = $02
DISK_INVALID_SECTOR  = $03
DISK_SD_READ_ERROR   = $04
DISK_SD_WRITE_ERROR  = $05
DISK_UNSUPPORTED     = $06
DISK_WRITE_PROTECTED = $07
DISK_BUSY_ERROR      = $08
DISK_INTERNAL_ERROR  = $09
```

### 11.2 Low-Level Routines

Suggested file:

```text
tools/kernel/disk.s
```

Required routines:

```asm
disk_reset_controller
disk_is_mounted
disk_wait_ready
disk_get_result
disk_read_sector
disk_copy_buffer
```

### 11.3 disk_is_mounted

Behavior:

```text
Input:
  none

Output:
  Carry clear if mounted
  Carry set if not mounted
```

Pseudo assembly:

```asm
disk_is_mounted:
    lda DISK_STATUS
    and #STATUS_MOUNTED
    beq .not_mounted
    clc
    rts

.not_mounted:
    sec
    rts
```

### 11.4 disk_wait_ready

Behavior:

```text
Wait until BUSY clears.
```

Pseudo assembly:

```asm
disk_wait_ready:
.wait:
    lda DISK_STATUS
    and #STATUS_BUSY
    bne .wait
    rts
```

Optional timeout later:

```text
Use a software counter to avoid infinite loops if hardware locks up.
```

### 11.5 disk_read_sector

Behavior:

```text
Input:
  A = track number
  X = sector number

Output:
  Carry clear on success
  Carry set on error
  DISK_RESULT contains result code
  DISK_BUFFER contains sector on success
```

Pseudo assembly:

```asm
disk_read_sector:
    sta DISK_TRACK
    stx DISK_SECTOR

    lda #CMD_READ_SECTOR
    sta DISK_COMMAND

.wait:
    lda DISK_STATUS
    and #STATUS_BUSY
    bne .wait

    lda DISK_STATUS
    and #STATUS_ERROR
    bne .error

    clc
    rts

.error:
    sec
    rts
```

### 11.6 Acceptance Criteria

```text
- disk_is_mounted reports mounted state.
- disk_read_sector reads Track 18/Sector 0.
- disk_read_sector reads Track 18/Sector 1.
- invalid sectors return carry set.
- result code is preserved.
- no routine depends on emulator-only behavior.
```

---

## 12. Directory Reader

### 12.1 Directory Layout

Directory starts at:

```text
Track 18, Sector 1
```

Each directory sector:

```text
Byte 0:
  next directory track

Byte 1:
  next directory sector

Bytes 2..255:
  eight directory entries of 32 bytes each
```

Directory entry offsets:

```text
+00 file type
+01 first file track
+02 first file sector
+03 filename byte 0
...
+18 filename byte 15
+19 REL side-sector fields or unused
...
+1D REL fields or unused
+1E file size low byte, in sectors
+1F file size high byte, in sectors
```

File type:

```text
entry[0] & $07

$00 DEL
$01 SEQ
$02 PRG
$03 USR
$04 REL
```

Closed flag:

```text
entry[0] & $80
```

### 12.2 Required Directory Routines

```asm
disk_dir_open
disk_dir_next_entry
disk_dir_print
disk_find_file
disk_find_prg
```

### 12.3 disk_dir_open

Behavior:

```text
Set current directory track/sector to 18/1.
Read first directory sector.
Set current entry index to 0.
```

### 12.4 disk_dir_next_entry

Behavior:

```text
Return next valid directory entry.
Skip deleted entries.
Follow directory sector chain.
Stop when next track is 0.
```

Output suggestion:

```text
Carry clear:
  valid entry found

Carry set:
  no more entries or error

Zero page or fixed buffer contains:
  file type
  first track
  first sector
  filename
  file size in sectors
```

### 12.5 Filename Handling

D64 filenames are normally stored as PETSCII and padded with `$A0`.

Version 1 may use a simplified filename model:

```text
- uppercase ASCII input
- compare against PETSCII uppercase for common A-Z, 0-9 and symbols
- trim trailing $A0
```

Rules:

```text
- Ignore case for ASCII input if practical.
- Treat trailing spaces as insignificant.
- For Version 1, support simple filenames:
    A-Z
    0-9
    space
    underscore
    dash
    dot
```

### 12.6 Directory Printing

For debugging, print entries as:

```text
BLOCKS  TYPE  NAME
2       PRG   "HELLO"
8       PRG   "SOUNDTEST"
24      PRG   "MANDEL"
```

Later C64-like listing:

```text
0 "TESTDISK" 00 2A
2 "HELLO" PRG
8 "SOUNDTEST" PRG
24 "MANDEL" PRG
664 BLOCKS FREE
```

### 12.7 Acceptance Criteria

```text
- Directory reader starts at 18/1.
- Directory reader follows linked directory sectors.
- Deleted entries are ignored.
- PRG entries are detected.
- Directory output is readable.
- Directory chain corruption is detected.
- Directory listing works in emulator first.
- Same code works on FPGA.
```

---

## 13. PRG Loader

### 13.1 PRG File Chain Structure

Each file block is one D64 sector.

Common block layout:

```text
Byte 0:
  next track

Byte 1:
  next sector

Bytes 2..255:
  payload
```

For the first PRG block:

```text
Byte 2:
  load address low byte

Byte 3:
  load address high byte

Bytes 4..255:
  first program payload bytes
```

For following blocks:

```text
Bytes 2..255:
  program payload bytes
```

Last block:

```text
Byte 0:
  $00

Byte 1:
  last used byte position in this sector
```

For the last block, only bytes up to the final used byte are valid.

### 13.2 Required Loader Routines

```asm
disk_load_prg_by_name
disk_load_prg_from_ts
disk_load_prg_embedded_address
disk_load_prg_to_fixed_address
```

### 13.3 disk_load_prg_by_name

Input:

```text
Pointer to filename
Load mode
Optional forced load address
```

Process:

```text
1. Search directory for matching PRG.
2. Extract first track and first sector.
3. Call disk_load_prg_from_ts.
```

### 13.4 disk_load_prg_from_ts

Input:

```text
Track/Sector of first file block
Load mode
Optional forced load address
```

Process:

```text
1. Read first file sector.
2. Read embedded load address from DISK_BUFFER+2 and DISK_BUFFER+3.
3. Determine target load address:
     embedded mode:
       use embedded address
     forced mode:
       use caller address
4. Copy payload bytes into memory.
5. Follow next track/sector pointer.
6. For each following sector:
     copy payload bytes from offset 2.
7. Stop when next track is zero.
8. Return final end address.
```

### 13.5 Last Sector Handling

Important detail:

When byte 0 is zero, byte 1 contains the final used byte position in the sector.

Example:

```text
Byte 0 = $00
Byte 1 = $2A
```

Valid data bytes end at sector byte `$2A`.

Since payload begins at byte 2, final payload length is:

```text
last_payload_length = last_used_index - 1
```

But handle this carefully:

```text
If last_used_index < 2:
  empty final payload or invalid chain

If first sector is also last sector:
  embedded load address consumes bytes 2 and 3
  program payload starts at byte 4
```

### 13.6 Safety Checks

Implement these before copying data:

```text
- Target address must not be inside I/O area unless explicitly allowed.
- Target address must not be inside ROM area unless explicitly allowed.
- Load must not wrap around from $FFFF to $0000.
- File chain must not exceed maximum plausible sector count.
- Track/sector pointers must be valid.
```

Recommended maximum block counter:

```text
683 blocks for 35-track D64
```

If more than 683 blocks are followed:

```text
abort with FILE_CHAIN_ERROR
```

### 13.7 Return Values

Recommended:

```text
Carry clear:
  load successful

Carry set:
  load failed

On success:
  start address in LOAD_START_LO/HI
  end address in LOAD_END_LO/HI

On failure:
  DISK_RESULT or kernel error code contains reason
```

### 13.8 Acceptance Criteria

```text
- Can load a one-sector PRG.
- Can load a multi-sector PRG.
- Correctly uses embedded load address.
- Supports forced load address.
- Correctly handles final sector byte count.
- Detects invalid chains.
- Detects memory overflow.
- Loaded BASIC program can RUN.
- Loaded machine-code program can be started manually.
```

---

## 14. BASIC and Monitor Integration

### 14.1 Minimal Integration First

Do not start by trying to perfectly clone C64 disk syntax.

First expose simple commands through the existing monitor or kernel command mechanism:

```text
DIR
LOAD "HELLO"
RUN
```

If the current BASIC integration allows custom commands, add:

```text
DIR
DLOAD "NAME"
```

If not, expose kernel calls and add a simple menu/monitor command first.

### 14.2 Later C64-like Syntax

Optional later:

```text
LOAD "$"
LIST

LOAD "PROGRAM"
RUN

LOAD "PROGRAM",8,1
```

Interpretation:

```text
LOAD "NAME":
  load PRG using embedded address or BASIC default depending on system policy

LOAD "NAME",8,1:
  load to embedded address

LOAD "$":
  generate directory listing as BASIC text or print directly
```

### 14.3 Kernel Jump Table

If the kernel has a jump table, add stable entries:

```asm
KERNEL_DISK_STATUS
KERNEL_DISK_DIR
KERNEL_DISK_LOAD
KERNEL_DISK_READ_SECTOR
```

Do not expose low-level MMIO addresses directly to BASIC programs unless desired.

### 14.4 Acceptance Criteria

```text
- User can display disk directory.
- User can load a named PRG.
- User can run a loaded BASIC PRG.
- User can load a machine-code PRG.
- Errors are printed in a readable form.
```

Example error output:

```text
?NO DISK MOUNTED
?FILE NOT FOUND
?DISK READ ERROR
?INVALID DISK IMAGE
?LOAD ADDRESS ERROR
```

---

## 15. Test D64 Tooling

### 15.1 Required Scripts

Create a tooling folder:

```text
tools/d64/
```

Required scripts:

```text
tools/d64/create_test_d64.py
tools/d64/list_d64.py
tools/d64/extract_prg.py
```

Optional later:

```text
tools/d64/inject_prg.py
tools/d64/create_blank_d64.py
tools/d64/validate_d64.py
```

### 15.2 create_test_d64.py

Purpose:

```text
Generate a deterministic test disk image for emulator and FPGA testing.
```

Output:

```text
roms/test_d64/testdisk.d64
```

Contents:

```text
HELLO.PRG
SOUNDTEST.PRG
MANDEL.PRG
DIRTEST1.PRG
DIRTEST2.PRG
```

Implementation options:

```text
Option A:
  Implement simple D64 writer in Python.

Option B:
  Use external tools only for local workflow, but keep generated D64 in repo.

Option C:
  Generate from a simple built-in minimal filesystem writer.
```

Prefer Option A if no external dependencies are wanted.

### 15.3 list_d64.py

Purpose:

```text
Parse and print D64 directory from host PC.
```

Expected output:

```text
Disk name: TESTDISK
Files:
  2  PRG  HELLO
  8  PRG  SOUNDTEST
  24 PRG  MANDEL
```

### 15.4 extract_prg.py

Purpose:

```text
Extract a named PRG from a D64 image and write it as a .prg file.
```

Usage:

```text
python tools/d64/extract_prg.py roms/test_d64/testdisk.d64 HELLO extracted/hello.prg
```

### 15.5 Unit Tests

Add tests for:

```text
- D64 image size
- sector mapping
- BAM sector location
- directory sector location
- directory entry parsing
- PRG extraction
- invalid track/sector rejection
- invalid image size rejection
```

### 15.6 Acceptance Criteria

```text
- Test D64 can be generated reproducibly.
- Test D64 can be listed by project tooling.
- Test PRGs can be extracted and match source binaries.
- Emulator can mount generated test D64.
- FPGA can mount the same image.
```

---

## 16. Suggested Repository Changes

Adjust paths to the actual repository layout.

### 16.1 FPGA Repository

```text
fpga/
  docs/
    D64_DRIVE.md

  rtl/
    disk/
      d64_sector_map.v
      d64_controller.v
      d64_mmio.v
      sd_d64_bridge.v
      disk_buffer_ram.v

  sim/
    disk/
      tb_d64_sector_map.v
      tb_d64_controller.v
```

### 16.2 Emulator Repository

```text
src/
  devices/
    d64_drive.*
    disk_controller.*

docs/
  D64_DRIVE.md
```

### 16.3 Shared Tools

```text
tools/
  d64/
    create_test_d64.py
    list_d64.py
    extract_prg.py

  kernel/
    disk.inc
    disk.s
```

### 16.4 ROM/Test Assets

```text
roms/
  test_d64/
    testdisk.d64
    hello.prg
    soundtest.prg
    mandel.prg
```

---

## 17. Implementation Order

Use this exact order unless there is a strong reason to change it.

### Step 1: D64 Sector Mapping

```text
- Implement mapping helper.
- Add mapping tests.
- Verify all known track/sector offsets.
```

Done when:

```text
All mapping tests pass.
```

### Step 2: Host-side D64 Parser Tool

```text
- Implement list_d64.py.
- Read BAM and directory sectors.
- Print directory.
```

Done when:

```text
A known D64 image can be listed.
```

### Step 3: Emulator D64 Image Loader

```text
- Add command-line mount option.
- Load D64 file into memory.
- Reject unsupported size.
```

Done when:

```text
Emulator logs mounted D64 metadata.
```

### Step 4: Emulator MMIO Disk Controller

```text
- Add disk registers.
- Add READ_SECTOR.
- Expose DISK_BUFFER.
```

Done when:

```text
6502 can read Track 18/Sector 1 in emulator.
```

### Step 5: 6502 Low-Level Disk Routines

```text
- Add disk.inc.
- Add disk.s.
- Implement disk_read_sector.
```

Done when:

```text
A 6502 test ROM reads a sector and prints a few bytes.
```

### Step 6: Directory Reader

```text
- Implement directory iteration.
- Print directory.
```

Done when:

```text
A mounted D64 directory is visible from the 6502 system.
```

### Step 7: PRG Loader

```text
- Implement file search.
- Implement file chain loading.
- Support embedded load address.
```

Done when:

```text
HELLO.PRG loads and runs in emulator.
```

### Step 8: FPGA MMIO Shell

```text
- Add disk register decode.
- Add status/result registers.
- Add disk buffer page.
```

Done when:

```text
6502 can see disk registers on FPGA.
```

### Step 9: FPGA SD-backed READ_SECTOR

```text
- Connect mounted image metadata to disk controller.
- Implement SD block read.
- Fill DISK_BUFFER.
```

Done when:

```text
6502 reads Track 18/Sector 1 from real SD card on FPGA.
```

### Step 10: FPGA Boot Menu Mounting

```text
- List .d64 files.
- Select image.
- Mount image before 6502 boot.
```

Done when:

```text
User can select D64 image and boot with it mounted.
```

### Step 11: BASIC or Monitor Integration

```text
- Add DIR command.
- Add LOAD command.
```

Done when:

```text
User can mount disk, type DIR, type LOAD "HELLO", and RUN.
```

### Step 12: Documentation

```text
- Document register map.
- Document D64 limitations.
- Document usage.
- Document test workflow.
```

Done when:

```text
docs/D64_DRIVE.md explains how to use and debug the drive.
```

---

## 18. Test ROMs

### 18.1 Sector Read Test ROM

Purpose:

```text
Verify low-level disk access.
```

Behavior:

```text
1. Check DISK_STATUS.
2. Print mounted/not mounted.
3. Read Track 18/Sector 0.
4. Print first 16 bytes.
5. Read Track 18/Sector 1.
6. Print first 16 bytes.
7. Print result codes.
```

Expected:

```text
- Track 18/Sector 0 contains BAM information.
- Track 18/Sector 1 contains directory chain pointer and entries.
```

### 18.2 Directory Test ROM

Purpose:

```text
Verify directory parsing.
```

Behavior:

```text
1. Open directory.
2. Print all PRG entries.
3. Print file sizes.
```

### 18.3 PRG Load Test ROM

Purpose:

```text
Verify file loading.
```

Behavior:

```text
1. Find HELLO.PRG.
2. Load it.
3. Print start and end address.
4. Optionally jump/run.
```

### 18.4 Error Test ROM

Purpose:

```text
Verify errors are deterministic.
```

Behavior:

```text
1. Read Track 0/Sector 0.
2. Expect INVALID_TRACK.
3. Read Track 1/Sector 21.
4. Expect INVALID_SECTOR.
5. Unmount disk.
6. Try reading Track 18/Sector 1.
7. Expect NO_IMAGE_MOUNTED.
```

---

## 19. Debugging and Diagnostics

### 19.1 Emulator Debug Log

Add optional debug logging:

```text
[D64] MOUNT path=... size=174848 tracks=35 readonly=1
[D64] READ track=18 sector=0 index=357 offset=91392 sd_block=178 half=256 result=OK
[D64] READ track=18 sector=1 index=358 offset=91648 sd_block=179 half=0 result=OK
[D64] READ track=35 sector=17 result=INVALID_SECTOR
[D64] UNMOUNT result=OK
```

### 19.2 FPGA Debug Options

Use at least one:

```text
UART debug output
on-screen boot messages
status LEDs
debug registers
```

Recommended debug registers:

```text
$8A0A DISK_DEBUG_INDEX_LO
$8A0B DISK_DEBUG_INDEX_HI
$8A0C DISK_DEBUG_SD_BLOCK_0
$8A0D DISK_DEBUG_SD_BLOCK_1
$8A0E DISK_DEBUG_SD_BLOCK_2
$8A0F DISK_DEBUG_SD_BLOCK_3
```

### 19.3 On-screen Debug Output

During boot menu:

```text
SD OK
FAT32 OK
3 D64 FILES FOUND
MOUNTED TESTDISK.D64
D64 SIZE 174848
READ ONLY
```

During failure:

```text
NO SD CARD
NO D64 FILES
INVALID D64 SIZE
SD READ ERROR
```

---

## 20. Error Handling Policy

### 20.1 Hardware Errors

Handle:

```text
No SD card
SD init failed
FAT32 mount failed
File open failed
SD read timeout
Unsupported D64 size
```

### 20.2 D64 Logical Errors

Handle:

```text
Invalid track
Invalid sector
Invalid directory chain
Invalid file chain
File not found
Unsupported file type
Load address invalid
Memory range invalid
```

### 20.3 6502-visible Errors

Expose errors through:

```text
DISK_RESULT
Carry flag in kernel routines
Readable BASIC/monitor error message
```

Example mapping:

```text
DISK_NO_IMAGE:
  ?NO DISK MOUNTED

DISK_INVALID_TRACK:
  ?INVALID TRACK

DISK_INVALID_SECTOR:
  ?INVALID SECTOR

DISK_SD_READ_ERROR:
  ?DISK READ ERROR

DISK_UNSUPPORTED:
  ?UNSUPPORTED DISK IMAGE

DISK_FILE_NOT_FOUND:
  ?FILE NOT FOUND

DISK_FILE_CHAIN_ERROR:
  ?BAD FILE CHAIN
```

---

## 21. Write Support Plan for Later

Do not implement write support in Version 1.

When read-only mode is stable, add the following.

### 21.1 Required Commands

```text
WRITE_SECTOR
FLUSH
```

### 21.2 Required Features

```text
- 6502 can write DISK_BUFFER.
- WRITE_SECTOR writes buffer to mounted D64.
- Dirty flag is set after write.
- FLUSH ensures SD-card writeback.
- Write-protect flag prevents writes.
```

### 21.3 File SAVE Requirements

To implement SAVE, the system must:

```text
1. Parse BAM.
2. Find free sectors.
3. Allocate sector chain.
4. Write PRG data blocks.
5. Create directory entry.
6. Update BAM.
7. Flush image.
```

### 21.4 Corruption Risks

Be careful with:

```text
- updating BAM before data is fully written
- partially written directory entries
- power loss during write
- wrong final sector byte count
- duplicate filenames
- overwriting existing files
```

### 21.5 Safer Write Policy

When SAVE is implemented:

```text
1. Write all file data blocks first.
2. Then update directory entry.
3. Then update BAM.
4. Then flush.
```

Alternative safer policy:

```text
- Keep write support disabled by default.
- Require explicit writable mount.
- Keep backup copy or journal later if desired.
```

---

## 22. Optional Future Features

Only after Version 1 is stable.

### 22.1 Runtime Disk Swap

```text
- Hotkey or menu opens image selector.
- Disk can be swapped while 6502 is running.
- MOUNTED flag updates.
```

### 22.2 Multiple Drives

```text
Drive 8
Drive 9
Drive 10
Drive 11
```

Possible MMIO model:

```text
DISK_ACTIVE_DRIVE register
same command interface
per-drive mounted image metadata
```

### 22.3 C64-like DOS Commands

Subset:

```text
LOAD "$",8
LOAD "NAME",8,1
SAVE "NAME",8
OPEN command channel
SCRATCH
RENAME
VALIDATE
INITIALIZE
```

### 22.4 Full 1541 Emulation

Explicitly out of scope unless required:

```text
1541 CPU
1541 ROM
VIA emulation
IEC serial bus timing
cycle-level behavior
fastloader compatibility
copy protection
G64 nibble format
```

---

## 23. Compatibility Notes

This drive shall be D64-compatible at the storage level.

It does not guarantee that arbitrary C64 software will run.

Reasons:

```text
- C64 software may expect VIC-II at $D000.
- C64 software may expect SID at $D400.
- C64 software may expect CIA chips at $DC00/$DD00.
- C64 software may use IEC routines or fastloaders.
- C64 software may rely on exact KERNAL behavior.
```

This system shall support:

```text
- PRG files stored inside D64 images
- BASIC programs compatible with the system BASIC
- machine-code programs written for this system
- test programs packaged as D64
```

---

## 24. Documentation Requirements

Create:

```text
docs/D64_DRIVE.md
```

Content:

```text
- overview
- architecture diagram
- supported D64 formats
- memory map
- register descriptions
- command descriptions
- result codes
- usage from boot menu
- usage from BASIC/monitor
- emulator usage
- test image generation
- limitations
- future write support
```

Add a short README near test images:

```text
roms/test_d64/README.md
```

Content:

```text
- what testdisk.d64 contains
- how it was generated
- which tests use it
```

---

## 25. Agent Instructions

When implementing this project:

```text
- Preserve existing memory map unless explicitly changed.
- Do not break sound, video, keyboard or ROM loading.
- Keep emulator and FPGA register behavior identical.
- Implement emulator support first if possible.
- Keep Version 1 read-only.
- Add tests before adding write support.
- Use clear result codes for every failure.
- Do not silently ignore invalid track/sector input.
- Do not implement full 1541 emulation for Version 1.
- Do not make 6502 parse FAT32.
- Keep 6502 routines small and reusable.
- Keep all addresses in shared include files where possible.
```

Before modifying code:

```text
1. Inspect current memory map.
2. Check existing I/O address usage.
3. Check current FPGA boot menu implementation.
4. Check current SD-card implementation.
5. Check current emulator device model.
6. Check current kernel build system.
7. Check current ROM build system.
```

After each phase:

```text
- Build emulator.
- Build kernel/ROM.
- Run tests.
- If FPGA code changed, run synthesis or at least simulation.
- Update docs.
```

---

## 26. Version 1 Definition of Done

Version 1 is complete when all of the following are true:

```text
- SD card can contain one or more .d64 files.
- FPGA boot menu can list valid .d64 files.
- User can select one .d64 image.
- Selected image is mounted read-only.
- DISK_STATUS reports MOUNTED.
- 6502 can issue READ_SECTOR.
- DISK_BUFFER contains the requested 256-byte D64 sector.
- Track/sector validation works.
- Directory can be read from Track 18/Sector 1.
- Directory can be printed.
- PRG file can be found by name.
- PRG file can be loaded into RAM.
- Loaded BASIC PRG can run.
- Loaded machine-code PRG can be started.
- Emulator supports the same MMIO interface.
- Emulator and FPGA behavior match.
- Test D64 image exists.
- D64 tooling exists.
- Documentation exists.
- Write support is still disabled or explicitly unsupported.
```

---

## 27. First Practical Milestone

The first useful demo shall be:

```text
1. Copy TESTDISK.D64 to SD card.
2. Start FPGA computer.
3. Boot menu shows TESTDISK.D64.
4. Select TESTDISK.D64.
5. System boots.
6. User enters DIR.
7. Directory is displayed.
8. User enters LOAD "HELLO".
9. Program loads.
10. User enters RUN.
11. HELLO program runs.
```

This is the milestone that turns the system from a UART-loaded development machine into a standalone SD-card-based homecomputer-like system.

---

## 28. Minimal Implementation Checklist

Use this condensed checklist during implementation.

```text
[ ] Choose final DISK_BASE address.
[ ] Add register constants.
[ ] Add d64_sector_index implementation.
[ ] Add sector mapping tests.
[ ] Add host-side D64 list tool.
[ ] Add emulator D64 mount option.
[ ] Add emulator MMIO disk controller.
[ ] Add READ_SECTOR command.
[ ] Add 6502 disk_read_sector.
[ ] Add sector read test ROM.
[ ] Add directory reader.
[ ] Add directory test ROM.
[ ] Add PRG loader.
[ ] Add PRG load test ROM.
[ ] Add FPGA disk MMIO registers.
[ ] Add FPGA disk buffer.
[ ] Add FPGA SD-backed sector read.
[ ] Add FPGA boot menu D64 listing.
[ ] Add FPGA boot menu mount action.
[ ] Add BASIC/monitor DIR.
[ ] Add BASIC/monitor LOAD.
[ ] Add docs/D64_DRIVE.md.
[ ] Add roms/test_d64/testdisk.d64.
[ ] Verify emulator and FPGA behave identically.
```
