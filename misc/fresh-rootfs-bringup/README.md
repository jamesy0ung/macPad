# Fresh rootfs bring-up (iPad14,5 / iPadOS 16.3.1 / Dopamine 3)

These scripts reproduce a working desktop from a **fresh** Ventura 13.4
(22F66) rootfs on a device outside the validated matrix: iPad Pro 12.9" 6th
gen (iPad14,5, M2) on iPadOS 16.3.1 (20D67) with Dopamine 3.0.13 and
ElleKit 1.2. The package assumes several things a long-used rootfs already
has; each script fills one of those gaps. The evidence for every step is in
[`docs/evidence/ipad14-5-ios1631-fresh-rootfs-20261111.md`](../../docs/evidence/ipad14-5-ios1631-fresh-rootfs-20261111.md).

All `ipad_*` scripts run on the iPad as root (`sudo bash <script>`). No
Apple binaries or rootfs payloads belong in git.

## 1. Mac: rootfs archives

Download `UniversalMac_13.4_22F66_Restore.ipsw`, extract the system volume
(`096-09648-074.dmg`, BuildManifest "OS") and the OS cryptex
(`096-09706-077.dmg`, "Cryptex1,SystemOS"), then:

```bash
sudo bash mac_pack_rootfs.sh <dir with both dmgs>
```

Copy `ventura-sys.tar.zst`, `ventura-cryptex.tar.zst` and `ventura.sha256` to
the iPad.

## 2. Mac: build the package

`TARGET := iphone:clang:latest` selects Xcode's newest iPhoneOS SDK, which
breaks `MTLCompilerBypassOSCheck`. Use the Command Line Tools SDKs, and make
the macOS SDK visible to Theos once:

```bash
ln -s /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
      ~/theos/sdks/MacOSX$(xcrun --sdk macosx --show-sdk-version).sdk
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 \
      THEOS_PLATFORM_SDK_ROOT=/Library/Developer/CommandLineTools -j8 package
```

Also fetch, on the Mac:

- ElleKit 1.1.3 for the chroot:
  `curl -fLO https://ellekit.space/pool/ellekit_1.1.3_iphoneos-arm64.deb`
  (SHA-256 `b6fa34a4…277b`, checked by the seed script).
- `OSXvnc-server` from Vine Server **5.3.2** (`stweil/OSXvnc` release
  `V5.3.2`, `VineServer-5.3.2.dmg`, `Vine Server.app/Contents/MacOS/OSXvnc-server`,
  SHA-256 `7676d575970c0b4af523646490a759df9762f0435282e99f834912267a697daa`).
  libmachook hooks this exact build at fixed offsets.
- `mount_bindfs` built from `khanhduytran0/mount-bindfs-dopamine`.

## 3. iPad: rootfs

```bash
sudo apt install zstd
sudo bash ipad_unpack_rootfs.sh <dir with the archives>
```

This keeps `System/Volumes/Data` a plain directory (the older `../..` symlink
makes LaunchServices assert and kills System Information) and makes
`var/folders/zz` a real directory (the Metal cache migration refuses symlinked
ancestors).

## 4. iPad: install

```bash
sudo cp mount_bindfs /var/jb/usr/local/bin/ && sudo chmod 755 /var/jb/usr/local/bin/mount_bindfs
sudo dpkg --unpack com.kdt.macosbooter_*_iphoneos-arm64.deb
sudo bash ipad_seed_chroot_runtime.sh ellekit_1.1.3_iphoneos-arm64.deb
sudo bash ipad_sign_core.sh
sudo python3 ipad_presign_executables.py
sudo dpkg --configure -a
sudo bash /var/jb/usr/macOS/bin/postinst.sh
sudo cp OSXvnc-server /var/mnt/rootfs/usr/local/bin/OSXvnc-server
sudo bash ipad_login_pam.sh
```

- `ipad_seed_chroot_runtime.sh`: libmachook and the ElleKit 1.1.3
  CydiaSubstrate inside the rootfs before the first chroot exec.
- `ipad_sign_core.sh` / `ipad_presign_executables.py`: stock executables need
  the project signature, or the iOS sandbox kills them when they are launched
  directly from iOS (autosignd only signs in-chroot execs).
- `ipad_login_pam.sh`: Terminal's `login -pf root` (PAM module trust and
  `login.term`).

Respring once so SpringBoard loads the windowing tweak, then:

```bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist
```

## Do not

- Exec a Settings pane directly in the chroot for testing. autosignd re-signs
  it, its runtime marker then disagrees and the package postinst fails with
  `Settings dependency signature changed`. Remove that pane's
  `Contents/Frameworks/.macws-settings-runtime` and rerun
  `ensure_settings_extensions_runtime.sh` to repair it.
