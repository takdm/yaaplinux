#!/usr/bin/env bash
# stages/40-pacstrap.sh — install the base system onto the target (spec §7.1).
# Uses pacstrap (not pkg_install) because the target is not yet a system.

STAGE_ID="40-pacstrap"

run_stage() {
    local root_part; root_part="$(cfg_get storage.root_partition)"
    [ -b "$root_part" ] || die "root partition missing; run partition/format/mount stages"

    local pkgs
    pkgs="base base-devel linux-zen linux linux-firmware
btrfs-progs dosfstools exfatprogs ntfs-3g
networkmanager iwd
sudo vim nano
man-db man-pages"

    log_info "pacstrap base system (this pulls the payload)"
    if [ "${YAAP_DRYRUN:-0}" = 1 ]; then
        log_info "DRYRUN pacstrap $TARGET_ROOT $pkgs"
        cfg_set meta.stage "base-config"
        return 0
    fi

    pacman-key --init >/dev/null 2>&1 || true
    pacman-key --populate archlinux >/dev/null 2>&1 || true

    # shellcheck disable=SC2086
    pacstrap -K --noconfirm --needed "$TARGET_ROOT" $pkgs >>"$YAAP_LOG" 2>&1 \
        || die "pacstrap failed (see $YAAP_LOG)"

    genfstab
    cfg_set meta.stage "base-config"
    log_info "pacstrap complete"
}

# Regenerate fstab with UUIDs now that the target packages are present.
genfstab() {
    if command -v genfstab >/dev/null 2>&1; then
        genfstab -U "$TARGET_ROOT" > "$TARGET_ROOT/etc/fstab" 2>>"$YAAP_LOG" \
            || log_warn "genfstab failed; using earlier fstab"
        log_info "regenerated /etc/fstab via genfstab"
    fi
    # genfstab reflects current mounts only, so the hibernation swapfile (not a
    # mountpoint) is missing — re-append it here so resume stays wired.
    append_swap_fstab
}

append_swap_fstab() {
    local style hibernation
    style="$(cfg_get disk.swap.style)"
    hibernation="$(cfg_get disk.swap.hibernation)"
    if [ "$hibernation" = true ] && [ "$style" = zram_plus_file ]; then
        if ! grep -q '^/swap/swap ' "$TARGET_ROOT/etc/fstab" 2>/dev/null; then
            echo "/swap/swap none swap defaults 0 0" >> "$TARGET_ROOT/etc/fstab"
            log_info "appended /swap/swap to /etc/fstab (hibernation)"
        fi
    fi
}
