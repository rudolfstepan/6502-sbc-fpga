#!/usr/bin/env python3
"""End-to-end regression test for the combined C64 SD hook.

Runs roms/diagnostics/sd_fastload_hook.prg (fastloader + FAT16 disk menu) in
a minimal 6502 emulator against a FAT16 card image, with the probe's
$DF00-$DF0D SD window emulated on top of the image file.  Covers: install,
load-without-mount error, LOAD"@" menu mounts (checked against an independent
FAT16/D64 parse), LOAD"*" and named fastloads compared byte-for-byte,
missing-file error, and the $/VERIFY fallback into the stock KERNAL path.

Usage (from the repo root, image from tools/d64/make_fat16_d64_card.py):
    python tools/test_c64_sd_hook.py build/test_fat16_card.img
or simply:
    make c64-sd-hook-test
"""

import json, sys

STANDALONE = "--standalone" in sys.argv[1:]
argv = [a for a in sys.argv[1:] if not a.startswith("--")]

if not argv:
    raise SystemExit(__doc__)

IMG = argv[0]
image = open(IMG, "rb").read()

PRG = argv[1] if len(argv) > 1 else "roms/diagnostics/sd_fastload_hook.prg"
SEG = PRG + ".segments.json"

ram = bytearray(0x10000)
if STANDALONE:
    # Standalone boot path: RAM receives only what the FPGA boot loader
    # would copy from the "C64HOOK1" block at LBA 8; install/RUN never runs.
    base = 8 * 512
    if image[base:base + 8] != b"C64HOOK1":
        raise SystemExit("no C64HOOK1 image at LBA 8 (build the card with --hook-image)")
    hook_addr = image[base + 8] | (image[base + 9] << 8)
    hook_len = image[base + 10] | (image[base + 11] << 8)
    ram[hook_addr:hook_addr + hook_len] = image[base + 16:base + 16 + hook_len]
    print(f"standalone boot: {hook_len} bytes at ${hook_addr:04X} from LBA 8")
else:
    prg = open(PRG, "rb").read()
    segmap = json.load(open(SEG))
    for seg in segmap["segments"]:
        a, o, s = seg["address"], seg["offset"], seg["size"]
        ram[a:a + s] = prg[o:o + s]

# --- FAT16 card reference parse ---
def le16(off):
    return image[off] | (image[off + 1] << 8)

def le32(off):
    return le16(off) | (le16(off + 2) << 16)

def fat16_d64_files():
    """Independent FAT16 root parse: list of mounted-D64 candidates."""
    part_lba = 0
    if image[510:512] == b"\x55\xaa":
        ptype = image[446 + 4]
        if ptype in (0x04, 0x06, 0x0E):
            part_lba = le32(446 + 8)

    bs = part_lba * 512
    if le16(bs + 11) != 512:
        raise SystemExit("FAT16 reference parser: unsupported bytes/sector")
    spc = image[bs + 13]
    reserved = le16(bs + 14)
    nfats = image[bs + 16]
    root_entries = le16(bs + 17)
    spf = le16(bs + 22)
    root_secs = (root_entries * 32 + 511) // 512
    root_lba = part_lba + reserved + nfats * spf
    data_lba = root_lba + root_secs

    out = []
    root = root_lba * 512
    for idx in range(root_entries):
        off = root + idx * 32
        first = image[off]
        if first == 0:
            break
        if first == 0xE5 or (image[off + 11] & 0x18):
            continue
        if image[off + 8:off + 11] != b"D64":
            continue
        short = image[off:off + 11].decode("ascii", "replace")
        stem = short[:8].rstrip()
        ext = short[8:11].rstrip()
        cluster = le16(off + 26)
        out.append({
            "name": f"{stem}.{ext}" if ext else stem,
            "start_lba": data_lba + (cluster - 2) * spc,
        })
    return out

card_d64s = fat16_d64_files()
if len(card_d64s) < 2:
    raise SystemExit("test image must contain at least two D64 files")

# --- D64 geometry ---
SPT = [0] + [21]*17 + [19]*7 + [18]*6 + [17]*5   # SPT[track], tracks 1..35

def d64_index(t, s):
    return sum(SPT[1:t]) + s

def d64_read(mount_lba, t, s):
    idx = d64_index(t, s)
    base = (mount_lba + idx // 2) * 512 + (idx % 2) * 256
    return image[base:base + 256]

def d64_first_prg_and_names(mount_lba):
    """Independent D64 dir parse: list of (name, start_t, start_s)."""
    files = []
    t, s = 18, 1
    while True:
        sec = d64_read(mount_lba, t, s)
        for e in range(8):
            off = e * 32
            typ = sec[off + 2]
            if typ & 0x80 and (typ & 0x07) == 2:
                name = bytes(b for b in sec[off + 5:off + 21] if b != 0xA0)
                files.append((name.decode("latin1"), sec[off + 3], sec[off + 4]))
        if sec[0] == 0:
            break
        t, s = sec[0], sec[1]
    return files

def d64_file_bytes(mount_lba, t, s):
    data = b""
    while True:
        sec = d64_read(mount_lba, t, s)
        if sec[0] == 0:
            data += sec[2:sec[1] + 1]
            break
        data += sec[2:256]
        t, s = sec[0], sec[1]
    return data

# --- SD window ---
class SD:
    def __init__(self):
        self.lba = [0, 0, 0, 0]
        self.buf = bytearray(256)
        self.offset = 0
        self.track = 0x12
        self.sector = 1
        self.error = False
        self.ready = False
        self.mounted = None
        self.mounts = 0

    def lba32(self):
        return self.lba[0] | (self.lba[1] << 8) | (self.lba[2] << 16) | (self.lba[3] << 24)

    def read(self, a):
        off = a & 0x0F
        if off <= 3: return self.lba[off]
        if off == 0x05:
            return 0x81 | (0x02 if False else 0) | (0x04 if self.mounted is not None else 0)
        if off == 0x08: return self.track
        if off == 0x09: return self.sector
        if off == 0x0A: return self.offset
        if off == 0x0B:
            return (0x81 | (0x04 if self.ready else 0) | (0x08 if self.error else 0)
                    | (0x10 if self.mounted is not None else 0))
        if off == 0x0C: return self.buf[self.offset]
        return 0

    def write(self, a, v):
        off = a & 0x0F
        if off <= 3: self.lba[off] = v
        elif off == 0x04:
            if v & 1:
                self.mounted = self.lba32()
                self.mounts += 1
        elif off == 0x08: self.track = v
        elif off == 0x09: self.sector = v & 0x1F
        elif off == 0x0A: self.offset = v
        elif off == 0x0B:
            if v & 2: self.error = False
            if v & 1:
                self.ready = False
                t, s = self.track, self.sector
                if self.mounted is None or not (1 <= t <= 35) or s >= SPT[t]:
                    self.error = True
                else:
                    self.buf = bytearray(d64_read(self.mounted, t, s))
                    self.ready = True
        elif off == 0x0D:
            if v & 1:
                self.ready = False
                lba = self.lba32()
                half = (v >> 1) & 1
                base = lba * 512 + half * 256
                chunk = image[base:base + 256]
                self.buf = bytearray(chunk) + bytearray(256 - len(chunk))
                self.error = False
                self.ready = True

sd = SD()
output = []
keys = []
fellback = [False]

def rd(a):
    if 0xDF00 <= a <= 0xDF0F: return sd.read(a)
    return ram[a]

def wr(a, v):
    if 0xDF00 <= a <= 0xDF0F: sd.write(a, v)
    else: ram[a] = v

# --- CPU core ---
def run(pc, a=0, x=0, y=0, max_steps=50_000_000):
    global fellback
    A, X, Y, SP, PC = a, x, y, 0xFD, pc
    N = V = Z = C = False
    steps = 0

    def set_nz(v):
        nonlocal N, Z
        N = bool(v & 0x80); Z = (v == 0)

    def push(v):
        nonlocal SP
        ram[0x100 + SP] = v & 0xFF; SP = (SP - 1) & 0xFF

    def pop():
        nonlocal SP
        SP = (SP + 1) & 0xFF; return ram[0x100 + SP]

    while True:
        steps += 1
        if steps > max_steps:
            raise SystemExit("runaway")
        if PC == 0xF4A5:
            fellback[0] = True
            return ("fallback", A, X, Y, C)
        if PC == 0xFFD2:
            output.append(A)
            lo = ram[0x100 + ((SP + 1) & 0xFF)]; hi = ram[0x100 + ((SP + 2) & 0xFF)]
            SP = (SP + 2) & 0xFF; PC = ((hi << 8) | lo) + 1
            continue
        if PC == 0xFFE4:
            A = keys.pop(0) if keys else 3
            set_nz(A)
            lo = ram[0x100 + ((SP + 1) & 0xFF)]; hi = ram[0x100 + ((SP + 2) & 0xFF)]
            SP = (SP + 2) & 0xFF; PC = ((hi << 8) | lo) + 1
            continue

        op = ram[PC]
        b1 = ram[(PC + 1) & 0xFFFF]
        w = b1 | (ram[(PC + 2) & 0xFFFF] << 8)

        def adc(v):
            nonlocal A, C, V
            r = A + v + (1 if C else 0)
            V = bool((~(A ^ v) & (A ^ r)) & 0x80)
            C = r > 0xFF; A = r & 0xFF; set_nz(A)

        def cmp_(reg, v):
            nonlocal C
            C = reg >= v; set_nz((reg - v) & 0xFF)

        def br(cond):
            nonlocal PC
            PC += 2
            if cond:
                PC = (PC + (b1 - 256 if b1 & 0x80 else b1)) & 0xFFFF

        if op == 0xEA: PC += 1
        elif op == 0x78 or op == 0x58 or op == 0xD8: PC += 1
        elif op == 0x18: C = False; PC += 1
        elif op == 0x38: C = True; PC += 1
        elif op == 0xA9: A = b1; set_nz(A); PC += 2
        elif op == 0xA5: A = rd(b1); set_nz(A); PC += 2
        elif op == 0xAD: A = rd(w); set_nz(A); PC += 3
        elif op == 0xBD: A = rd((w + X) & 0xFFFF); set_nz(A); PC += 3
        elif op == 0xB9: A = rd((w + Y) & 0xFFFF); set_nz(A); PC += 3
        elif op == 0xB1:
            p = (ram[b1] | (ram[(b1 + 1) & 0xFF] << 8)); A = rd((p + Y) & 0xFFFF); set_nz(A); PC += 2
        elif op == 0x85: wr(b1, A); PC += 2
        elif op == 0x8D: wr(w, A); PC += 3
        elif op == 0x9D: wr((w + X) & 0xFFFF, A); PC += 3
        elif op == 0x99: wr((w + Y) & 0xFFFF, A); PC += 3
        elif op == 0x91:
            p = (ram[b1] | (ram[(b1 + 1) & 0xFF] << 8)); wr((p + Y) & 0xFFFF, A); PC += 2
        elif op == 0xA2: X = b1; set_nz(X); PC += 2
        elif op == 0xA6: X = rd(b1); set_nz(X); PC += 2
        elif op == 0xAE: X = rd(w); set_nz(X); PC += 3
        elif op == 0xA0: Y = b1; set_nz(Y); PC += 2
        elif op == 0xA4: Y = rd(b1); set_nz(Y); PC += 2
        elif op == 0xAC: Y = rd(w); set_nz(Y); PC += 3
        elif op == 0x86: wr(b1, X); PC += 2
        elif op == 0x8E: wr(w, X); PC += 3
        elif op == 0x84: wr(b1, Y); PC += 2
        elif op == 0x8C: wr(w, Y); PC += 3
        elif op == 0xAA: X = A; set_nz(X); PC += 1
        elif op == 0xA8: Y = A; set_nz(Y); PC += 1
        elif op == 0x8A: A = X; set_nz(A); PC += 1
        elif op == 0x98: A = Y; set_nz(A); PC += 1
        elif op == 0xE8: X = (X + 1) & 0xFF; set_nz(X); PC += 1
        elif op == 0xC8: Y = (Y + 1) & 0xFF; set_nz(Y); PC += 1
        elif op == 0xCA: X = (X - 1) & 0xFF; set_nz(X); PC += 1
        elif op == 0x88: Y = (Y - 1) & 0xFF; set_nz(Y); PC += 1
        elif op == 0x48: push(A); PC += 1
        elif op == 0x68: A = pop(); set_nz(A); PC += 1
        elif op == 0x69: adc(b1); PC += 2
        elif op == 0x65: adc(rd(b1)); PC += 2
        elif op == 0x6D: adc(rd(w)); PC += 3
        elif op == 0x7D: adc(rd((w + X) & 0xFFFF)); PC += 3
        elif op == 0xE9: adc(b1 ^ 0xFF); PC += 2
        elif op == 0xE5: adc(rd(b1) ^ 0xFF); PC += 2
        elif op == 0xED: adc(rd(w) ^ 0xFF); PC += 3
        elif op == 0xC9: cmp_(A, b1); PC += 2
        elif op == 0xC5: cmp_(A, rd(b1)); PC += 2
        elif op == 0xCD: cmp_(A, rd(w)); PC += 3
        elif op == 0xE0: cmp_(X, b1); PC += 2
        elif op == 0xC0: cmp_(Y, b1); PC += 2
        elif op == 0xC4: cmp_(Y, rd(b1)); PC += 2
        elif op == 0xCC: cmp_(Y, rd(w)); PC += 3
        elif op == 0x29: A &= b1; set_nz(A); PC += 2
        elif op == 0x25: A &= rd(b1); set_nz(A); PC += 2
        elif op == 0x2D: A &= rd(w); set_nz(A); PC += 3
        elif op == 0x2C:
            v = rd(w); Z = ((A & v) == 0); N = bool(v & 0x80); V = bool(v & 0x40); PC += 3
        elif op == 0x09: A |= b1; set_nz(A); PC += 2
        elif op == 0x05: A |= rd(b1); set_nz(A); PC += 2
        elif op == 0x0D: A |= rd(w); set_nz(A); PC += 3
        elif op == 0x0A: C = bool(A & 0x80); A = (A << 1) & 0xFF; set_nz(A); PC += 1
        elif op == 0x4A: C = bool(A & 1); A >>= 1; set_nz(A); PC += 1
        elif op == 0x2A:
            nc = bool(A & 0x80); A = ((A << 1) | (1 if C else 0)) & 0xFF; C = nc; set_nz(A); PC += 1
        elif op == 0x6A:
            nc = bool(A & 1); A = (A >> 1) | (0x80 if C else 0); C = nc; set_nz(A); PC += 1
        elif op in (0x06, 0x0E):
            a2 = b1 if op == 0x06 else w; v = rd(a2); C = bool(v & 0x80); v = (v << 1) & 0xFF; wr(a2, v); set_nz(v); PC += 2 if op == 0x06 else 3
        elif op in (0x46, 0x4E):
            a2 = b1 if op == 0x46 else w; v = rd(a2); C = bool(v & 1); v >>= 1; wr(a2, v); set_nz(v); PC += 2 if op == 0x46 else 3
        elif op in (0x26, 0x2E):
            a2 = b1 if op == 0x26 else w; v = rd(a2); nc = bool(v & 0x80); v = ((v << 1) | (1 if C else 0)) & 0xFF; C = nc; wr(a2, v); set_nz(v); PC += 2 if op == 0x26 else 3
        elif op in (0x66, 0x6E):
            a2 = b1 if op == 0x66 else w; v = rd(a2); nc = bool(v & 1); v = (v >> 1) | (0x80 if C else 0); C = nc; wr(a2, v); set_nz(v); PC += 2 if op == 0x66 else 3
        elif op in (0xE6, 0xEE):
            a2 = b1 if op == 0xE6 else w; v = (rd(a2) + 1) & 0xFF; wr(a2, v); set_nz(v); PC += 2 if op == 0xE6 else 3
        elif op in (0xC6, 0xCE):
            a2 = b1 if op == 0xC6 else w; v = (rd(a2) - 1) & 0xFF; wr(a2, v); set_nz(v); PC += 2 if op == 0xC6 else 3
        elif op == 0x4C: PC = w
        elif op == 0x6C:
            PC = ram[w] | (ram[(w + 1) & 0xFFFF] << 8)
        elif op == 0x20:
            r = PC + 2; push((r >> 8) & 0xFF); push(r & 0xFF); PC = w
        elif op == 0x60:
            if SP == 0xFD:
                return ("rts", A, X, Y, C)
            lo = pop(); hi = pop(); PC = ((hi << 8) | lo) + 1
        elif op == 0xF0: br(Z)
        elif op == 0xD0: br(not Z)
        elif op == 0x90: br(not C)
        elif op == 0xB0: br(C)
        elif op == 0x10: br(not N)
        elif op == 0x30: br(N)
        else:
            raise SystemExit(f"unimplemented opcode ${op:02X} at ${PC:04X}")

def petscii(buf):
    return "".join(chr(c) if 32 <= c < 127 else ("\n" if c == 13 else f"<{c:02X}>") for c in buf)

def flush_output(label):
    global output
    print(f"--- {label} ---")
    print(petscii(output))
    output = []

def call_load(name, sa, a=0, addr=0x0801):
    """Enter the hook LOAD entry like the KERNAL stub would."""
    fellback[0] = False
    ram[0xBA] = 8
    ram[0xB9] = sa
    ram[0xB7] = len(name)
    ram[0xBB] = 0x40
    ram[0xBC] = 0x03
    for i, ch in enumerate(name):
        ram[0x340 + i] = ord(ch)
    return run(0xC006, a=a, x=addr & 0xFF, y=addr >> 8)

fails = []

def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)

# BASIC state
ram[0x2B] = 0x01; ram[0x2C] = 0x08          # TXTTAB $0801
ram[0x2D] = 0x03; ram[0x2E] = 0x08          # VARTAB $0803

# 1) install via SYS 49152 (skipped in standalone mode: the KERNAL guard
#    stub enters at $C006 without install ever having run)
if not STANDALONE:
    res = run(0xC000)
    flush_output("install")
    check(ram[0x330] | (ram[0x331] << 8) != 0, "ILOAD written")
else:
    check(ram[0xC000] == 0x2C, "hook BIT signature present at $C000")

# 2) fastload before any mount -> $E5 error + hint, carry set, A=$04
res = call_load("*", 1)
flush_output("LOAD\"*\",8,1 without mount")
check(res[0] == "rts" and res[4] is True and res[1] == 0x04,
      f"unmounted load fails cleanly (got {res[0]}, A=${res[1]:02X}, C={res[4]})")

# 3) menu: LOAD"@",8 -> pick disk 1
keys[:] = [ord("1")]
res = call_load("@", 0)
flush_output("LOAD\"@\",8 menu, key 1")
check(res[0] == "rts" and res[4] is False, "menu returns clean")
check(sd.mounted == card_d64s[0]["start_lba"],
      f"mounted {card_d64s[0]['name']} at LBA {card_d64s[0]['start_lba']} (got {sd.mounted})")
check((res[2] | (res[3] << 8)) == 0x0803, "menu preserves VARTAB in X/Y")

files = d64_first_prg_and_names(sd.mounted)
print("D64 directory:", files)

# 4) LOAD"*",8,1 fastload of the first PRG
first_name, ft, fs = files[0]
expect = d64_file_bytes(sd.mounted, ft, fs)
load_addr = expect[0] | (expect[1] << 8)
payload = expect[2:]
res = call_load("*", 1)
flush_output("LOAD\"*\",8,1")
got = bytes(ram[load_addr:load_addr + len(payload)])
end = res[2] | (res[3] << 8)
check(res[0] == "rts" and res[4] is False, "fastload * returns clean")
check(got == payload, f"payload matches ({len(payload)} bytes at ${load_addr:04X})")
check(end == load_addr + len(payload), f"end address ${end:04X}")

# 5) named load of the last PRG in the directory
last_name, lt, ls = files[-1]
expect2 = d64_file_bytes(sd.mounted, lt, ls)
la2 = expect2[0] | (expect2[1] << 8)
ram[la2:la2 + len(expect2)] = bytes(len(expect2))  # scrub target
res = call_load(last_name, 1)
flush_output(f"LOAD\"{last_name}\",8,1")
got2 = bytes(ram[la2:la2 + len(expect2) - 2])
check(res[0] == "rts" and res[4] is False, f"named load '{last_name}' returns clean")
check(got2 == expect2[2:], "named payload matches")

# 6) missing name -> file not found
res = call_load("NOPE", 1)
flush_output("LOAD\"NOPE\",8,1")
check(res[0] == "rts" and res[4] is True and res[1] == 0x04, "missing file fails with A=$04")

# 7) LOAD"$",8 and VERIFY fall back to the KERNAL path
res = call_load("$", 0)
check(res[0] == "fallback", "LOAD\"$\" falls back to $F4A5")
res = call_load("*", 1, a=1)
check(res[0] == "fallback", "VERIFY falls back to $F4A5")
check(res[1] == 1, f"fallback preserves A=1 (got {res[1]})")

# 8) menu again: switch to disk 2, then fastload from it
keys[:] = [ord("2")]
res = call_load("@", 0)
flush_output("LOAD\"@\",8 menu, key 2")
check(sd.mounted == card_d64s[1]["start_lba"],
      f"second disk mounted at {card_d64s[1]['start_lba']} (got {sd.mounted})")
files2 = d64_first_prg_and_names(sd.mounted)
print("D64 #2 directory:", files2)
n2, t2, s2 = files2[0]
exp3 = d64_file_bytes(sd.mounted, t2, s2)
la3 = exp3[0] | (exp3[1] << 8)
res = call_load("*", 1)
flush_output("LOAD\"*\",8,1 from disk 2")
check(bytes(ram[la3:la3 + len(exp3) - 2]) == exp3[2:], "disk-2 payload matches")

# 9) Optional paging regression: cursor down/right shows the next 16-image page.
if len(card_d64s) > 16:
    keys[:] = [0x11, ord("1")]   # C64 cursor down, then first key on page 2
    res = call_load("@", 0)
    flush_output("LOAD\"@\",8 menu, cursor next page, key 1")
    check(res[0] == "rts" and res[4] is False, "paged menu returns clean")
    check(sd.mounted == card_d64s[16]["start_lba"],
          f"paged menu mounted {card_d64s[16]['name']} at {card_d64s[16]['start_lba']} "
          f"(got {sd.mounted})")

# 10) IEC-loader mount mode: LOAD"@I",8 mounts, then clears the $C000 guard
#     signature so the patched KERNAL falls back to the stock IEC path.
ram[0xC000] = 0x2C
keys[:] = [ord("1")]
res = call_load("@I", 0)
flush_output("LOAD\"@I\",8 menu, key 1")
check(res[0] == "rts" and res[4] is False, "@I menu returns clean")
check(sd.mounted == card_d64s[0]["start_lba"],
      f"@I mounted {card_d64s[0]['name']} at LBA {card_d64s[0]['start_lba']} (got {sd.mounted})")
check(ram[0xC000] == 0x00, "IEC mode clears $C000 hook signature")

print()
print("RESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILURES: {fails}")
sys.exit(1 if fails else 0)
