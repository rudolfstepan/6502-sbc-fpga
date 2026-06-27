#!/usr/bin/env python3
"""Build a standalone FPGA ROM (+ Windows upload .bat) for every .sid in a folder.

For each tune under ``sid_orig/`` this wraps the native PSID/RSID payload in a
generic player: it generates the 6502 player source, assembles it with ca65,
links it with ``sw/soundsid.cfg`` (or ``sw/sid_page.cfg`` for $A000-load tunes)
into ``roms/sound_<name>.rom`` and writes ``roms/upload/sound_<name>.bat``.
Tunes that cannot be wrapped (load address in zero page, or a payload too big
for RAM/ROM) are skipped and reported. Curated hand-made ROMs (see ``CURATED``,
e.g. ``roms/sound_commando.rom``) are left untouched unless ``--rebuild-curated``
is given.

Usage:
    python tools/build_all_sid_roms.py [--sid-dir sid_orig] [--rom-dir roms]
        [--port COM15] [--baud 115200] [--keep-src] [--list]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_native_sid_rom import parse_payload, render_asm, SidUnsupported  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

# Curated, hand-crafted ROMs that are NOT tooling output and must never be
# overwritten by the bulk build. `roms/sound_commando.rom` is a bespoke demo
# (commit "add a new sounddemo based on the c64 sid commando") whose generic
# wrapper does not reproduce it; clobbering it with the auto-generated player
# breaks playback. Keyed by the sanitized base name. Use --rebuild-curated to
# override (e.g. when intentionally replacing one).
CURATED = {"commando"}


def sanitize(stem: str) -> str:
    """Turn a tune file name into a safe lower-case rom/bat base name."""
    name = re.sub(r"[^A-Za-z0-9]+", "_", stem).strip("_").lower()
    return name or "tune"


def produces_sound(sid: Path, dump_exe: str, seconds: int) -> bool:
    """Run the tune in the bare 6502 SID emulator and report if it makes sound.

    Returns True if, within the window, the player ever sets a non-zero master
    volume AND gates a voice -- both are necessary for any audible output on the
    bare-RAM FPGA (no CIA/VIC/KERNAL). A tune that fails this is silent here.
    """
    import subprocess
    import tempfile
    out = Path(tempfile.gettempdir()) / "sid_verify.raw"
    try:
        subprocess.run([dump_exe, str(sid), str(seconds), str(out)],
                       check=True, capture_output=True, text=True, timeout=120)
        data = out.read_bytes()
    except Exception:
        return False
    vol = gate = False
    for i in range(0, len(data) - 24, 25):
        fr = data[i:i + 25]
        vol = vol or bool(fr[24] & 0x0F)
        gate = gate or bool((fr[4] | fr[11] | fr[18]) & 1)
        if vol and gate:
            return True
    return False


def bat_text(rom_name: str, title: str, port: str, baud: str) -> str:
    return (
        "@echo off\r\n"
        f"@REM Upload the {title} native SID player split ROM and start it at $A000.\r\n"
        f'python "%~dp0..\\..\\tools\\upload_monitor_hex.py" "%~dp0..\\{rom_name}" '
        f"--split-rom --port {port} --baud {baud} --run --verbose\r\n"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sid-dir", type=Path, default=ROOT / "sid_orig")
    ap.add_argument("--rom-dir", type=Path, default=ROOT / "roms")
    ap.add_argument("--bat-dir", type=Path, default=ROOT / "roms" / "upload")
    ap.add_argument("--cfg", type=Path, default=ROOT / "sw" / "soundsid.cfg")
    ap.add_argument("--ca65", default="C:/tools/cc65/bin/ca65.exe")
    ap.add_argument("--ld65", default="C:/tools/cc65/bin/ld65.exe")
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--baud", default="115200")
    ap.add_argument("--keep-src", action="store_true",
                    help="keep the generated .s sources next to the ROMs")
    ap.add_argument("--list", action="store_true",
                    help="only classify the tunes (build nothing)")
    ap.add_argument("--rebuild-curated", action="store_true",
                    help="also (re)build the curated hand-made ROMs that are "
                         "skipped by default (see CURATED); overwrites them")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the emulator playability check (build every tune "
                         "that merely fits memory, even if it is silent here)")
    ap.add_argument("--dump", default=str(ROOT / "tools" / "sid_dump_full.exe"),
                    help="sid_dump_full executable used for the playability check")
    ap.add_argument("--verify-seconds", type=int, default=6,
                    help="how long to emulate each tune when checking for sound")
    args = ap.parse_args()

    verify = not args.no_verify and Path(args.dump).exists()
    if not args.no_verify and not Path(args.dump).exists():
        print(f"note: {args.dump} not found -> skipping playability check", file=sys.stderr)

    sids = sorted(args.sid_dir.glob("*.sid"))
    if not sids:
        print(f"no .sid files in {args.sid_dir}", file=sys.stderr)
        return 2

    args.rom_dir.mkdir(parents=True, exist_ok=True)
    args.bat_dir.mkdir(parents=True, exist_ok=True)
    src_dir = (args.rom_dir / "sid_src") if args.keep_src else Path(tempfile.mkdtemp())
    src_dir.mkdir(parents=True, exist_ok=True)

    built, skipped, failed = [], [], []
    for sid in sids:
        base = sanitize(sid.stem)
        rom_name = f"sound_{base}.rom"
        if base in CURATED and not args.rebuild_curated:
            skipped.append((sid.name, "curated hand-made ROM kept (use --rebuild-curated to override)"))
            continue
        try:
            info = parse_payload(sid.read_bytes())
        except SidUnsupported as e:
            skipped.append((sid.name, str(e)))
            continue
        if verify and not produces_sound(sid, args.dump, args.verify_seconds):
            skipped.append((sid.name, "silent here (never sets volume/gate)"))
            continue
        if args.list:
            built.append((sid.name, rom_name))
            continue

        asm = render_asm(sid.stem, info)
        s_path = src_dir / f"sound_{base}.s"
        o_path = src_dir / f"sound_{base}.o"
        rom_path = args.rom_dir / rom_name
        s_path.write_text(asm, newline="\n")
        # "page" tunes (load $A000-$CFFF) use the RAM-under-BASIC layout cfg.
        cfg = (ROOT / "sw" / "sid_page.cfg") if info["mode"] == "page" else args.cfg
        try:
            subprocess.run([args.ca65, "--cpu", "6502", "-t", "none",
                            str(s_path), "-o", str(o_path)],
                           check=True, capture_output=True, text=True)
            subprocess.run([args.ld65, "-C", str(cfg), "-o", str(rom_path),
                            str(o_path)], check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            failed.append((sid.name, (e.stderr or e.stdout or "build error").strip().splitlines()[-1]))
            continue

        (args.bat_dir / f"sound_{base}.bat").write_text(
            bat_text(rom_name, sid.stem, args.port, args.baud), newline="")
        built.append((sid.name, rom_name))

    verb = "would build" if args.list else "built"
    print(f"\n{verb} {len(built)} ROM(s), skipped {len(skipped)}, failed {len(failed)} "
          f"(of {len(sids)} tunes)")
    if skipped:
        print("\nskipped (cannot wrap):")
        for name, why in skipped:
            print(f"  {name:42s} {why}")
    if failed:
        print("\nfailed (assembler/linker):")
        for name, why in failed:
            print(f"  {name:42s} {why}")
    if built and not args.list:
        print(f"\nROMs -> {args.rom_dir}\\sound_*.rom   uploaders -> {args.bat_dir}\\sound_*.bat")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
