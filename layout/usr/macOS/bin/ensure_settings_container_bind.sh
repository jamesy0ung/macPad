# No shebang: invoke with bash. This jailbreak's AMFI rejects execve of
# shebang scripts.
# Settings panes are app extensions, so iPadOS applies their PluginKit
# container at exec time. The pane image runs chrooted in /var/mnt/rootfs,
# where the sandbox then resolves two host paths:
#
#   - the container, /private/var/mobile/Containers/Data/PluginKitPlugin/...
#   - the executable, /private/var/mnt/rootfs/System/Library/ExtensionKit/...
#
# Runtime-confirmed on iPad14,5 / iPadOS 16.3.1 with Dopamine 3.0.13
# (2026-11-11): with neither path present inside the rootfs, every pane was
# killed at exec with `Sandbox: hook..execve() killing <pane> (err=2) failed to
# set container`, and then `failed to set executable path`. Exposing both made
# the same panes start and stay running. Neither step creates or alters a
# container; the host containermanager remains the only owner.
set -eu

rootfs=/var/mnt/rootfs
source_dir=/private/var/mobile/Containers
target_dir=$rootfs/private/var/mobile/Containers
self_link=$rootfs/private/var/mnt/rootfs
mount_tool=/var/jb/usr/local/bin/mount_bindfs
system_mount=/sbin/mount

[ -d "$rootfs/System/Library" ] || {
    echo "MacWS: rootfs is not mounted; Settings container bind deferred" >&2
    exit 0
}

# The kernel-visible rootfs path resolves to the chroot root itself.
mkdir -p "$rootfs/private/var/mnt"
if [ -L "$self_link" ]; then
    [ "$(readlink "$self_link")" = "/" ] || {
        echo "MacWS: unexpected rootfs self link: $self_link" >&2
        exit 1
    }
elif [ -e "$self_link" ]; then
    echo "MacWS: refusing to replace existing $self_link" >&2
    exit 1
else
    ln -s / "$self_link"
fi

[ -d "$target_dir" ] || mkdir -p "$target_dir"
canonical_target=$(realpath "$target_dir")
if "$system_mount" | grep -Fq " on $canonical_target ("; then
    exit 0
fi
chown 501:501 "$rootfs/private/var/mobile" "$target_dir"
if [ -n "$(ls -A "$target_dir")" ]; then
    echo "MacWS: refusing to cover nonempty $target_dir with a bind mount" >&2
    exit 1
fi
[ -x "$mount_tool" ] || {
    echo "MacWS: mount_bindfs is unavailable" >&2
    exit 1
}
"$mount_tool" "$source_dir" "$target_dir" || exit 1
[ -d "$target_dir/Data" ] || {
    echo "MacWS: iOS containers are not visible after mounting $target_dir" >&2
    exit 1
}
