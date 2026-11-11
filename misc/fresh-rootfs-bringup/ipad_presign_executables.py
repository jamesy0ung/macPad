#!/var/jb/usr/bin/python3
"""Pre-apply autosignd's executable signature to a fresh macOS rootfs.

autosignd re-signs a main executable (`ldid -S<entitlements.plist> -M`) when it
is exec'd from inside the chroot, but macos_gui.sh starts several stock
daemons and tools directly from iOS through launchdchrootexec, which bypasses
it. A long-used rootfs already carries those signatures; a fresh one does not,
and the iOS sandbox kills the stock-signed binary at exec.

Only Mach-O images with an arm64/arm64e MH_EXECUTE slice are touched. Images
whose entitlements already include no-sandbox (project-signed: WindowServer,
launchservicesd loader, systemstatusd, ...) are skipped. Libraries keep their
signatures, as in autosignd.

Run on the iPad:  sudo python3 ipad_presign_executables.py
"""
import os
import struct
import subprocess
import sys

ROOTFS = "/var/mnt/rootfs"
TREES = ["System", "usr", "bin", "sbin", "Library", "Applications", "opt"]
ENT = "/var/jb/usr/macOS/bin/entitlements.plist"
LDID = "/var/jb/usr/bin/ldid"
JBCTL = "/var/jb/usr/bin/jbctl"
MARKER = b"com.apple.private.security.no-sandbox"

CPU_ARM64 = 0x0100000C
MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 2
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def arm_executable(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
            magic = struct.unpack(">I", head[:4])[0] if len(head) >= 4 else 0
            if magic in (FAT_MAGIC, FAT_MAGIC_64):
                count = struct.unpack(">I", head[4:8])[0]
                size = 32 if magic == FAT_MAGIC_64 else 20
                for i in range(min(count, 16)):
                    rec = head[8 + i * size: 8 + (i + 1) * size]
                    if len(rec) < size:
                        return False
                    cpu = struct.unpack(">I", rec[:4])[0]
                    if magic == FAT_MAGIC_64:
                        offset = struct.unpack(">Q", rec[8:16])[0]
                    else:
                        offset = struct.unpack(">I", rec[8:12])[0]
                    if cpu != CPU_ARM64:
                        continue
                    f.seek(offset)
                    slice_head = f.read(16)
                    if len(slice_head) == 16:
                        m, c, _, ftype = struct.unpack("<IIII", slice_head)
                        if m == MH_MAGIC_64 and ftype == MH_EXECUTE:
                            return True
                return False
            if len(head) >= 16:
                m, c, _, ftype = struct.unpack("<IIII", head[:16])
                return m == MH_MAGIC_64 and c == CPU_ARM64 and ftype == MH_EXECUTE
    except OSError:
        pass
    return False


def run(argv):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def main():
    if os.geteuid() != 0:
        sys.exit("run with sudo")
    candidates = []
    for tree in TREES:
        base = os.path.join(ROOTFS, tree)
        for root, dirs, files in os.walk(base):
            # Do not descend into bind mounts or iOS-side trees.
            if root.startswith(os.path.join(ROOTFS, "var")) or root.startswith(os.path.join(ROOTFS, "private")):
                dirs[:] = []
                continue
            for name in files:
                path = os.path.join(root, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                if arm_executable(path):
                    candidates.append(path)
    print(f"arm64/arm64e executables found: {len(candidates)}", flush=True)

    signed = skipped = failed = 0
    for index, path in enumerate(candidates, 1):
        ents = run([LDID, "-e", path]).stdout
        if MARKER in ents:
            skipped += 1
            continue
        if run([LDID, "-S" + ENT, "-M", path]).returncode != 0:
            failed += 1
            print(f"  FAILED {path}", flush=True)
            continue
        for arch in ("arm64", "arm64e"):
            out = run([LDID, "-arch", arch, "-h", path]).stdout.decode(errors="replace")
            for line in out.splitlines():
                if line.startswith("CDHash="):
                    run([JBCTL, "trustcache", "add", line[7:].strip()])
        signed += 1
        if index % 100 == 0:
            print(f"  {index}/{len(candidates)} signed={signed} skipped={skipped} failed={failed}", flush=True)
    print(f"done: signed={signed} already-project-signed={skipped} failed={failed}")


if __name__ == "__main__":
    main()
