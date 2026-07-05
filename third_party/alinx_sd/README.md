# ALINX SD Card SPI Core

These Verilog files were copied from the PIX16 vendor demo:

`pix16/demo/20_2_sd_sdram_an430_lcd/src`

They provide a sector-level SD card SPI controller used by the SD bootloader
board top. The original source headers permit use and redistribution as long as
the copyright notice is retained.

Files:

- `spi_master.v`
- `sd_card_cmd.v`
- `sd_card_sec_read_write.v`
- `sd_card_top.v`

Local modifications:

- `sd_card_cmd.v`: after a block write (CMD24), the state machine now polls the
  card's busy level (DO held low while programming) until it reads 0xff before
  acknowledging the write. The original returned right after the CRC bytes, so
  a follow-up command hit a busy card and its all-zero busy bytes were
  mistaken for a successful R1=0x00 response.
- `sd_card_cmd.v`: one 0xff gap byte is sent between the CMD24 R1 response and
  the 0xfe start-block token. The spec requires Nwr >= 1 byte there; cards
  that enforce it silently ignored a token sent back-to-back with R1 and the
  whole 512-byte block was lost while the state machine reported success.
- `sd_card_cmd.v`: the R1 response scan in S_CMD starts only after the six
  command bytes have been clocked out. The original compared MISO from byte 0
  on, so residual all-zero busy bytes from an earlier operation matched
  R1=0x00 and aborted the command mid-transmission.
- `sd_card_cmd.v`: the busy poll after the data-response token uses its own
  18-bit counter instead of the shared 16-bit byte counter, so slow cards
  still legally programming (up to 250 ms per spec) no longer trip the
  timeout. All write error paths (no token, data rejected, busy timeout)
  raise `cmd_req_error`, which `sd_card_top` exposes as `debug_cmd_error`;
  it is valid while `sd_sec_write_end` pulses.
