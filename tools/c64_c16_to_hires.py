#!/usr/bin/env python3
"""Convert SBC COLOR16 payload to a native C64 hires bitmap.

This targets real C64 bitmap mode, not the SBC framebuffer:

  bitmap byte offset = char_row*320 + char_col*8 + row_in_cell
  screen RAM         = high nibble bit-1 colour, low nibble bit-0 colour

For every 8x8 cell it searches the best two-colour C64 palette pair by weighted
RGB error, then applies small ordered dithering within that fixed pair.  The
result keeps the full 320-pixel horizontal hires resolution and avoids the
large colour rectangles caused by picking colours from already-quantised cell
frequency alone.
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

PAL_R5 = [0o00, 0o37, 0o21, 0o15, 0o21, 0o13, 0o10, 0o30,
          0o21, 0o13, 0o27, 0o12, 0o17, 0o23, 0o17, 0o24]
PAL_G6 = [0, 0b111111, 0b001110, 0b101110, 0b010000, 0b101000, 0b001100, 0b110100,
          0b011001, 0b010010, 0b011010, 0b010100, 0b011110, 0b111000, 0b011010, 0b101000]
PAL_B5 = [0b00000, 0b11111, 0b00110, 0b11000, 0b10011, 0b01001, 0b10010, 0b01110,
          0b00110, 0b00000, 0b01100, 0b01010, 0b01111, 0b10001, 0b11001, 0b10100]

W = np.array([0.299, 0.587, 0.114], np.float64)
BAYER8 = np.array([
    [0, 48, 12, 60, 3, 51, 15, 63],
    [32, 16, 44, 28, 35, 19, 47, 31],
    [8, 56, 4, 52, 11, 59, 7, 55],
    [40, 24, 36, 20, 43, 27, 39, 23],
    [2, 50, 14, 62, 1, 49, 13, 61],
    [34, 18, 46, 30, 33, 17, 45, 29],
    [10, 58, 6, 54, 9, 57, 5, 53],
    [42, 26, 38, 22, 41, 25, 37, 21],
], np.float64) / 64.0 - 0.5


def build_palette():
    pal = np.zeros((16, 3), np.float64)
    for i in range(16):
        pal[i, 0] = round(PAL_R5[i] * 255 / 31)
        pal[i, 1] = round(PAL_G6[i] * 255 / 63)
        pal[i, 2] = round(PAL_B5[i] * 255 / 31)
    return pal


def unpack_c16(data):
    if len(data) != 38400:
        raise ValueError(f"COLOR16 input must be 38400 bytes, got {len(data)}")
    packed = np.frombuffer(data, dtype=np.uint8).reshape(240, 160)
    idx = np.zeros((240, 320), np.uint8)
    idx[:, 0::2] = packed & 0x0F
    idx[:, 1::2] = packed >> 4
    return idx


def resize_to_hires_rgb(idx, pal):
    rgb = pal[idx].astype(np.uint8)
    im = Image.fromarray(rgb, "RGB").resize((320, 200), Image.Resampling.LANCZOS)
    return np.asarray(im, np.float64)


def pair_error(block, pal, a, b):
    ca = pal[a]
    cb = pal[b]
    da = np.sum(W * (block - ca) ** 2, axis=2)
    db = np.sum(W * (block - cb) ** 2, axis=2)
    return float(np.minimum(da, db).sum())


def choose_pair(block, pal):
    best = (1e30, 1, 0)
    mean = block.reshape(-1, 3).mean(axis=0)
    for a in range(16):
        for b in range(16):
            if a == b:
                continue
            err = pair_error(block, pal, a, b)
            # The C64 yellow/brown/green entries often win small least-squares
            # fights in skin highlights, but produce harsh 8x8 blotches in a
            # portrait.  Penalise those hue jumps when the cell average is
            # flesh-like instead of green/yellow scenery.
            r, g, bl = mean
            skinish = r > 95 and g > 55 and bl > 45 and r >= g and g >= bl * 0.75
            if skinish:
                for c in (a, b):
                    if c in (7, 9, 13):
                        err *= 1.22
                    elif c in (5,):
                        err *= 1.35
            if err < best[0]:
                best = (err, a, b)
    return best[1], best[2]


def convert(rgb, dither=16.0):
    pal = build_palette()
    bmp = bytearray(8000)
    scr = bytearray(1000)
    preview = np.zeros((200, 320, 3), np.uint8)

    for cy in range(25):
        for cx in range(40):
            block = rgb[cy * 8:cy * 8 + 8, cx * 8:cx * 8 + 8, :]
            fg, bg = choose_pair(block, pal)
            scr[cy * 40 + cx] = ((fg & 0x0F) << 4) | (bg & 0x0F)
            cf = pal[fg]
            cb = pal[bg]

            for row in range(8):
                out = 0
                for bit in range(8):
                    src = block[row, bit]
                    # Compare true weighted RGB distance, with a small ordered
                    # threshold nudge.  This preserves detail without turning
                    # each cell into a flat colour ramp.
                    df = float(np.sum(W * (src - cf) ** 2))
                    db = float(np.sum(W * (src - cb) ** 2))
                    threshold = BAYER8[row, bit] * dither * dither
                    if df - db <= threshold:
                        out |= 1 << (7 - bit)
                        preview[cy * 8 + row, cx * 8 + bit] = cf
                    else:
                        preview[cy * 8 + row, cx * 8 + bit] = cb
                bmp[cy * 320 + cx * 8 + row] = out
    return bytes(bmp), bytes(scr), preview


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("--out", default="sw/ich_image_c64")
    ap.add_argument("--dither", type=float, default=12.0)
    args = ap.parse_args()

    pal = build_palette()
    rgb = resize_to_hires_rgb(unpack_c16(args.input.read_bytes()), pal)
    bmp, scr, preview = convert(rgb, dither=args.dither)

    out = Path(args.out)
    out.with_name(out.name + "_bmp.bin").write_bytes(bmp)
    out.with_name(out.name + "_scr.bin").write_bytes(scr)
    Image.fromarray(preview, "RGB").resize((640, 400), Image.Resampling.NEAREST).save(
        out.with_name(out.name + "_preview.png")
    )
    print(f"wrote {args.out}_bmp.bin, {args.out}_scr.bin")


if __name__ == "__main__":
    main()
