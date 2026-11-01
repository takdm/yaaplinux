#!/usr/bin/env bash
# lib/chroot.sh — arch-chroot helpers for the target system.
# Requires TARGET_ROOT to be mounted with a bootable target (post-pacstrap).
#
# Provides:
#   chroot_run <cmd...>          # run a command in the target
#   chroot_run_bash <script>     # run a bash -c string in the target
#   chroot_enable <unit...>      # enable systemd units in the target

chroot_run() {
    [ -d "$TARGET_ROOT/usr/bin/systemctl" ] || die "chroot_run: $TARGET_ROOT is not a bootable target"
    arch-chroot "$TARGET_ROOT" "$@"
}

chroot_run_bash() {
    arch-chroot "$TARGET_ROOT" bash -c "$1"
}

chroot_enable() {
    arch-chroot "$TARGET_ROOT" systemctl enable "$@"
}
