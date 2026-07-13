#!/bin/sh
set -eu

target=$1
inittab="$target/etc/inittab"

# tty1 is rendered by the System16 text console and driven by the normal Linux
# virtual-console keyboard path (PS/2 and FPGA USB-HID input devices).
if ! grep -q '^tty1::respawn:' "$inittab"; then
    printf '%s\n' 'tty1::respawn:/sbin/getty -L tty1 0 linux' >> "$inittab"
fi

# Give the UART its own direct getty.  Kernel messages are already mirrored to
# tty0 and ttyS0 by the two console= arguments; conspy is neither needed nor
# desirable here because its polling makes both keyboard paths feel sluggish.
if grep -q '^console::respawn:' "$inittab"; then
    sed -i 's|^console::respawn:.*|console::respawn:/sbin/getty -L ttyS0 115200 vt100|' "$inittab"
else
    printf '%s\n' 'console::respawn:/sbin/getty -L ttyS0 115200 vt100' >> "$inittab"
fi
