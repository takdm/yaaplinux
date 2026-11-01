#!/usr/bin/env bash
# stages/20-format.sh — filesystems and btrfs subvolumes (spec §6.2, §6.4, §6.5).
# Destructive. Formats ESP (FAT32) and btrfs root, creates subvolumes, and the
# btrfs swapfile for hibernation when enabled. Snapshots config is written here.

STAGE_ID="20-format"

run_stage() {
    local dev root_part luks
    dev="$(cfg_get storage.device)"
    root_part="$(cfg_get storage.root_partition)"
    [ -b "$root_part" ] || die "root partition $root_part not found (run partition stage)"
    luks="$(cfg_get disk.luks.enabled)"

    # Resolve the btrfs backing device (LUKS mapper if enabled).
    local btrfs_dev="$root_part"
    if [ "$luks" = true ]; then
        local m; m="$(cfg_get disk.luks.open_mapper)"
        [ -b "/dev/mapper/$m" ] || die "LUKS mapper /dev/mapper/$m not open"
        btrfs_dev="/dev/mapper/$m"
    fi

    log_info "formatting ESP on ${root_part%%p*}p (FAT32)"
    # ESP device: partition 1.
    local esp_dev; esp_dev="$(esp_device)"
    mkfs.fat -F32 "$esp_dev" >>"$YAAP_LOG" 2>&1 || die "mkfs.fat failed on $esp_dev"

    log_info "creating btrfs on $btrfs_dev"
    mkfs.btrfs -L archroot "$btrfs_dev" >>"$YAAP_LOG" 2>&1 || die "mkfs.btrfs failed"

    # Materialise subvolumes on a temporary mount (ESP is mounted later, in
    # stage 30, to avoid hiding it under the root mount).
    btrfs_create_subvolumes "$btrfs_dev"

    cfg_set meta.stage "mount"
}

esp_device() {
    local dev root_part
    dev="$(cfg_get storage.device)"
    root_part="$(cfg_get storage.root_partition)"
    # Partition 1 is ESP.
    local base; base="$(basename "$dev")"
    case "$base" in
        nvme*|mmcblk*) echo "${dev}p1" ;;
        *)             echo "${dev}1" ;;
    esac
}

esp_mountpoint() { echo "$TARGET_ROOT/boot/efi"; }

btrfs_create_subvolumes() {
    local dev="$1"
    local tmp="$TARGET_ROOT/.btrfs-tmp"
    mkdir -p "$tmp"
    mount -o noatime,compress=zstd:3 "$dev" "$tmp" >>"$YAAP_LOG" 2>&1 || die "btrfs mount failed"

    local subs
    # Read subvolumes from config (default @ @home @swap @snapshots).
    subs="$(cfg_array disk.subvolumes)"
    [ -z "$subs" ] && subs="@
@home
@swap
@snapshots"

    while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        log_info "btrfs subvolume: /$sub"
        btrfs subvolume create "$tmp/$sub" >>"$YAAP_LOG" 2>&1 || die "subvolume create @/$sub failed"
    done <<< "$subs"

    # Hibernation swapfile needs CoW disabled + resolvable resume_offset.
    if [ "$(cfg_get disk.swap.hibernation)" = true ]; then
        create_swapfile "$tmp"
    fi

    umount "$tmp" >>"$YAAP_LOG" 2>&1 || true
    rmdir "$tmp" 2>/dev/null || true
}

# btrfs swapfile: CoW disabled, then map-swapfile for resume_offset.
create_swapfile() {
    local tmp="$1"
    local size_gb; size_gb="$(cfg_get disk.swap.file_size_gb)"; size_gb="${size_gb:-8}"
    local swap_sub; swap_sub="$(cfg_get disk.swap.swap_subvolume)"; swap_sub="${swap_sub:-@swap}"
    local file="$tmp/$swap_sub/swap"
    log_info "creating hibernation swapfile at /$swap_sub/swap (${size_gb}GiB, CoW off)"
    mkdir -p "$tmp/$swap_sub"
    # CoW disabled is mandatory for a btrfs swapfile.
    chattr +C "$file" 2>/dev/null || true
    if command -v btrfs >/dev/null 2>&1; then
        btrfs filesystem mkswapfile --size "${size_gb}GiB" "$file" >>"$YAAP_LOG" 2>&1 \
            || { fallocate -l "${size_gb}G" "$file"; mkswap "$file" >>"$YAAP_LOG" 2>&1; }
    else
        fallocate -l "${size_gb}G" "$file" && mkswap "$file" >>"$YAAP_LOG" 2>&1
    fi
    local off
    off="$(btrfs inspect-internal map-swapfile -r "$file" 2>/dev/null | awk '{print $1}')"
    if [ -n "$off" ]; then
        cfg_set disk.swap.resume_offset "$off"
        log_info "resume_offset=$off"
    else
        log_warn "could not compute resume_offset; hibernation may not resume"
    fi
}
