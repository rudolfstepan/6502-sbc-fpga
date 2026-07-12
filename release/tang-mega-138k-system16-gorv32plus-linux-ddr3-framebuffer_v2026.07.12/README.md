# Tang Mega 138K System16 GoRV32 Plus Linux DDR3 Framebuffer

Release: `v2026.07.12`

Dieses Paket enthaelt die drei Flash-Artefakte fuer das System16-GoRV32-Plus-
Linux-System auf dem Tang Mega 138K / Tang Console 138K. Der Linux-Kernel nutzt
den DDR3-Framebuffer fuer die HDMI-Konsole und gibt Kernelmeldungen zugleich
ueber HDMI und UART mit 115200 Baud aus.

## Dateien und Flash-Adressen

| Datei | Zweck | Flash-Adresse | SHA-256 |
| --- | --- | --- | --- |
| `tang-mega-138k-system16-gorv32plus-ddr3-framebuffer-bitstream.fs` | aktueller FPGA-Bitstream mit DDR3-Framebuffer | `0x000000` | `EA3B72D2C4FC53B504C24D5AF5D16BCEB35D1ECDEB3B360AD4F5F1F45E83C72E` |
| `tang-mega-138k-system16-gorv32plus-zsbl-v11.bin` | ZSBL v11, flash-first | `0x500000` | `76ED432000A541D3C5C79422616763113F12AFE5A625FFFDB29DBAE620244637` |
| `tang-mega-138k-system16-gorv32plus-linux-ddr3-framebuffer-image.bin` | OpenSBI, DTB, Linux und Buildroot-Initramfs | `0x510000` | `12C0267C354AEC348DE86E9E809E83E5B40A35E8A5DBEB498DB48EBCCC95EAE5` |

## Programmieren

Alle drei Dateien werden mit dem Gowin Programmer in den externen Flash
geschrieben. Fuer den Bitstream wird `exFlash Erase, Program, Verify 5A`
verwendet. Fuer ZSBL und Linux wird `exFlash C Bin Erase, Program, Verify 5A`
verwendet. Die oben angegebenen Startadressen muessen exakt eingehalten werden.

Programmier-Reihenfolge:

1. Bitstream nach `0x000000`
2. ZSBL nach `0x500000`
3. Linux-Image nach `0x510000`

Nach dem Einschalten startet ZSBL den GRV1-Linux-Container aus dem Flash. Sobald
`simplefb` und `fbcon` aktiv sind, erscheinen die Kernelmeldungen auf HDMI. UART
und HDMI bedienen anschliessend dieselbe Linux-Konsole auf `tty1`.
