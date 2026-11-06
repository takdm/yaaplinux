#!/usr/bin/env bash
# stages/10-partition.sh — GPT layout, optional LUKS2 container (spec §6.1, §6.3).
# Destructive. Creates ESP, (bios_grub on BIOS), and root partition. Opens LUKS
# if enabled. Does not format or mount.

STAGE_ID="10-partition"

run_stage() {
    local dev luks esp_size root_start
    dev="$(cfg_get storage.device)"
    [ -b "$dev" ] || die "no valid target disk in config"

    luks="$(cfg_get disk.luks.enabled)"
    esp_size="$(esp_size_for)"

    log_info "partitioning $dev (LUKS=$luks, ESP=${esp_size}MiB)"

    # --- GPT table ---------------------------------------------------------
    sgdisk --zap-all "$dev" >>"$YAAP_LOG" 2>&1 || die "sgdisk zap failed"
    dd if=/dev/zero of="$dev" bs=1M count=2048 conv=notrunc >>"$YAAP_LOG" 2>&1 || die "wipe failed"

    sgdisk -o "$dev" >>"$YAAP_LOG" 2>&1 || die "sgdisk new GPT failed"

    # ESP (always)
    sgdisk -n 1:0:+${esp_size}M -t 1:ef00 -c 1:"EFI System" "$dev" >>"$YAAP_LOG" 2>&1 \
        || die "sgdisk ESP failed"

    # BIOS boot partition (BIOS only)
    if [ "$(cfg_get hardware.firmware)" = bios ]; then
        sgdisk -n 2:0:+1M -t 2:ef02 -c 2:"BIOS boot" "$dev" >>"$YAAP_LOG" 2>&1 \
            || die "sgdisk bios_grub failed"
        root_start=3
    else
        root_start=2
    fi

    # Root (remainder)
    sgdisk -n "${root_start}:0:0" -t "${root_start}:8300" -c "${root_start}:root" "$dev" >>"$YAAP_LOG" 2>&1 \
        || die "sgdisk root failed"
    partprobe "$dev" >>"$YAAP_LOG" 2>&1 || true
    sync

    # Partition device path (handle partN naming for nvme/sd).
    local root_part="${dev}p${root_start}"
    [ -b "$root_part" ] || root_part="${dev}${root_start}"
    cfg_set storage.root_partition "$root_part"
    log_info "root partition: $root_part"

    if [ "$luks" = true ]; then
        setup_luks "$root_part"
    else
        cfg_set disk.luks.open_mapper ""
    fi

    cfg_set meta.stage "format"
}

esp_size_for() {
    # 1 GiB if UKIs planned, else 512 MiB.
    [ "$(cfg_get bootloader.unified_kernel_images)" = true ] && echo 1024 || echo 512
}

setup_luks() {
    local part="$1" mapper
    mapper="$(luks_mapper_name)"
    local cipher key_size kdf
    cipher="$(cfg_get disk.luks.cipher)";   cipher="${cipher:-aes-xts-plain64}"
    key_size="$(cfg_get disk.luks.key_size)"; key_size="${key_size:-512}"
    kdf="argon2id"

    log_info "creating LUKS2 container on $part ($cipher, ${key_size}-bit, $kdf)"

    # Non-interactive passphrase via keyfile prompt captured to a fd.
    local pass
    if [ "${YAAP_UNATTENDED:-0}" = 1 ]; then
        # Unattended: generate a passphrase and PERSIST it to a keyfile on the
        # (unencrypted) ESP in stage 30. Discarding it here would brick the
        # install — the LUKS prompt would be unanswerable after reboot.
        pass="$(generate_transient_key)"
        mkdir -p "$(dirname "$YAAP_LUKS_PASSPHRASE_FILE")"
        printf '%s' "$pass" > "$YAAP_LUKS_PASSPHRASE_FILE"
        chmod 600 "$YAAP_LUKS_PASSPHRASE_FILE"
        cfg_set disk.luks.unattended true
        printf '%s' "$pass" | cryptsetup luksFormat --type luks2 \
            --cipher "$cipher" --key-size "$key_size" \
            --pbkdf argon2id "$part" - >>"$YAAP_LOG" 2>&1 \
            || die "luksFormat failed"
    else
        ui_input "" "Enter passphrase for $part (LUKS)"
        pass="$REPLY"
        printf '%s' "$pass" | cryptsetup luksFormat --type luks2 \
            --cipher "$cipher" --key-size "$key_size" --pbkdf argon2id "$part" - >>"$YAAP_LOG" 2>&1 \
            || die "luksFormat failed"
    fi

    if [ "${YAAP_UNATTENDED:-0}" = 1 ]; then
        cryptsetup luksOpen --type luks2 --key-file "$YAAP_LUKS_PASSPHRASE_FILE" \
            "$part" "$mapper" >>"$YAAP_LOG" 2>&1 \
            || die "luksOpen failed for $mapper"
    else
        cryptsetup luksOpen --type luks2 "$part" "$mapper" >>"$YAAP_LOG" 2>&1 \
            || die "luksOpen failed for $mapper"
    fi

    # Optional TPM2 auto-unlock (weakens physical protection unless PIN added).
    # Enrolment KEEPS the passphrase slot; wiping it is a separate opt-in
    # (disk.luks.tpm2_wipe_password_slot) best done after a verified first boot.
    if [ "$(cfg_get hardware.secure_boot.tpm2_auto_unlock)" = true ]; then
        if ui_confirm yes "Add TPM2 auto-unlock? (weakens physical attack protection without a PIN)"; then
            if command -v systemd-cryptenroll >/dev/null 2>&1; then
                if systemd-cryptenroll --tpm2-device=auto "$mapper" >>"$YAAP_LOG" 2>&1; then
                    log_info "TPM2 slot enrolled (passphrase slot kept)"
                    if [ "$(cfg_get disk.luks.tpm2_wipe_password_slot)" = true ]; then
                        log_warn "tpm2_wipe_password_slot=true: wiping password slot"
                        systemd-cryptenroll --tpm2-device=auto --wipe-slot=password "$mapper" >>"$YAAP_LOG" 2>&1 \
                            || log_warn "password-slot wipe failed; passphrase slot retained"
                    fi
                else
                    log_warn "TPM2 enrolment failed; keeping passphrase-only"
                fi
            fi
        fi
    fi

    cfg_set disk.luks.open_mapper "$mapper"
    log_info "LUKS container open as /dev/mapper/$mapper"
}

luks_mapper_name() {
    local n; n="$(cfg_get disk.luks.mapper_name)"
    [ -n "$n" ] && { echo "$n"; return; }
    echo "cryptroot"
}

# Generate a random passphrase for unattended mode.
generate_transient_key() {
    head -c 64 /dev/urandom | base64 | head -c 44
}
