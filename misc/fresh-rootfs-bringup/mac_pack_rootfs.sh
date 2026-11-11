#!/bin/bash
# Pack the Ventura 13.4 (22F66) system volume and OS cryptex into archives
# for /var/mnt/rootfs on the iPad. Run on the Mac with sudo:
#   sudo bash mac_pack_rootfs.sh ~/v134
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
WORK=${1:?usage: sudo bash mac_pack_rootfs.sh <dir containing the dmgs>}
cd "$WORK"

SYS_DMG=096-09648-074.dmg      # BuildManifest "OS"
CRYPTEX_DMG=096-09706-077.dmg  # BuildManifest "Cryptex1,SystemOS"
SYS_MNT=/private/tmp/v134-sys
CRYPTEX_MNT=/private/tmp/v134-cryptex
OWNER=$(stat -f %u:%g "$WORK")

cleanup() {
    hdiutil detach "$SYS_MNT" -quiet 2>/dev/null || true
    hdiutil detach "$CRYPTEX_MNT" -quiet 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$SYS_MNT" "$CRYPTEX_MNT"
# -owners on: without it macOS reports every file as the invoking user and
# the archive would carry uid 501 instead of the real root/system owners.
hdiutil attach -readonly -noverify -nobrowse -owners on -mountpoint "$SYS_MNT" "$SYS_DMG" >/dev/null
hdiutil attach -readonly -noverify -nobrowse -owners on -mountpoint "$CRYPTEX_MNT" "$CRYPTEX_DMG" >/dev/null

grep -q '<string>22F66</string>' "$SYS_MNT/System/Library/CoreServices/SystemVersion.plist" \
    || { echo "system volume is not 22F66" >&2; exit 1; }
[ -f "$CRYPTEX_MNT/System/Library/dyld/dyld_shared_cache_arm64e" ] \
    || { echo "cryptex has no arm64e shared cache" >&2; exit 1; }
[ "$(stat -f %u "$SYS_MNT/usr/bin/sudo")" -eq 0 ] \
    || { echo "owners are not enabled on the mount" >&2; exit 1; }

# --numeric-owner: iOS lacks most macOS account names (_www, _windowserver...).
# --no-mac-metadata: no AppleDouble ._ files in the archive.
pack() {
    echo "packing $1 -> $2"
    tar -C "$1" --numeric-owner --no-mac-metadata -cpf - . | zstd -T0 -q -f -o "$2"
}
pack "$SYS_MNT" ventura-sys.tar.zst
pack "$CRYPTEX_MNT" ventura-cryptex.tar.zst

shasum -a 256 ventura-sys.tar.zst ventura-cryptex.tar.zst | tee ventura.sha256
chown "$OWNER" ventura-sys.tar.zst ventura-cryptex.tar.zst ventura.sha256
echo "done"
