# iPad14,5 / iPadOS 16.3.1 fresh-rootfs bring-up — 2026-11-11

Device: iPad14,5 (M2), iPadOS 16.3.1 (20D67), Dopamine 3.0.13, ElleKit 1.2,
fresh Ventura 13.4 (22F66) rootfs. The validated matrix covers iPad13,6 on
20D67 and iPad14,5 on 20A8372, each with a long-used rootfs. The compiler
service is the already allowlisted 20D67 executable (UUID
`6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E`); the AGX device-info probe negotiated
`legacy-0x70`. Reproduction steps are in `misc/fresh-rootfs-bringup/`.

## Terminal: `[Process completed]`

Decompiled stock Terminal `-[TTShell initShellArgs:userInfo:forCustomWorkingDirectory:]`:
when `getpwuid` returns a record and `/usr/bin/login` exists, Terminal runs
`login -pf <user> …`, even with a custom Shell preference. Only a failed
lookup makes it exec the shell directly (the path the existing
`exec_hooks.c` adapter expects).

`login` then failed in three independent ways, each runtime-confirmed:

1. AMFI rejected the PAM modules:
   `AMFI: '/usr/lib/pam/pam_nologin.so.2': unsuitable CT policy 0x8`.
   Fix: sign/trust `/usr/lib/pam`; `macos_gui.sh` now restores it at boot.
2. Decompiled Ventura `login`: a same-uid `-f` login selects PAM service
   `login.term`, whose `account required pam_opendirectory.so` fails without
   Open Directory → `Login incorrect`. Fix: `pam_permit` for that account
   line in `login.term` (`ipad_login_pam.sh`).
3. The forked child died in every report with
   `SIGBUS KERN_PROTECTION_FAILURE libxpc _xpc_look_up_endpoint ← xpc_pipe_create ← _od_xpc_pipe ← initgroups`.
   `login` is a headless broker like the shells already in
   `InitMetalHooks`' skip list; adding it removed the crash.

## Compiler service abort loop

With `/tmp/macws_mtlcompiler_diagnostics`, every new `MTLCompilerService`
received one discriminator-`0xf` request and died in
`readModuleFromBinaryRequest`. Its bitcode is MPSImage `F11H`
(`MPSGaussianBlur`) with identification `LLVM16.0.0` and LLVM16-only
`memory(...)` attributes: the deep `postinst.sh` had rewritten MPSImage with
upstream llvm-16 after `ensure_metal2metal_compat.sh` produced it with the
installed Apple LLVM. Regenerating with `macws-llvm-dis/as` produced the
already pinned `84973060c516…` and the loop stopped. `postinst.sh` now uses
the Apple LLVM for that route.

## ControlCenter / SystemUIServer crash loops: ElleKit 1.2

ControlCenter faulted reading `0x16664a00f0` in CoreGraphics
`crossing_count+1048`, reached directly from ControlCenter's call to
`CGSSessionCopyCurrentSessionProperties` (two instructions:
`mov w0,#1; b …`), which libmachook hooks. The landing PC `0x1A15C488C`
equals `macws_cgsession_private_compat` (`0x1015C488C`) mod 2^28: the hook
was written as a plain `B` with a truncated displacement.

ElleKit 1.2 `Hook.swift` only takes the exception-handler path for a tiny,
far target when `#available(iOS 17.4, *)` is false. The chroot copy is the
iOS dylib re-tagged as macOS, where that check is always true, so it falls
through to `b(branchOffset / 4)`. ElleKit 1.1.3 has no such gate. With 1.1.3
as the rootfs `CydiaSubstrate`, no ControlCenter or SystemUIServer crash
occurred afterwards. Each Settings pane also carried its own copy of the iOS
ElleKit; `ensure_settings_extensions_runtime.sh` now copies the chroot
`CydiaSubstrate` instead, byte-identical (no per-pane re-sign).

## Finder double-click on an application

hostd: `open-documents reject … requested=/System/Applications/Utilities/System Information.app`.
Finder's QLSeamlessOpener fallback resolves an `.app` item to itself and sends
it as a document; hostd accepts only regular files. The bridge now sends such
a request as `launch-path`.

## System Information: `_linkedBinding != this`

The assertion string is in LaunchServices (`LinkBinding.mm:150`,
`LinkBinding::resolveBinding`). A standalone `NSWorkspace iconForFile:` tool
aborted identically for `/System/Volumes/Data` and succeeded for
`/Applications`. That path was the `../..` symlink from the original setup
notes. Replacing it with a plain directory made `/System/Volumes/Data`, `/`
and System Information work.

## Settings panes blank

oslog (`oslog` package) showed RunningBoard launching each pane, the
MacWSCatalystLaunch overlay rewrite and carrier working, and then:

```text
Sandbox: hook..execve() killing com.apple.Screen-Time-Settings.extension[pid=56553, uid=501]: (err=2) failed to set container
```

A copy of the pane outside its `.appex` was not killed, and a `.bundle`
mirror reached `An XPC Service cannot be run directly`. The pane's container
exists at `/private/var/mobile/Containers/Data/PluginKitPlugin/…`, which does
not exist inside the chroot. A read-only bind of the host containers into the
rootfs changed the kill to `failed to set executable path`; a
`rootfs/private/var/mnt/rootfs -> /` link removed that too, and the panes
stayed running. `ensure_settings_container_bind.sh` performs both at GUI
start.

The panes then ran under the iOS extension sandbox, which denied
`com.apple.macosbooter.DiskArbitration.diskarbitrationd`,
`com.apple.macosbooter.CoreServices.coreservicesd`, `com.apple.window_proxies`,
`com.apple.dock.server`, `com.apple.dock.fullscreen` and related names. Adding
exactly those names to `settings-extension-entitlements.plist` made the panes
render and respond (Appearance confirmed). Remaining denials:
`iokit-get-properties` for `IOService` / `AppleDiagnosticDataAccessReadOnly`,
`com.apple.audio.audiohald` (Accessibility), `com.apple.corefollowup.agent`.

## System Information: empty sidebar

After the LinkBinding fix the window opened ("iPad Pro" title) with no
categories. oslog showed every reporter failing to load:

```text
+[SPReporter reporterBundles] -- Error loading /System/Library/SystemProfiler/SPUSBReporter.spreporter:
dlopen_preflight(...) => false ... fat file, but missing compatible architecture (have 'x86_64,arm64e', need '')
```

dyld-1066 `ProcessConfig::Process::getMainArchs` sets `osBinariesOnly` on
macOS, so an arm64e process grades only platform-binary arm64e slices; the
empty `need ''` is that list printed for a non-platform file. The reporters
keep their Apple signatures but were not in the dynamic trustcache.
Registering their existing CDHashes (no re-sign) made a standalone
`dlopen_preflight`/`dlopen` of `SPUSBReporter` succeed. `macos_gui.sh` now
restores `System/Library/SystemProfiler` with the cold-boot trust closure.

## Open

- `open .` returns `-600 procNotFound` (Finder is not an LS-launched process);
  `open -a` and About This Mac are not yet traced.
- AGX `GPURestart` events were seen while the crash loops ran; not re-measured
  after the fixes.
- `mount_bindfs` mounts read-only; the container bind is therefore read-only.
