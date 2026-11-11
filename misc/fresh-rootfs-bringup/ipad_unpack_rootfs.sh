#!/bin/bash
# Unpack the Ventura 13.4 archives into /var/mnt/rootfs and create the
# Data/cryptex layout from the original MacWSBootingGuide setup notes.
# Run on the iPad:
#   sudo bash ipad_unpack_rootfs.sh /var/mobile/v134
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
SRC=${1:?usage: sudo bash ipad_unpack_rootfs.sh <dir containing the archives>}
ROOTFS=/var/mnt/rootfs
CRYPTEX_DIR="$ROOTFS/System/Volumes/Preboot/Cryptexes/OS"

command -v zstd >/dev/null || { echo "install zstd first: sudo apt install zstd" >&2; exit 1; }

cd "$SRC"
sha256sum -c ventura.sha256

if [ -e "$ROOTFS" ] && [ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ]; then
    echo "$ROOTFS is not empty; refusing to unpack over it" >&2
    exit 1
fi

mkdir -p "$ROOTFS"
echo "unpacking system volume"
zstd -dc ventura-sys.tar.zst | tar --numeric-owner -xpf - -C "$ROOTFS"
mkdir -p "$CRYPTEX_DIR"
echo "unpacking OS cryptex"
zstd -dc ventura-cryptex.tar.zst | tar --numeric-owner -xpf - -C "$CRYPTEX_DIR"

cd "$ROOTFS"
# Merge the Data volume template without overwriting system files.
cp -an System/Library/Templates/Data/. .
# Keep System/Volumes/Data a plain directory. The older setup notes made it a
# `../..` symlink; LaunchServices then resolves that link back to itself and
# aborts with `_linkedBinding != this` (LinkBinding.mm:150) whenever an icon
# is requested for it, which kills System Information at launch.
mkdir -p System/Volumes/Data
# A real directory: macws_metal_cache_migration.py refuses symlinked ancestors.
mkdir -p private/var/folders/zz
chown root:wheel private/var/folders/zz
chmod 755 private/var/folders/zz
mkdir -p Users/root

echo
grep -A1 ProductBuildVersion System/Library/CoreServices/SystemVersion.plist
ls -l "$CRYPTEX_DIR/System/Library/dyld/"
ls -ld System/Volumes/Data var/folders/zz Users/root usr/bin/sudo
