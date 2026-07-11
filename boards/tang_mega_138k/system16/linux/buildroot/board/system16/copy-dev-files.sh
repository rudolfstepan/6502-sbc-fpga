#!/bin/sh
set -eu
target=$1

# Buildroot normally strips development files from the target. A native
# compiler needs the libc headers, startup objects, linker scripts and libs.
mkdir -p "$target/usr/include" "$target/usr/lib" "$target/lib"
cp -a "$STAGING_DIR/usr/include/." "$target/usr/include/"
cp -a "$STAGING_DIR/usr/lib/." "$target/usr/lib/"
cp -a "$STAGING_DIR/lib/." "$target/lib/"

# GCC's cc1 cannot work reliably in the board's 12 MiB Linux RAM. Put a
# real (non-sparse) swap file into the ext2 image and enable it during init.
dd if=/dev/zero of="$target/swapfile" bs=1M count=64 status=none
mkswap "$target/swapfile" >/dev/null
mkdir -p "$target/etc/init.d"
cat > "$target/etc/init.d/S01swap" <<'EOF'
#!/bin/sh
swapon /swapfile || echo "warning: could not enable /swapfile"
EOF
chmod +x "$target/etc/init.d/S01swap"
