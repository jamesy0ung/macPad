#!/bin/bash
# Give a fresh rootfs the project's chroot signature (entitlements.plist:
# no-sandbox, platform-application, ...) so the iOS sandbox admits direct
# launchdchrootexec targets. Later in-chroot execs are signed on demand by
# autosignd. Run on the iPad:
#   sudo bash ipad_sign_core.sh
set -uo pipefail
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:$PATH

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
ROOTFS=/var/mnt/rootfs
ENT=/var/jb/usr/macOS/bin/entitlements.plist

sign_and_trust() {
    local path=$1 arch hash
    ldid -S"$ENT" -M "$path" || return 1
    for arch in arm64 arm64e; do
        hash=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8- || true)
        [ -n "$hash" ] && jbctl trustcache add "$hash"
    done
    echo "signed $path"
}

# 1. One binary, then probe.
sign_and_trust "$ROOTFS/bin/echo" || exit 1
echo "--- probe: /bin/echo in the chroot"
if ! MACWS_UTILITY_PROCESS=1 /var/jb/usr/macOS/bin/launchdchrootexec 0 0 "$ROOTFS" /bin/echo chroot-ok; then
    echo "--- probe failed; recent kernel messages:"
    dmesg 2>/dev/null | grep -i -E "amfi|sandbox|System Policy|dyld|cs_|launchdchroot" | tail -25
    exit 1
fi
echo "--- probe passed"

# 2. Core command directories through the project's bulk signer.
for dir in bin usr/bin usr/sbin usr/libexec; do
    bash /var/jb/usr/macOS/bin/sign_installed.sh "$ROOTFS/$dir" | tail -3
done
echo "--- done"
