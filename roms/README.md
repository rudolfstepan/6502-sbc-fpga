# ROM Images

Prebuilt ROM/boot images for the 6502 SBC FPGA build. Most are 16 KB and target
the **split shadow-ROM map** (`$A000–$CFFF` + `$F000–$FFFF`, with the `$D000–$EFFF`
I/O hole left free). Upload them over the UART monitor (press the board's monitor
key first) or from an SD boot image.

See [docs/SOUND.md](../docs/SOUND.md), [docs/SPLIT_ROM_SID_UPDATE.md](../docs/SPLIT_ROM_SID_UPDATE.md)
and [docs/FPGA_TOOLS_GUI.md](../docs/FPGA_TOOLS_GUI.md) for details.

## System & boot ROMs

| File | Description |
| --- | --- |
| `fpga_ehbasic_16kb.rom` | EhBASIC interpreter + kernel, 16 KB split-shadow image. Build/upload via `make -C sw fpga-ehbasic` or the GUI **Build** tab (`build_fpga_ehbasic.py`). |
| `fpga_ehbasic_16kb.img` | Raw SD-card boot image of the EhBASIC ROM (sector 0 header + 16 KB payload). |
| `fpga_ehbasic_A000.bin` | EhBASIC code segment (`$A000–$CFFF`) — split-upload artifact. |
| `fpga_kernel_F000.bin` | Kernel/vectors segment (`$F000–$FFFF`) — split-upload artifact. |

## Demo & diagnostic ROMs

| File | Description |
| --- | --- |
| `upload_demo.rom` | Bring-up demo: LED blink + VGA/HDMI text + UART banner. No arguments needed. |
| `test.prg` | Native C64 VIC-II graphics test PRG for `tools/c64_uart_prg_loader.py`; loads at `$0801`, run with `RUN`, then press any key to cycle text, hires bitmap, multicolour bitmap, ECM text, and multicolour text. Build with `make c64-graphics-test-prg`. |
| `sprite_test.prg` | Native C64 VIC-II sprite test PRG for `tools/c64_uart_prg_loader.py`; loads at `$0801`, run with `RUN`, then shows a moving hires sprite plus multicolour, expanded, and X-MSB sprites. Build with `make c64-sprite-test-prg`. |
| `d016_scroll_test.prg` | Native C64 `$D016` fine-scroll/raster-split diagnostic. It shows three scrolling bands with `$D016` writes at different raster positions to expose line tearing or lower-row jitter. Build with `make c64-d016-scroll-test-prg`. |
| `math_copro_test.prg` | Experimental native C64 math-coprocessor smoke test for the `$DF00-$DF0F` I/O2 register window. The stable C64 bitstream currently disables that window, so this PRG is retained for future timing-clean coprocessor integration. Build with `make c64-math-copro-test-prg`. |
| `mandelbrot_copro_c64.prg` | Experimental native C64 Mandelbrot demo for the `$DF00-$DF0F` math coprocessor window. The stable C64 bitstream currently disables that window; reset after viewing on experimental builds. Build with `make c64-mandelbrot-copro-prg`. |
| `c64_uart_sid/*.prg` | Native C64 UART SID player PRGs. Build with `make c64-sid-prgs`, upload with `tools/c64_uart_prg_loader.py`, then start with `RUN`. Matching `*.prg.segments.json` sidecars let the loader skip large zero-filled gaps during UART upload. These are sound-only PRGs: they clear `$D011.DEN` so the VIC stops RAM fetches and SID playback stays steady. |
| `soundtest.rom` | Legacy 4-voice sound-chip demo (each waveform, an ADSR swell, a 4-voice chord). Uses the old contiguous `$C000–$FFFF` layout — not for the current split map. |
| `mandelbrot_bitmap.rom` | Standalone Mandelbrot renderer using software fixed-point multiply (split-ROM). |
| `mandelbrot_bitmap.img` | SD boot image of the Mandelbrot bitmap ROM. |
| `mandelbrot_copro.bin` | Mandelbrot renderer using the hardware math coprocessor (FPU, `$88B0`). |
| `copro_selftest.bin` | Math-coprocessor self-test. |

## Native SID music ROMs (`sound_*.rom`)

Each `sound_<name>.rom` wraps a real C64 PSID tune in a native MOS 6581 player:
the original 6502 payload is embedded, copied to its load address, and its
`init`/`play` routines are called — so every register write (waveforms, ADSR,
**filter**, etc.) hits the FPGA SID core exactly as on a C64. They are generated
from `sid_orig/` by [`tools/build_all_sid_roms.py`](../tools/build_all_sid_roms.py).

**Upload:** easiest from the GUI **SID Tunes** tab, or run the matching
`upload/sound_<name>.bat`, or directly:

```sh
python tools/upload_monitor_hex.py roms/sound_<name>.rom --split-rom \
       --port COM15 --baud 115200 --run --verbose
```

Only tunes that fit the board's linear RAM (`$0200–$5FFF`), have a real `play`
address, and actually produce sound here are kept. The 38 below are verified to
play; tunes that need a C64's CIA/VIC/KERNAL (hang or stay silent) are not
included.

`soundsid.rom` is the original native-SID example (Matt Gray's *World Record 2*,
`World_Record_2.sid`); it predates the `sound_*.rom` naming and uses no filter,
sync or ring modulation. Upload it with `make -C sw upload-soundsid` or
`upload/soundsid.bat`.

| Tune | Composer | ROM |
| --- | --- | --- |
| 3545 II | Thomas E. Petersen (Laxity) | `sound_3545_ii.rom` |
| Ahead Crack Intro | Markus Schneider (Diflex) | `sound_ahead_crack_intro.rom` |
| Another Tune for Joanna | Neil Baldwin (Demon) | `sound_another_tune_for_joanna.rom` |
| Battle Valley | Jeroen Tel | `sound_battle_valley.rom` |
| The Cat | Markus Müller (Hayes) | `sound_cat.rom` |
| Commando | Rob Hubbard | `sound_commando.rom` |
| Contest Demo (part 2) | Sami Seppä (Rock) | `sound_contest_demo_part_2.rom` |
| Contest Demo (part 4) | Sami Seppä (Rock) | `sound_contest_demo_part_4.rom` |
| D.Y.S.P.I.D.C.E. (part 2) | Sami Seppä (Rock) | `sound_d_y_s_p_i_d_c_e_part_2.rom` |
| Double Dragon | Charles Deenen | `sound_double_dragon.rom` |
| Dynamic Range | Michael Hendriks | `sound_dynamic_range.rom` |
| For Shining 8 | Markus Schneider (Diflex) | `sound_for_shining_8.rom` |
| Garfield | Neil Baldwin (Demon) | `sound_garfield.rom` |
| Ikari Intro | Marcel Donné (Mad) | `sound_ikari_intro_mad.rom` |
| Ikari Union | Jeroen Tel | `sound_ikari_union.rom` |
| K.A.O.S. | Oliver Klüwer (Jess) | `sound_k_a_o_s.rom` |
| Kaos | Markus Schneider | `sound_kaos.rom` |
| Kinetix | Jeroen Tel | `sound_kinetix.rom` |
| The Last Starfighter | Thomas E. Petersen (Laxity) | `sound_last_starfighter.rom` |
| The Magic Writer (tune 00) | Jens Blidon | `sound_magic_writer_tune_00.rom` |
| Noisy Pillars | Jeroen Tel | `sound_noisy_pillars.rom` |
| Pheric | Jens-Christian Huus | `sound_pheric.rom` |
| Public Enemy | Thomas E. Petersen (Laxity) | `sound_public_enemy.rom` |
| R1D1 | Antony Crowther | `sound_r1d1.rom` |
| S-Express | Jeroen Tel | `sound_s_express.rom` |
| Scorpion | Marcel Donné (Mad) | `sound_scorpion.rom` |
| Silence | Thomas Mogensen (DRAX) | `sound_silence.rom` |
| Soldier of Light | Charles Deenen & Jeroen Tel | `sound_soldier_of_light.rom` |
| Something | Thomas E. Petersen (Laxity) | `sound_something.rom` |
| Speedball | David Whittaker | `sound_speedball.rom` |
| Strike Force Introtune | Markus Schneider | `sound_strike_force_introtune.rom` |
| Supremacy | Jeroen Tel | `sound_supremacy.rom` |
| Take Over | Klaus Grøngaard (Link) | `sound_take_over.rom` |
| Thrust | Rob Hubbard | `sound_thrust.rom` |
| Twistin'88 - Part 2 | Thomas E. Petersen (Laxity) | `sound_twistin_88_part_2.rom` |
| UniTechno | Thomas Mogensen (DRAX) | `sound_unitechno.rom` |
| Unitrax '88 Killermix | Henrik Buus Jensen | `sound_unitrax_88_killermix.rom` |
| Zoids | Rob Hubbard | `sound_zoids.rom` |

> Tip: `Commando` and `Thrust` (Rob Hubbard) lean on the SID low-pass filter and
> are good tunes to hear the filter at work.

## `upload/`

Windows `.bat` shortcuts that upload an already-built image with the default
serial settings (`COM15`, `115200`): `ehbasic.bat`, `mandelbrot_bitmap.bat`,
`mandelbrot_copro.bat`, `soundsid.bat`, and one `sound_<name>.bat` per SID tune
above.
