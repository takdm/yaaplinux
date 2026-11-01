#!/usr/bin/env bash
# stages/00-preflight.sh — pre-mutation checks (spec §5). Any hard failure
# aborts before touching a disk. Firmware branch is resolved here.

STAGE_ID="00-preflight"

run_stage() {
    local hard=0
    check_root
    check_arch_live
    check_internet || hard=1
    check_clock || hard=1
    resolve_target_disk || hard=1
    check_disk_size || hard=1
    check_firmware_branch
    check_secure_boot_preflight
    check_battery
    check_ram
    check_mirrorlist
    [ "$hard" = 1 ] && die "preflight: one or more hard checks failed (see log)"
    cfg_set meta.stage "partitioning"
    log_info "preflight OK"
}

check_root() {
    if [ "$(id -u)" != 0 ]; then
        die "must run as root (use sudo)"
    fi
}

check_arch_live() {
    # The installer must run from an Arch ISO environment.
    if [ ! -f /etc/arch-release ] && [ ! -d /run/archos ]; then
        log_warn "not clearly an Arch live environment (missing /etc/arch-release)"
        if [ "${YAAP_UNATTENDED:-0}" != 1 ]; then
            ui_confirm yes "Continue anyway (not a detected Arch ISO environment)?" || \
                die "refusing to run outside the Arch live environment"
        fi
    fi
}

check_internet() {
    log_info "checking internet connectivity"
    local ok=0
    for host in 1.1.1.1 8.8.8.8 archlinux.org; do
        if ping -c1 -W2 "$host" >/dev/null 2>&1; then ok=1; break; fi
        if curl -sI --max-time 5 "https://archlinux.org" >/dev/null 2>&1; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || { log_err "no network reachability"; return 1; }
    log_info "network: reachable"
}

check_clock() {
    local t
    t="$(timedatectl show -p NTPsynchronized --value 2>/dev/null)"
    if [ "$t" = "yes" ]; then
        log_info "clock: synchronised"
    else
        log_warn "clock not reported synchronised; synchronising"
        timedatectl set-ntp true 2>/dev/null || true
        sleep 2
        t="$(timedatectl show -p NTPsynchronized --value 2>/dev/null)"
        if [ "$t" != "yes" ]; then
            log_err "clock not synchronised"; return 1
        fi
    fi
}

resolve_target_disk() {
    # Already resolved by --target or a prior detect run.
    if [ -b "${YAAP_TARGET_DISK:-}" ]; then
        cfg_set storage.device "${YAAP_TARGET_DISK}"
    fi
    detect_storage || true
    local dev; dev="$(cfg_get storage.device)"
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        if [ "${YAAP_UNATTENDED:-0}" = 1 ]; then
            log_err "no target disk in unattended mode (use --target /dev/XXX)"; return 1
        fi
        ui_input "" "Target disk (e.g. /dev/nvme0n1)"
        dev="$REPLY"
        cfg_set storage.device "$dev"
        detect_storage || true
        dev="$(cfg_get storage.device)"
    fi
    [ -n "$dev" ] && [ -b "$dev" ] || return 1
    log_info "target disk: $dev"
}

check_disk_size() {
    local dev; dev="$(cfg_get storage.device)"
    [ -b "$dev" ] || return 1
    local sectors gib
    sectors="$(cat "/sys/block/$(basename "$dev")/size" 2>/dev/null || echo 0)"
    gib=$(( sectors * 512 / 1024 / 1024 / 1024 ))
    if [ "$gib" -lt 32 ]; then
        log_err "target $dev is ${gib}GiB (< 32 GiB minimum)"; return 1
    fi
    log_info "target size: ${gib}GiB OK"
}

check_firmware() {
    detect_firmware >/dev/null
}

check_firmware_branch() {
    check_firmware
    local fw; fw="$(cfg_get hardware.firmware)"
    if [ "$fw" = uefi ] && [ -d /sys/firmware/efi ]; then
        log_info "UEFI firmware confirmed"
    elif [ "$fw" = bios ]; then
        log_warn "BIOS firmware — Secure Boot unavailable; GRUB path selected"
    fi
    if [ "${YAAP_UNATTENDED:-0}" != 1 ]; then
        ui_confirm yes "Firmware detected as ${fw}. Proceed?" || \
            die "firmware confirmation declined"
    fi
}

check_secure_boot_preflight() {
    detect_secure_boot_state >/dev/null
    local st; st="$(cfg_get hardware.secure_boot.setup_mode)"
    log_info "secure boot setup_mode=$st (detailed state in detect log)"
}

check_battery() {
    detect_peripherals >/dev/null
    local b; b="$(cfg_get battery)"
    [ "$b" = true ] && log_info "battery present (laptop): power management enabled" || \
        log_info "no battery (desktop)"
}

check_ram() {
    local kib
    kib="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
    [ -n "$kib" ] || return 0
    local mib=$(( kib / 1024 ))
    if [ "$mib" -lt 768 ]; then
        log_err "free RAM ${mib}MiB < 768MiB required for pacstrap"; return 1
    fi
    [ "$mib" -lt 2048 ] && log_warn "RAM ${mib}MiB is low; pacstrap may be slow"
    log_info "RAM: ${mib}MiB"
}

check_mirrorlist() {
    local ml="/etc/pacman.d/mirrorlist"
    [ -f "$ml" ] || return 0
    if command -v reflector >/dev/null 2>&1; then
        log_info "refreshing mirrorlist via reflector"
        reflector --latest 12 --sort rate --save "$ml" >>"$YAAP_LOG" 2>&1 || \
            log_warn "reflector failed; using existing mirrorlist"
    else
        log_info "reflector not present; using existing mirrorlist"
    fi
}
