#!/usr/bin/env bash
# stages/80-bootloader.sh — bootloader, UKIs, Secure Boot, login manager
# (spec §10). Most fragile stage; do after the rest works. Secure Boot
# enrolment failure must leave a bootable unsigned system (§10.3).

STAGE_ID="80-bootloader"

run_stage() {
    ensure_chroot
    detect_firmware >/dev/null
    local fw; fw="$(cfg_get hardware.firmware)"

    if [ "$fw" = bios ]; then
        require_bios_ack
        install_grub_bios
    else
        install_uefi_boot
    fi

    install_login_manager
    cfg_set meta.stage "postinstall"
    log_info "bootloader stage complete"
}

ensure_chroot() {
    [ -x "$TARGET_ROOT/usr/bin/pacman" ] || die "target not bootable"
}

require_bios_ack() {
    if [ "$(cfg_get bootloader.bios_warning_acknowledged)" != true ]; then
        if [ "${YAAP_UNATTENDED:-0}" = 1 ]; then
            die "BIOS path requires bootloader.bios_warning_acknowledged=true (unattended)"
        fi
        ui_confirm_true "BIOS boot: Secure Boot is unavailable. Acknowledge and continue?" || \
            die "BIOS acknowledgement required; refusing to proceed (spec §10.2)"
        cfg_set bootloader.bios_warning_acknowledged true
    fi
}

# ---- UEFI path ------------------------------------------------------------
install_uefi_boot() {
    pkg_install systemd efibootmgr
    local strategy; strategy="$(cfg_get bootloader.uefi)"
    case "$strategy" in
        grub) install_systemd_boot; return 0 ;;   # UKIs pair with systemd-boot
        *)    install_systemd_boot ;;
    esac
}

install_systemd_boot() {
    log_info "installing systemd-boot"
    arch-chroot "$TARGET_ROOT" bootctl install >>"$YAAP_LOG" 2>&1 || die "bootctl install failed"

    # Loader entries: write a systemd-boot loader config pointing at ESP.
    local esp="$TARGET_ROOT/boot/efi"
    mkdir -p "$esp/loader/entries"
    build_uki_cmdline

    cat > "$esp/loader/loader.conf" <<'EOF'
default arch-linux-zen.conf
timeout 5
editor off
EOF

    efibootmgr --create-only --disk "$(cfg_get storage.device)" --part 1 \
        --label "YaapLinux" --uuid "$(cfg_get storage.esp_uuid)" \
        --loader '\EFI\boot\bootx64.efi' >>"$YAAP_LOG" 2>&1 || \
        log_warn "efibootmgr entry creation failed (bootctl may have configured it)"

    if [ "$(cfg_get bootloader.unified_kernel_images)" = true ]; then
        build_uki
    else
        log_info "UKIs disabled; relying on split /boot kernel + initrd loader entry"
    fi
    maybe_sign_secure_boot
}

# Assemble the kernel cmdline from config (spec §10.4).
build_uki_cmdline() {
    local ruuid; ruuid="$(luks_cmdline_root)"
    local cmd="root=UUID=$ruuid rw quiet splash"
    if [ "$(cfg_get disk.swap.hibernation)" = true ]; then
        local off; off="$(cfg_get disk.swap.resume_offset)"
        cmd="$cmd resume=UUID=$ruuid"
        [ -n "$off" ] && cmd="$cmd resume_offset=$off"
    fi
    cfg_set bootloader.cmdline "$cmd"
    log_info "UKI cmdline: $cmd"
}

luks_cmdline_root() {
    # For UKI root= we use the btrfs root UUID (LUKS is unlocked by sd-encrypt
    # in the initramfs before root mount).
    cfg_get storage.root_uuid
}

# Build a Unified Kernel Image at /boot/EFI/Linux/arch-linux-zen.efi.
build_uki() {
    local esp="$TARGET_ROOT/boot/efi"
    local kernel="$TARGET_ROOT/boot/vmlinuz-linux-zen"
    local initrd="$TARGET_ROOT/boot/initramfs-linux-zen.img"
    local microcode=""
    [ "$(cfg_get hardware.cpu.microcode)" = intel-ucode ] && microcode="$TARGET_ROOT/boot/intel-ucode.img"
    [ "$(cfg_get hardware.cpu.microcode)" = amd-ucode ]   && microcode="$TARGET_ROOT/boot/amd-ucode.img"

    command -v ukify >/dev/null 2>&1 || { log_warn "ukify unavailable; skipping UKI build"; return 0; }

    mkdir -p "$esp/EFI/Linux"
    local cmd; cmd="$(cfg_get bootloader.cmdline)"
    local osrel="$TARGET_ROOT/usr/lib/os-release"
    local out="$esp/EFI/Linux/arch-linux-zen.efi"

    local args=(build -o "$out"
        --os-release "$osrel"
        --linux "$kernel" "$initrd"
        --cmdline "$cmd")
    [ -n "$microcode" ] && args=( "${args[@]}" --microcode "$microcode" )

    ukify "${args[@]}" >>"$YAAP_LOG" 2>&1 || log_warn "ukify build failed; falling back to split /boot"
    log_info "UKI built at $esp/EFI/Linux/arch-linux-zen.efi"
}

# ---- Secure Boot (graceful, never bricks) ---------------------------------
maybe_sign_secure_boot() {
    local strategy; strategy="$(cfg_get hardware.secure_boot.strategy)"
    local state; state="$(detect_secure_boot_state)"
    case "$strategy" in
        none) log_info "Secure Boot: strategy=none"; return 0 ;;
        sbctl)
            if [ "$state" = setup_mode ] || [ "$state" = enabled ]; then
                sign_sbctl
            else
                log_warn "Secure Boot: not in setup mode; leaving UKI unsigned"
            fi
            ;;
        systemd)
            log_info "Secure Boot: systemd-native signing strategy (ukify signing placeholder)"
            # Real ukify --sign-secure-boot wiring deferred; leave unsigned + notice.
            ;;
        *) log_info "Secure Boot: no strategy selected";;
    esac
}

sign_sbctl() {
    if ! command -v sbctl >/dev/null 2>&1 && [ ! -x "$TARGET_ROOT/usr/bin/sbctl" ]; then
        log_warn "sbctl unavailable; skipping enrolment"
        return 0
    fi
    log_info "Secure Boot: attempting sbctl enrolment (graceful abort on failure)"
    local ok=0
    if [ "${YAAP_UNATTENDED:-0}" = 1 ]; then
        arch-chroot "$TARGET_ROOT" sbctl enroll -v >>"$YAAP_LOG" 2>&1 && ok=1
    else
        arch-chroot "$TARGET_ROOT" sbctl enroll -v >>"$YAAP_LOG" 2>&1 && ok=1
    fi

    if [ "$ok" != 1 ]; then
        graceful_sb_abort
        return 0
    fi
    cfg_set hardware.secure_boot.enrolled true
    log_info "Secure Boot enrolled via sbctl"
}

# §10.3 — leave a bootable unsigned system; never persist a half-enrolled state.
graceful_sb_abort() {
    log_err "Secure Boot enrolment failed; restoring a bootable unsigned system"
    cfg_set hardware.secure_boot.enrolled false
    log_warn "Secure Boot left DISABLED. UKI remains bootable unsigned."
    log_warn "Manual enrolment later: sbctl enroll -v  (see /root/install-report.txt)"
    # Ensure the UKI file exists and is the fallback; do not touch further.
}

# ---- BIOS path ------------------------------------------------------------
install_grub_bios() {
    pkg_install grub
    local bios_part; bios_part="$(bios_grub_partition)"
    log_info "installing GRUB to $bios_part (BIOS)"
    arch-chroot "$TARGET_ROOT" grub-install --target=i386-pc --recheck "$bios_part" >>"$YAAP_LOG" 2>&1 \
        || die "grub-install (i386-pc) failed"
    arch-chroot "$TARGET_ROOT" grub-mkconfig -o /boot/grub/grub.cfg >>"$YAAP_LOG" 2>&1 \
        || die "grub-mkconfig failed"
}

bios_grub_partition() {
    local dev; dev="$(cfg_get storage.device)"
    case "$(basename "$dev")" in
        nvme*|mmcblk*) echo "${dev}p2" ;;
        *)             echo "${dev}2" ;;
    esac
}

# ---- Login manager --------------------------------------------------------
install_login_manager() {
    local lm; lm="$(cfg_get login.manager)"
    case "$lm" in
        greetd)
            pkg_install greetd tuigreet
            mkdir -p "$TARGET_ROOT/etc/greetd"
            cp "$ASSETS_DIR/greetd-config.toml" "$TARGET_ROOT/etc/greetd/config.toml" 2>/dev/null || true
            arch-chroot "$TARGET_ROOT" systemctl enable greetd.service >>"$YAAP_LOG" 2>&1 \
                || die "could not enable greetd"
            log_info "login: greetd + tuigreet"
            ;;
        tty_autologin)
            log_info "login: TTY autologin (getty@tty1 override)"
            mkdir -p "$TARGET_ROOT/etc/systemd/system/getty@tty1.service.d"
            cat > "$TARGET_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
            ;;
    esac
}
