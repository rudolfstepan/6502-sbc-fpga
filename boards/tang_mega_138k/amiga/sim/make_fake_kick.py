"""Generate fake_kick13.hex for tb_boot_copy: 131072 16-bit words with the
signature words, the patchable word at 0xAA and address-derived filler so a
misplaced word identifies where it came from."""

words = []
for i in range(131072):
    if i == 0x00000:
        v = 0x1111
    elif i == 0x00001:
        v = 0x4EF9
    elif i == 0x00002:
        v = 0x00FC
    elif i == 0x00003:
        v = 0x00D2
    elif i == 0x000AA:
        v = 0x6678          # patched to 0x6078 during the copy
    elif i == 0x1FFFF:
        v = 0x001F
    else:
        v = (i ^ (i << 7) ^ 0xA53C) & 0xFFFF
    words.append(v)

with open("fake_kick13.hex", "w", newline="\n") as f:
    for v in words:
        f.write(f"{v:04x}\n")

print(f"fake_kick13.hex written, {len(words)} words")
