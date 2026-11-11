#!/bin/bash
# Make Terminal's `login -pf root` work in a fresh rootfs. Run on the iPad:
#   sudo bash ipad_login_pam.sh
#
# Terminal starts the shell through /usr/bin/login whenever getpwuid resolves
# the user (stock TTShell behavior). In this chroot that path failed three ways:
#   1. login dlopens /usr/lib/pam/*.so.2, which AMFI rejected
#      ("unsuitable CT policy") until they were signed and trusted.
#   2. `login -f` by the same uid uses /etc/pam.d/login.term, whose
#      `account required pam_opendirectory.so` needs Open Directory, which
#      does not run here -> "Login incorrect".
#   3. login's forked child crashed in libxpc (fixed in libmachook: login is
#      now in Metal_hooks.x's headless skip list).
# The PAM trust is reboot-volatile; macos_gui.sh restores it at each start.
set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:$PATH
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
ROOTFS=/var/mnt/rootfs
TERM_PAM=$ROOTFS/etc/pam.d/login.term

bash /var/jb/usr/macOS/bin/sign_installed.sh "$ROOTFS/usr/lib/pam" | tail -2

[ -f "$TERM_PAM.orig" ] || cp -p "$TERM_PAM" "$TERM_PAM.orig"
sed -i \
    -e 's/^account    required       pam_opendirectory.so/account    required       pam_permit.so/' \
    -e 's/^session    required       pam_uwtmp.so/session    optional       pam_uwtmp.so/' \
    "$TERM_PAM"
cat "$TERM_PAM"
