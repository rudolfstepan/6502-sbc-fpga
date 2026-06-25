#!/usr/bin/env python3
"""Generate the HDMI AVI-InfoFrame data-island TERC4 words for the Tang HDMI TX.

The AVI InfoFrame is static (one fixed video format), so the entire 32-pixel
data-island packet is encoded offline here and embedded as a VHDL ROM in
rtl/core/hdmi/hdmi_data_island_pkg.vhd. The fiddly maths (HDMI BCH/ECC,
TERC4 coding, packet bit-packing, InfoFrame checksum) thus lives in this
auditable script instead of in RTL.

References (all cross-checked against hdl-util/hdmi):
  * TERC4 table & guard-band constants: HDMI 1.4a spec, tmds_channel.sv
  * Data-island bit packing & ECC poly 0x83: packet_assembler.sv
  * AVI InfoFrame layout: CEA-861-D section 6.4

Channel/bit mapping per data-island pixel (hdl-util hdmi.sv):
  data_island_data[11:4] = packet_data[8:1]   -> channels 1 (low) & 2 (high)
  data_island_data[3]    = (pixel_index != 0)  -> ch0 bit3 "not first pixel"
  data_island_data[2]    = packet_data[0]       -> ch0 bit2 header bit
  data_island_data[1:0]  = {vsync, hsync}       -> ch0 bits 1,0 (wire levels)
  packet_data = {bch3[2c+1],bch2[2c+1],bch1[2c+1],bch0[2c+1],
                 bch3[2c],  bch2[2c],  bch1[2c],  bch0[2c],   bch4[c]}
"""

# --- TERC4 4-bit -> 10-bit table (HDMI 1.4a) -------------------------------
TERC4 = {
    0x0: "1010011100", 0x1: "1001100011", 0x2: "1011100100", 0x3: "1011100010",
    0x4: "0101110001", 0x5: "0100011110", 0x6: "0110001110", 0x7: "0100111100",
    0x8: "1011001100", 0x9: "0100111001", 0xA: "0110011100", 0xB: "1011000110",
    0xC: "1010001110", 0xD: "1001110001", 0xE: "0101100011", 0xF: "1011000011",
}

# Sync wire levels during the data island. The island is placed in horizontal
# blanking, away from the (negative-polarity) HSYNC pulse, so both lines sit at
# their idle level = logic 1 (matching the control-period coding used elsewhere).
VSYNC = 1
HSYNC = 1


def ecc_byte(bits):
    """HDMI data-island ECC: LFSR, poly 0x83, LSB-first. Returns 8 parity bits
    (LSB first) appended after the data bits."""
    ecc = 0
    for b in bits:
        feedback = (ecc & 1) ^ b
        ecc >>= 1
        if feedback:
            ecc ^= 0x83
    return [(ecc >> i) & 1 for i in range(8)]


def bytes_to_bits_lsb(byte_list):
    bits = []
    for byte in byte_list:
        for i in range(8):
            bits.append((byte >> i) & 1)
    return bits


def build_avi_infoframe():
    """Return (header_bytes[3], packet_bytes[28]) for the AVI InfoFrame.

    720x480p, RGB. Picture aspect 4:3 => CEA VIC 2 (the 640x480 content is
    pillarboxed 4:3). Active-format = 'same as picture aspect ratio'."""
    HB = [0x82, 0x02, 0x0D]            # type, version, length(13)
    PB = [0] * 28
    # PB1: Y(colorspace)=RGB(00), A0(active-format present)=1, B=00, S=00
    PB[1] = 0x10
    # PB2: C(colorimetry)=00, M(picture aspect)=01 (4:3), R(active fmt)=1000
    PB[2] = 0x18
    PB[3] = 0x00                        # ITC/EC/Q/SC = 0
    PB[4] = 0x02                        # VIC = 2 (720x480p 4:3)
    PB[5] = 0x00                        # pixel repetition = 0
    # PB6..PB13 bar info = 0; PB14..PB27 unused = 0
    # PB0 = checksum so that (sum(HB)+sum(PB)) mod 256 == 0
    s = (sum(HB) + sum(PB)) & 0xFF
    PB[0] = (256 - s) & 0xFF
    return HB, PB


def main():
    HB, PB = build_avi_infoframe()
    print("AVI InfoFrame header :", " ".join(f"{b:02X}" for b in HB))
    print("AVI InfoFrame PB0..13:", " ".join(f"{b:02X}" for b in PB[:14]))
    chk = (sum(HB) + sum(PB)) & 0xFF
    print(f"checksum verify (must be 0): {chk}  (PB0=0x{PB[0]:02X})")

    # bch4: 24 header data bits + 8 ECC
    hdr_bits = bytes_to_bits_lsb(HB)
    bch4 = hdr_bits + ecc_byte(hdr_bits)             # 32 bits
    # bch0..3: each 7 packet bytes (56 data bits) + 8 ECC
    bch = []
    for k in range(4):
        sp = PB[k * 7:(k + 1) * 7]
        data_bits = bytes_to_bits_lsb(sp)
        bch.append(data_bits + ecc_byte(data_bits))  # 64 bits each

    ch0, ch1, ch2 = [], [], []
    for c in range(32):
        t2, t2p1 = 2 * c, 2 * c + 1
        hdr_bit = bch4[c]
        # channel 0 nibble: {not-first, header bit, vsync, hsync}
        n0 = ((1 if c != 0 else 0) << 3) | (hdr_bit << 2) | (VSYNC << 1) | HSYNC
        # channel 1 nibble: even bit of subpackets 3..0
        n1 = (bch[3][t2] << 3) | (bch[2][t2] << 2) | (bch[1][t2] << 1) | bch[0][t2]
        # channel 2 nibble: odd bit of subpackets 3..0
        n2 = (bch[3][t2p1] << 3) | (bch[2][t2p1] << 2) | (bch[1][t2p1] << 1) | bch[0][t2p1]
        ch0.append(TERC4[n0])
        ch1.append(TERC4[n1])
        ch2.append(TERC4[n2])

    emit_vhdl(ch0, ch1, ch2, HB, PB)


def vhdl_array(name, words):
    lines = [f"  constant {name} : island_rom_t := ("]
    for i in range(0, 32, 4):
        chunk = ", ".join(f'"{w}"' for w in words[i:i + 4])
        comma = "," if i + 4 < 32 else ""
        lines.append(f"    {chunk}{comma}   -- {i:2d}..{i+3}")
    lines.append("  );")
    return "\n".join(lines)


def emit_vhdl(ch0, ch1, ch2, HB, PB):
    path = "rtl/core/hdmi/hdmi_data_island_pkg.vhd"
    avi_hdr = " ".join(f"{b:02X}" for b in HB)
    avi_pb = " ".join(f"{b:02X}" for b in PB[:14])
    body = f"""-- AUTO-GENERATED by tools/gen_avi_infoframe.py -- DO NOT EDIT BY HAND.
-- HDMI AVI-InfoFrame data island (TERC4-encoded), 32 pixels x 3 channels.
-- Static packet for 720x480p (VIC 2, RGB, 4:3). Regenerate via the script.
--   AVI header : {avi_hdr}
--   AVI PB0..13: {avi_pb}
library ieee;
use ieee.std_logic_1164.all;

package hdmi_data_island_pkg is
  type island_rom_t is array (0 to 31) of std_logic_vector(9 downto 0);
  -- Channel 0 (blue): header bit + sync, Channel 1 (green) / 2 (red): subpackets
{vhdl_array("DI_CH0", ch0)}
{vhdl_array("DI_CH1", ch1)}
{vhdl_array("DI_CH2", ch2)}
end package;
"""
    with open(path, "w", newline="\n") as f:
        f.write(body)
    print(f"\nwrote {path}")


if __name__ == "__main__":
    main()
