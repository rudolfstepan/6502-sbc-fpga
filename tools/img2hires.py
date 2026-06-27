#!/usr/bin/env python3
"""Convert an image to the FPGA VIC 320x200 hires bitmap mode (bitmap_mode, VIC
bit0) with 2 colours per 8x8 cell from the 16-entry C64 palette.

Output (written next to --out base):
  <base>_bmp.bin  8000 bytes  linear bitmap  addr = y*40 + x/8, MSB = leftmost px
  <base>_col.bin  1000 bytes  colour RAM     low nibble = fg (bit=1),
                                             high nibble = bg (bit=0; needs $9005=1)
  <base>_preview.png            2x upscaled preview of the result

Per 8x8 cell we pick the optimal palette pair (min nearest-colour error over the
64 source pixels) and Floyd-Steinberg dither the cell between just those two
colours -- the classic C64 hires look, but with the exact hardware palette so
the on-screen colours match.
"""
import argparse
import numpy as np
from PIL import Image

# --- exact hardware palette (rtl/core/peripherals/vic_vga.vhd PAL_R/G/B) ------
PAL_R5 = [0o00, 0o37, 0o21, 0o15, 0o21, 0o13, 0o10, 0o30,
          0o21, 0o13, 0o27, 0o12, 0o17, 0o23, 0o17, 0o24]
PAL_G6 = [0, 0b111111, 0b001110, 0b101110, 0b010000, 0b101000, 0b001100, 0b110100,
          0b011001, 0b010010, 0b011010, 0b010100, 0b011110, 0b111000, 0b011010, 0b101000]
PAL_B5 = [0b00000, 0b11111, 0b00110, 0b11000, 0b10011, 0b01001, 0b10010, 0b01110,
          0b00110, 0b00000, 0b01100, 0b01010, 0b01111, 0b10001, 0b11001, 0b10100]


def build_palette():
    pal = np.zeros((16, 3), np.float64)
    for i in range(16):
        pal[i, 0] = round(PAL_R5[i] * 255 / 31)
        pal[i, 1] = round(PAL_G6[i] * 255 / 63)
        pal[i, 2] = round(PAL_B5[i] * 255 / 31)
    return pal


# perceptual weights (luma) for the colour distance metric
W = np.array([0.299, 0.587, 0.114])


def wdist2(a, b):
    d = a - b
    return np.sum(W * d * d, axis=-1)


def fit_canvas(im, cw=320, ch=200, bg=(0, 0, 0)):
    im = im.convert("RGB")
    w, h = im.size
    scale = min(cw / w, ch / h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (cw, ch), bg)
    canvas.paste(im, ((cw - nw) // 2, (ch - nh) // 2))
    return np.asarray(canvas, np.float64)


def enhance(a, brightness=0.0, contrast=1.0, saturation=1.0, gamma=1.0):
    """Mild tone tuning before quantising; helps the limited palette register."""
    a = a.copy()
    if gamma != 1.0:
        a = 255.0 * np.clip(a / 255.0, 0, 1) ** (1.0 / gamma)
    if contrast != 1.0 or brightness != 0.0:
        a = (a - 128.0) * contrast + 128.0 + brightness
    if saturation != 1.0:
        luma = (a * W).sum(axis=-1, keepdims=True)
        a = luma + saturation * (a - luma)
    return np.clip(a, 0, 255)


def global_dither(src, pal):
    """Serpentine Floyd-Steinberg of the whole image to the full 16 colours.
    Returns an (H,W) array of palette indices."""
    h, w = src.shape[:2]
    work = src.copy()
    qidx = np.zeros((h, w), np.intp)
    for y in range(h):
        d = 1 if (y % 2 == 0) else -1
        xr = range(w) if d == 1 else range(w - 1, -1, -1)
        for x in xr:
            old = work[y, x]
            k = int(np.argmin(np.sum(W * (old - pal) ** 2, axis=1)))
            qidx[y, x] = k
            err = old - pal[k]
            if 0 <= x + d < w:
                work[y, x + d] += err * 7 / 16
            if y + 1 < h:
                if 0 <= x - d < w:
                    work[y + 1, x - d] += err * 3 / 16
                work[y + 1, x] += err * 5 / 16
                if 0 <= x + d < w:
                    work[y + 1, x + d] += err * 1 / 16
    return qidx


def convert_c16(src, pal):
    """320x240 16-colours-PER-PIXEL (color16_mode).  Every pixel is a free
    palette index -- no per-cell limit -- so a full Floyd-Steinberg dither gives
    near-photo quality.  Packs two pixels per byte: byte = y*160 + x/2, even x in
    the low nibble, odd x in the high nibble.  Returns data(38400), preview."""
    qidx = global_dither(src, pal)            # (240,320)
    data = np.zeros(38400, np.uint8)
    preview = np.zeros((240, 320, 3), np.uint8)
    for y in range(240):
        row = y * 160
        for x in range(320):
            idx = qidx[y, x]
            bi = row + (x >> 1)
            if x & 1:
                data[bi] |= idx << 4
            else:
                data[bi] |= idx
            preview[y, x] = pal[idx].astype(np.uint8)
    return data, preview


def convert(src, pal, per_cell_bg=True):
    """src: (200,320,3) float.

    The hardware hires model gives one *foreground* colour per 8x8 cell (the
    $8400 low nibble) but a single *global* background ($D021) for every bit=0
    pixel.  Two colour models:

    - per_cell_bg=True ($9005 cell_bg_mode bitstream): each cell gets its OWN
      foreground AND background -- the optimal palette pair for that cell.  This
      is the real C64 hires model and looks much better.
    - per_cell_bg=False (older bitstream): one foreground per cell + a single
      global background ($D021) shared by every cell.

    In both cases a global serpentine Floyd-Steinberg pass diffuses the
    quantisation error across cell boundaries so gradients stay smooth.

    Returns bmp(8000), col(1000), d021(global background to program), preview.
    """
    fgmap = np.zeros((25, 40), np.intp)   # foreground index ($8400 low nibble)
    bgmap = np.zeros((25, 40), np.intp)   # background index ($8400 high nibble)
    if per_cell_bg:
        # Pick each cell's two colours from a COHERENT global dither: first
        # Floyd-Steinberg the whole image to the full 16-colour palette (so
        # neighbouring cells share colours and gradients), then take each cell's
        # two most-used palette entries.  This avoids the attribute-clash you get
        # from choosing every cell's optimal pair independently.
        qidx = global_dither(src, pal)
        for cy in range(25):
            for cx in range(40):
                block = qidx[cy * 8:cy * 8 + 8, cx * 8:cx * 8 + 8].ravel()
                counts = np.bincount(block, minlength=16)
                order = np.argsort(counts)[::-1]
                a = int(order[0])
                b = int(order[1]) if counts[order[1]] > 0 else a
                fgmap[cy, cx], bgmap[cy, cx] = a, b
        d021 = 0                          # per-cell bg; $D021 unused in image area
    else:
        # one global background: the colour minimising total nearest-pair error
        bg_score = np.zeros(16)
        Cmats = []
        for cy in range(25):
            for cx in range(40):
                px = src[cy * 8:cy * 8 + 8, cx * 8:cx * 8 + 8, :].reshape(64, 3)
                D = wdist2(px[:, None, :], pal[None, :, :])
                C = np.minimum(D[:, :, None], D[:, None, :]).sum(axis=0)
                Cmats.append(C)
                bg_score += C.min(axis=0)
        G = int(np.argmin(bg_score))
        for i, C in enumerate(Cmats):
            fgmap[i // 40, i % 40] = int(np.argmin(C[:, G]))
        bgmap[:] = G
        d021 = G

    col = ((bgmap << 4) | fgmap).astype(np.uint8).reshape(1000)

    # --- GLOBAL serpentine Floyd-Steinberg over the whole 320x200 -----------
    bmp = np.zeros(8000, np.uint8)
    preview = np.zeros((200, 320, 3), np.uint8)
    work = src.copy()
    for y in range(200):
        d = 1 if (y % 2 == 0) else -1
        xr = range(320) if d == 1 else range(319, -1, -1)
        for x in xr:
            cf = pal[fgmap[y // 8, x // 8]]
            cb = pal[bgmap[y // 8, x // 8]]
            old = work[y, x]
            df = np.sum(W * (old - cf) ** 2)
            db = np.sum(W * (old - cb) ** 2)
            if df <= db:
                chosen = cf
                bmp[y * 40 + (x >> 3)] |= 1 << (7 - (x & 7))   # bit=1 -> fg
            else:
                chosen = cb
            preview[y, x] = chosen.astype(np.uint8)
            err = old - chosen
            if 0 <= x + d < 320:
                work[y, x + d] += err * 7 / 16
            if y + 1 < 200:
                if 0 <= x - d < 320:
                    work[y + 1, x - d] += err * 3 / 16
                work[y + 1, x] += err * 5 / 16
                if 0 <= x + d < 320:
                    work[y + 1, x + d] += err * 1 / 16
    return bmp, col, d021, preview


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--out", default="sw/ich_image",
                    help="output base path (writes _bmp.bin/_col.bin/_preview.png)")
    ap.add_argument("--brightness", type=float, default=0.0)
    ap.add_argument("--contrast", type=float, default=1.08)
    ap.add_argument("--saturation", type=float, default=1.05)
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--global-bg", action="store_true",
                    help="one global $D021 background (older bitstream without "
                         "the $9005 cell_bg_mode feature); default is per-cell bg")
    ap.add_argument("--color16", action="store_true",
                    help="320x240 16-colours-PER-PIXEL (color16_mode); writes "
                         "<out>_c16.bin (38400 B) instead of the hires _bmp/_col")
    args = ap.parse_args()

    pal = build_palette()

    if args.color16:
        src = fit_canvas(Image.open(args.image), cw=320, ch=240)
        src = enhance(src, args.brightness, args.contrast, args.saturation, args.gamma)
        data, preview = convert_c16(src, pal)
        with open(args.out + "_c16.bin", "wb") as f:
            f.write(data.tobytes())
        Image.fromarray(preview).resize((640, 480), Image.NEAREST).save(args.out + "_preview.png")
        print(f"wrote {args.out}_c16.bin ({len(data)} B), {args.out}_preview.png")
        return

    src = fit_canvas(Image.open(args.image))
    src = enhance(src, args.brightness, args.contrast, args.saturation, args.gamma)
    bmp, col, bg, preview = convert(src, pal, per_cell_bg=not args.global_bg)

    with open(args.out + "_bmp.bin", "wb") as f:
        f.write(bmp.tobytes())
    with open(args.out + "_col.bin", "wb") as f:
        f.write(col.tobytes())
    with open(args.out + "_bg.inc", "w") as f:
        f.write(f"IMG_BGCOL = ${bg:02X}    ; $D021 value (per-cell mode: unused in image, $00)\n")
    Image.fromarray(preview).resize((640, 400), Image.NEAREST).save(args.out + "_preview.png")
    print(f"wrote {args.out}_bmp.bin ({len(bmp)} B), "
          f"{args.out}_col.bin ({len(col)} B), bg=${bg:02X}, {args.out}_preview.png")


if __name__ == "__main__":
    main()
