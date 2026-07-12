# NanoMig for Tang Console 138K

> **Status: experimental and not working.** The project currently documents
> an incomplete hardware bring-up. It is not a released or hardware-verified
> Amiga core for the Tang Console 138K.
>
> No Kickstart ROM, converted Kickstart data or other copyrighted Amiga ROM
> content is included. The preparation script accepts only a ROM supplied
> locally by the user and verifies its hash before generating ignored build
> input.

This board project uses the upstream NanoMig/Minimig implementation for the
Tang Console with the Mega 138K module. It is a separate FPGA design and does
not modify System16.

Initialize the pinned upstream source after cloning this repository:

```text
git submodule update --init third_party/NanoMig
```

`prepare_project.bat` applies the versioned board patch from
`patches/nanomig-tc138k.patch` when necessary. The patch is kept outside the
upstream submodule so this repository remains reproducible without referring
to a private NanoMig commit. Re-running the preparation is safe when the patch
is already applied.

## Hardware configuration

- Board: Tang Console with Mega 138K module
- Main memory: external 16-bit SDRAM module on the GPIO connector
- Video/audio: onboard HDMI
- Kickstart storage: 256 KiB inferred block ROM inside the FPGA bitstream
- CPU/chipset: 68000 with OCS/ECS Minimig

The generated board-specific Gowin project is:

`boards/tang_mega_138k/amiga/project/nanomig_tc138k.gprj`

Run `open_project.bat` to prepare and open it. The preparation step validates
the selected Kickstart ROM, converts it into 131072 big-endian 16-bit words,
filters and compresses NanoMig's OSD menu, and creates the local project. Files
are only rewritten when their content changes. Build and SRAM-program the
generated `nanomig_tc138k.fs` from Gowin EDA as usual. This bitstream already
contains Kickstart; no external ROM programming is required.

For persistent operation, program the generated
`project\impl\pnr\nanomig_tc138k.bin` exactly once in Gowin Programmer using
`External Flash Mode Arora V`, operation
`exFlash C Bin Erase,Program,Verify Arora V`, and start address `0x000000`.
Loading `nanomig_tc138k.fs` with SRAM Program remains temporary and will not
survive a power cycle.

If this project is already open in Gowin EDA, close it before running
`open_project.bat`. This ensures the IDE reloads the generated source list and
the required `TopModule=top` process configuration.

The local project omits the unused TG68K/68020 VHDL sources. The Console 138K
top does not enable that core and uses fx68k/68000 only, so this reduces
mixed-language frontend work without changing the synthesized top-level
netlist.

## Kickstart 1.3

The default ROM is read directly from:

`E:\Emulatoren\Amiga\ROMS\Kickstart v1.3 rev 34.5 (1987)(Commodore)(A500-A1000-A2000-CDTV)[!].rom`

The current experiment expects this locally supplied 256 KiB A500 Kickstart
1.3 image, identified only by SHA-256:

`EE05862D8102A08436AC4056DA7D549DB31625C7D47B24DFB7B3C9A5C113CA53`

Validate it and regenerate the project-local block-ROM initialization:

```bat
prepare_project.bat
```

The generated `project\kickstart13_words.hex` is ignored by Git. The
`kickstart_bram` module stores one 256 KiB image and mirrors its 17-bit word
address while filling NanoMig's 512 KiB ROM area in external SDRAM. Changing
the ROM now requires a new FPGA build because its contents are part of the
configuration bitstream.

After the SDRAM copy has passed readback verification, CPU reads in the
Kickstart window are served directly by the same embedded block ROM. This
keeps the 68000 reset-vector and opcode path inside its fixed DTACK budget;
external SDRAM remains the writable Amiga memory and boot-integrity target.

The intended result after a successful future bring-up is the normal
Kickstart insert-disk screen when no floppy image is mounted. That state has
not been reached reliably by this experimental port. Keyboard, mouse, OSD and
ADF file selection would additionally require the NanoMig FPGA Companion
firmware on the onboard BL616.

## Incremental-build impact

- Changed FPGA modules: `src/tang/console138k/top.sv`, `src/hdmi/hdmi.sv`, and
  `src/misc/sdram.sv`, plus the local `rtl/kickstart_bram.sv` and
  and `rtl/sdram_boot_verify.sv` modules.
  The stock BL616 level on V14 is no longer allowed to hold the ROM copy and
  NanoMig core in reset; the physical S0/reset input provides the local
  programming hold. The Console 138K also enables a local 5x-clock reset
  synchronizer for the Gowin HDMI serializers,
  and explicitly selects the 68000 CPU configuration.
  The SDRAM controller runs with its upstream defaults; the local `SYNC_DELAY`
  parameter stays at the stock two synchronization-delay stages.
- Changed interfaces: no top-level or existing module-port changes. Local
  registered interfaces connect `kickstart_bram` to the board-top boot copier
  and `sdram_boot_verify` to the unchanged SDRAM controller port. The optional
  `EXTERNAL_RAM_READ_WAIT` hierarchy parameter stays disabled, so the Minimig
  bus keeps its original timing; the hook remains in the source but is inert.
- Clock/reset changes: the external SDRAM, boot copier and SDRAM verifier run
  at 85 MHz from the HDMI PLL, exactly 3x the 28 MHz chipset clock and
  phase-locked to it — the same arrangement as the Tang Console 60K port. The
  SDRAM clock pin is driven by the PLL's 270-degree-shifted output. An earlier
  revision clocked this logic from the 50 MHz oscillator instead; that clock
  is unrelated to the 28 MHz domain (17/30 ratio), which made the controller
  miss bus cycles and corrupted chip RAM at runtime, so Kickstart failed its
  memory test with a green screen although the boot copy verified clean.
  Four board-top reset gates use `reset_n` instead of `bl616_jtagsel`; only
  the HDMI serializer reset is synchronized into its existing 5x clock domain.
- Constraint changes: the board SDC keeps the two-cycle registered-bus
  relationship from `clk28` into the `clk85` SDRAM domain and excludes the
  protocol-held return path (SDRAM data, block-ROM data, ready/done flags) in
  the opposite direction. The quasi-static `spi_ext` flag is the only
  remaining oscillator-to-`clk28` crossing and stays a false path. I2S and
  HDMI audio are described as their actual `/36` and `/590` derivatives of
  `clk28`. Pin and I/O constraints are unchanged. Existing Companion-SPI and
  audio handshake CDCs are excluded from single-cycle setup/hold analysis.
- Full P&R: required because the embedded ROM adds about 2 Mbit of BSRAM and
  because the SDRAM logic moved into the 85 MHz PLL clock domain. A later
  Kickstart change also requires a new synthesis and P&R.
- Reusable areas: CPU, chipset, SDRAM controller, companion, HDMI clocks, PLL,
  video I/O and all top-level interfaces remain structurally unchanged. Only
  the board-top SDRAM clock attachment and boot path require new placement.

The HDMI output is always driven by the native Amiga video signal. The boot
sequencer still performs exactly `0x40000` SDRAM writes plus one non-written
lookahead read needed to finish its pipelined copy state machine, and the
Kickstart/SDRAM integrity checks still hold the Amiga core in reset when they
fail.
