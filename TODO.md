# TODO: Neue C64-kompatible Memory-Map

## Entscheidungen (festgelegt)
- **Framebuffer**: Dediziertes VRAM, **kein** flaches CPU-Mapping. CPU greift über
  Auto-Increment-Port (Modell TMS9918 / X16-VERA) zu.
- **Banking**: Fixe Dekodierung, kein C64-PLA-Banking (kein RAM unter ROM/IO).
- **Legacy-IO**: UART / USB-HID / Disk werden in die freien Bytes der VIA-Pages gefaltet.

## Hinweis
Der aktuelle "Framebuffer" ist trotz `40KB`-Kommentaren real nur **8000 Bytes**
($9010-$AF4F = 320x200x1bpp Hires). Kommentare in `sbc_pkg.vhd` sind irreführend.

## Finale Memory-Map (fixe Dekodierung)

| Bereich     | Größe | Inhalt                          |
|-------------|-------|---------------------------------|
| `$0000-$9FFF` | 40KB  | RAM                             |
| `$A000-$BFFF` | 8KB   | BASIC ROM (optional, sonst RAM) |
| `$C000-$CFFF` | 4KB   | RAM                             |
| `$D000-$D3FF` | 1KB   | Video-Register + VRAM-Port      |
| `$D400-$D7FF` | 1KB   | SID + 4 Extra-Sound-Kanäle      |
| `$D800-$DBFF` | 1KB   | Color RAM                       |
| `$DC00-$DCFF` | 256B  | VIA #1 + UART                   |
| `$DD00-$DDFF` | 256B  | VIA #2 + USB-HID + Disk         |
| `$DE00-$DEFF` | 256B  | FPU                             |
| `$DF00-$DFFF` | 256B  | System Control / MMU            |
| `$E000-$FFFF` | 8KB   | Kernel ROM                      |

## Video-Register-Layout ($D000-$D3FF)

```
$D000-$D02E  VIC-II-kompatible Register (Raster, Control, Sprite X/Y, Border/BG ...)
$D030-$D03F  Blitter (16B)
$D040-$D07F  Sprite-Controller (64B)
$D080        VRAM_ADDR_LO   ┐
$D081        VRAM_ADDR_HI   ├ VRAM-Port: ADDR setzen, dann DATA streamen
$D082        VRAM_DATA      ┘ (Read/Write inkrementiert ADDR automatisch)
$D083        VRAM_CTRL      (Increment-Schritt, Auto-Inc on/off)
```

Bitmap (8KB), Text-Matrix (2KB) und Sprite-Pattern (256B) liegen alle im dedizierten
VRAM und werden über den Port beschrieben.

## Gefaltete Legacy-IO

```
$DC00-$DC0F  VIA #1            $DD00-$DD0F  VIA #2
$DC10-$DC13  UART              $DD10-$DD13  USB-HID-Host
                               $DD20-$DD2B  Disk-Controller
```

## Umsetzungs-Schritte
- [ ] `MEMORYMAP.md` als verbindliche Referenz schreiben
- [ ] `sbc_pkg.vhd`: neue Konstanten + `device_sel_t` anpassen (VIC_TEXT/BMP/SPD entfallen als CPU-Devices)
- [ ] `bus_decode.vhd`: 256B-aligned Decoder (nur A8-A15 vergleichen)
- [ ] VIC: internes Dual-Port-BlockRAM als VRAM + Auto-Increment-Port verdrahten
- [ ] Software: alle direkten Bitmap-/Text-Zugriffe ($8000 / $9010) auf VRAM-Port umstellen
      (Kernel-Grafik-/Render-/Print-Routinen). `soundsid.s` ist NICHT betroffen.

## Auswirkung
- VHDL: klein (Decoder simpler, VRAM wird Dual-Port-BlockRAM des VIC).
- Software: eigentliche Arbeit — jeder direkte Bitmap-/Text-Zugriff muss über den
  VRAM-Port laufen. Das ist der einzige echte Stolperstein.

---

# AKTUELL: ROM-Relokation (EhBASIC raus aus $D000-$DFFF)

## Hintergrund / Root-Cause des "Syntax Error"
Die Sound-Änderung legte den **SID auf $D400-$D418**, dekodiert vor dem ROM. EhBASIC
liegt aber bei $D000-$FFFF → der SID verdeckte ~25 Bytes der Keyword-Tabelle →
"?Syntax Error" bei jedem Befehl. EhBASIC lief vor der Sound-Änderung, weil $D400
reines ROM war. (Interim-Fix aktiv: SID als Write-Only-Overlay, Reads $D400-$D418 ->
ROM, in `sbc_t65_boot_monitor_top.vhd`. Wird mit der Relokation entfernt.)

## Ziel-Layout (bestätigt)
```
$0000-$9FFF  RAM (40K)
$A000-$CFFF  EhBASIC (12K, zusammenhängend; BASIC startet C64-like bei $A000)
$D000-$DFFF  I/O (frei für künftige Video/SID/Color/VIA/FPU/SysCtrl; SID schon $D400)
$E000-$EFFF  frei (vorerst)
$F000-$FFFF  Kernel (4K, Jump-Table $F000, Vektoren $FFFA)
```
ROM-Image bleibt 16K im `boot_shadow_rom` (ADDR_WIDTH=14). Adress->Offset:
- $A000-$CFFF -> offset (addr - $A000)   = $0000-$2FFF (EhBASIC)
- $F000-$FFFF -> offset (addr - $C000)   = $3000-$3FFF (Kernel)

## Schritte
### RTL (verifizierbar mit GHDL) — ERLEDIGT, GHDL-clean
- [x] `sbc_pkg.vhd`: neue Konstanten ADDR_BASROM/KERNROM + Helfer `is_rom_addr()`,
      `rom_offset()`. ADDR_ROM_BASE/LAST bleiben für Legacy-Monitore.
- [x] `bus_decode.vhd`: $A000-$CFFF und $F000-$FFFF -> DEV_ROM; $D400-$D418 -> DEV_SID;
      DEV_VIC_BMP-Decode entfernt (Bitmap interim deaktiviert).
- [x] `sbc_t65_boot_monitor_top.vhd`: `rom_addr_mux`/`rom_load_addr_mux` via `rom_offset()`,
      Monitor-FSM via `is_rom_addr()`, SID-Band-Aid zurückgenommen (DEV_SID -> sid_dout).
- Bitmap-Subsystem im Top bleibt instanziiert, wird durch fehlenden Decode inert
  (kein CPU-Zugriff). Mandelbrot-Bitmap-Demo defekt bis VRAM-Port.
### Build / Firmware — ERLEDIGT, ROM gebaut + Image verifiziert
- [x] `ehbasic_fpga.cfg`: ROM start $A000 size $3000; VECTORS-Segment entfernt.
- [x] `ehbasic_fpga.s`: feste ENTRY_TABLE ($A000=reset/$A003=irq/$A006=nmi);
      KERNAL_*-Equates -> $F00x; eigenes VECTORS-Segment entfernt.
- [x] Schwester `kernel.cfg`: ROM start $F000 size $0FFA; VECTORS @ $FFFA.
- [x] Schwester `kernel.s`: BASIC_ENTRY=$A000; VECTORS @ $FFFA -> $A006/$A000/$A003.
      kernel.rom neu gebaut + Vektoren verifiziert.
- [x] `build_fpga_ehbasic.py`: Image-Reihenfolge EhBASIC|Kernel; zwei Segment-Dateien
      (fpga_ehbasic_A000.bin, fpga_kernel_F000.bin); zweistufiger Upload + G A000.

### Verifiziertes ROM-Image (16K)
- offset $0000: `4C 09 A0` (JMP RESET_ENTRY $A009), $A003->irq, $A006->nmi
- offset $3000: Kernel JMP INIT ($F020); Vektoren @ $3FFA: RESET=$A000 IRQ=$A003 NMI=$A006

## Noch offen
- [ ] Bitstream neu synthetisieren + flashen (RTL-Änderung).
- [ ] Zwei-Segment-ROM hochladen + auf HW testen (nicht simulierbar).
- [ ] SD-Boot-Image prüfen: lädt make_sd_boot_image per Offset (dann ok) oder per Adresse?
- [ ] Später: VRAM-Port -> Bitmap reaktivieren; Restliche I/O nach $D000-$DFFF.

## Risiko
Boot-kritisch + 2 Repos. RTL + Firmware passen zusammen (rom_offset $A000->0, $F000->$3000;
Kernel-$FFFA -> EhBASIC-ENTRY_TABLE). Vor dem Flashen: beide Segmente hochladen.
