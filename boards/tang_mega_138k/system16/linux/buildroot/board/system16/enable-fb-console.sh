#!/bin/sh
set -eu

target=$1
inittab="$target/etc/inittab"

# There is exactly one login session: tty1, rendered by fbcon and driven by a
# normal virtual-console keyboard (including the FPGA USB-HID input device).
if ! grep -q '^tty1::respawn:' "$inittab"; then
    printf '%s\n' 'tty1::respawn:/sbin/getty -L tty1 0 linux' >> "$inittab"
fi

# /dev/console is ttyS0 because it is the last console on the kernel command
# line.  Do not start a second getty there.  cttyhack gives conspy the
# controlling terminal it needs; conspy then mirrors virtual console 1 to the
# UART and forwards UART keystrokes back to that same login and shell.
if grep -q '^console::respawn:' "$inittab"; then
    sed -i 's|^console::respawn:.*|console::respawn:/bin/cttyhack /bin/conspy -c -f 1|' "$inittab"
else
    printf '%s\n' 'console::respawn:/bin/cttyhack /bin/conspy -c -f 1' >> "$inittab"
fi
