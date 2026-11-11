#!/bin/bash
# Seed the chroot runtime files that the package maintainer scripts expect to
# already exist in a previously used rootfs, then probe one chroot exec.
# Run on the iPad after ipad_unpack_rootfs.sh and `dpkg --unpack` of the package,
# with the ElleKit 1.1.3 package copied over from the Mac (the iPad has no curl):
#   curl -fLO https://ellekit.space/pool/ellekit_1.1.3_iphoneos-arm64.deb
#   sudo bash ipad_seed_chroot_runtime.sh ellekit_1.1.3_iphoneos-arm64.deb
set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:$PATH

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
ROOTFS=/var/mnt/rootfs
ELLEKIT_DEB=${1:?usage: sudo bash ipad_seed_chroot_runtime.sh <ellekit_1.1.3_iphoneos-arm64.deb>}
[ -f /var/jb/usr/macOS/lib/libmachook.dylib ] || {
    echo "unpack the package first: dpkg --unpack <com.kdt.macosbooter .deb>" >&2
    exit 1
}

# ElleKit 1.1.3 is the chroot CydiaSubstrate. ElleKit 1.2 gates its
# exception-handler hook on `#available(iOS 17.4, *)`, which is always true
# in a macOS-tagged image; a hook on a tiny shared-cache function with a far
# replacement then becomes a truncated B (ControlCenter crash-looped jumping to
# its replacement address mod 2^28). The iOS-side ElleKit is not touched.
ELLEKIT_SHA256=b6fa34a45629f1eba602678d3322ad06d077b52e015223f99a989883652b277b

trust() {
    local path=$1 arch hash
    for arch in arm64 arm64e; do
        hash=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8- || true)
        [ -n "$hash" ] || continue
        jbctl trustcache add "$hash"
        echo "trusted $arch $hash $path"
    done
}

# 1. Directories postinst.sh copies into without creating.
mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/lib" \
    "$ROOTFS/usr/local/Frameworks/MetalSerializer.framework"

# 2. libmachook: launchdchrootexec inserts /usr/local/lib/libmachook.dylib into
# every chroot process, but postinst runs its first chroot codesign before
# install_chroot_runtime copies it there. Fresh inodes (rm, then cp) avoid a
# stale cached code signature.
for lib in libmachook.dylib libmachook_arm64.dylib; do
    rm -f "$ROOTFS/usr/local/lib/$lib"
    cp "/var/jb/usr/macOS/lib/$lib" "$ROOTFS/usr/local/lib/$lib"
    trust "$ROOTFS/usr/local/lib/$lib"
done

# 3. CydiaSubstrate for macOS dyld: ElleKit 1.1.3, platform rewritten to
# macOS, re-signed twice (the recipe of ensure_settings_extensions_runtime.sh).
work=$(mktemp -d /tmp/macws-ellekit.XXXXXX)
echo "$ELLEKIT_SHA256  $ELLEKIT_DEB" | sha256sum -c -
dpkg-deb -x "$ELLEKIT_DEB" "$work/x"
fw="$ROOTFS/System/Library/Frameworks/CydiaSubstrate.framework"
mkdir -p "$fw"
rm -f "$fw/CydiaSubstrate"
cp "$work/x/var/jb/usr/lib/libellekit.dylib" "$fw/CydiaSubstrate"
rm -rf "$work"
python3 /var/jb/usr/macOS/bin/set_macos_version.py "$fw/CydiaSubstrate"
ldid -S -M "$fw/CydiaSubstrate"
ldid -S -M "$fw/CydiaSubstrate"
trust "$fw/CydiaSubstrate"

# 4. Loader closure the first exec needs (shared cache CDHashes are the ones
# the package postinst also registers for 22F66).
trust "$ROOTFS/usr/lib/dyld"
trust "$ROOTFS/usr/lib/libobjc-trampolines.dylib"
trust "$ROOTFS/bin/echo"
jbctl trustcache add b5da39409492ac85e5a8e8ab618fe77e2d7a2980
jbctl trustcache add bbb765988e2677b98d47a549d612fa0d4af25f69

# 5. Probe.
echo "--- probe: /bin/echo in the chroot"
if MACWS_UTILITY_PROCESS=1 /var/jb/usr/macOS/bin/launchdchrootexec 0 0 "$ROOTFS" /bin/echo chroot-ok; then
    echo "--- probe passed"
else
    echo "--- probe failed (exit $?); recent kernel messages:"
    dmesg 2>/dev/null | grep -i -E "amfi|codesign|dyld|cs_|launchdchroot|echo" | tail -25 || true
    exit 1
fi
