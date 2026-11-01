#!/usr/bin/env bash
# stages/60-drivers-media.sh — codecs, VA-API driver matrix, universal drivers,
# multilib, printing, scanning, GStreamer tuning (spec §8). Largely declarative:
# build an install set from config, run conflict guards, install, then verify.

STAGE_ID="60-drivers-media"

run_stage() {
    ensure_chroot
    build_install_set
    apply_multilib_if_requested
    install_universal_drivers
    install_codecs
    install_vaapi_drivers
    install_gstreamer_tuning
    install_printing
    install_scanning
    run_diagnostics
    cfg_set meta.stage "desktop"
    log_info "drivers/media stage complete"
}

ensure_chroot() {
    [ -x "$TARGET_ROOT/usr/bin/pacman" ] || die "target not bootable; run pacstrap/base-config"
}

# Track the pending set so conflict guards can inspect it.
build_install_set() {
    YAAP_INSTALL_SET="base base-devel linux linux-firmware"
    local gpu; gpu="$(cfg_get hardware.gpu.primary)"
    [ "$gpu" != unknown ] && YAAP_INSTALL_SET="$YAAP_INSTALL_SET video-render-utils"
    log_debug "install set seed: $YAAP_INSTALL_SET"
}

apply_multilib_if_requested() {
    if [ "$(cfg_get media.multilib)" = true ]; then
        repo_enable_multilib || log_warn "multilib enablement failed (non-fatal)"
    fi
}

install_universal_drivers() {
    local set=""

    # Audio — always.
    set="$set pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber alsa-utils alsa-ucm-conf sof-firmware"

    # Filesystems — always.
    set="$set exfatprogs dosfstools ntfs-3g"

    # Sensors — always.
    set="$set lm_sensors"

    # Peripherals, gated.
    [ "$(cfg_get peripherals.bluetooth)" = true ]   && set="$set bluez bluez-utils"
    [ "$(cfg_get peripherals.touchpad)" = true ]     && set="$set libinput"
    [ "$(cfg_get peripherals.webcam)" = true ]       && set="$set v4l-utils"
    [ "$(cfg_get peripherals.tablet)" = true ]       && set="$set libwacom"
    [ "$(cfg_get peripherals.fingerprint)" = true ]  && set="$set fprintd"

    # Storage health.
    set="$set smartmontools"
    [ "$(cfg_get storage.type)" = nvme ] && set="$set nvme-cli"

    # Modem.
    [ "$(cfg_get peripherals.modem)" = true ] && set="$set modemmanager"

    # Power (laptop): power-profiles-daemon XOR tlp.
    if [ "$(cfg_get battery)" = true ]; then
        local pd; pd="$(cfg_get power.daemon)"; pd="${pd:-power-profiles-daemon}"
        case "$pd" in
            tlp)                 set="$set tlp" ;;
            power-profiles-daemon) set="$set power-profiles-daemon" ;;
            none) : ;;
        esac
    fi

    pkg_install $set
}

install_codecs() {
    [ "$(cfg_get media.codecs)" = true ] || { log_info "codecs disabled by config"; return 0; }
    log_info "installing codec stack"
    local ugly="gst-plugins-ugly"
    [ "$(cfg_get media.gstreamer_ugly)" = false ] && ugly=""
    pkg_install \
        ffmpeg \
        gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad $ugly gst-libav
    # Diagnostics tools always useful with codecs.
    [ "$(cfg_get media.diagnostics)" = true ] && pkg_install libva-utils vdpauinfo
}

# VA-API driver per the hardware matrix (spec §8.2).
install_vaapi_drivers() {
    local gpu; gpu="$(cfg_get hardware.gpu.primary)"
    case "$gpu" in
        amd)
            pkg_install mesa libva-mesa-driver ;;
        intel)
            local gen; gen="$(cfg_get hardware.gpu.intel_gen)"
            if [ "$gen" = broadwell_plus ]; then
                pkg_install mesa libva-mesa-driver intel-media-driver
                # Skylake+ needs the Intel firmware subpackage (assert, warn if absent).
                if ! arch-chroot "$TARGET_ROOT" pacman -Q linux-firmware-intel >/dev/null 2>&1; then
                    log_warn "linux-firmware-intel missing — Intel VA-API on Skylake+ may fail silently"
                fi
            else
                pkg_install mesa libva-mesa-driver libva-intel-driver
            fi
            # Set LIBVA_DRIVER_NAME=iHD for intel-media-driver in the session env.
            write_env_hint LIBVA_DRIVER_NAME iHD ;;
        nvidia)
            pkg_install mesa nvidia-utils libva-nvidia-driver
            write_env_hint LIBVA_DRIVER_NAME nvidia ;;
        unknown|*)
            log_warn "no VA-API driver installed (GPU undetected: $gpu)" ;;
    esac
    # User must be in the video group for acceleration (assert, spec §8.2).
    assert_video_group
}

write_env_hint() {
    local key="$1" val="$2"
    mkdir -p "$TARGET_ROOT/etc/profile.d"
    echo "export $key=$val" > "$TARGET_ROOT/etc/profile.d/yaap-vaapi.sh"
    # Also expose to the Wayland session (consumed by hyprland.lua generation).
    cfg_set desktop.env.$key "$val"
    log_info "env hint: $key=$val"
}

assert_video_group() {
    local name; name="$(cfg_get user.name)"
    [ -z "$name" ] && { log_warn "no user to check video group"; return 0; }
    if arch-chroot "$TARGET_ROOT" id "$name" >/dev/null 2>&1; then
        if ! arch-chroot "$TARGET_ROOT" id "$name" | grep -qw video; then
            arch-chroot "$TARGET_ROOT" usermod -aG video "$name" >>"$YAAP_LOG" 2>&1 \
                && log_info "added $name to video group"
        fi
    fi
}

# GStreamer decoder ranking / AV1 demotion based on vainfo (spec §8.8).
install_gstreamer_tuning() {
    [ "$(cfg_get media.diagnostics)" = true ] || return 0
    local rank
    case "$(cfg_get hardware.gpu.primary)" in
        nvidia)
            rank="nvmpegvideodec:MAX,nvmpeg2videodec:MAX,nvmpeg4videodec:MAX,nvh264sldec:MAX,nvh264dec:MAX,nvjpegdec:MAX,nvh265sldec:MAX,nvh265dec:MAX,nvvp9dec:MAX" ;;
        *) rank="" ;;
    esac
    [ -n "$rank" ] && cfg_set desktop.env.GST_PLUGIN_FEATURE_RANK "$rank"
}

install_printing() {
    [ "$(cfg_get media.printing)" = true ] || { log_info "printing disabled by config"; return 0; }
    log_info "installing printing stack (OpenPrinting CUPS)"
    pkg_install cups system-config-printer avahi ghostscript gsfonts gutenprint
    # hplip only if HP selected; track it in the install set so the foo2zjs
    # conflict guard below has something to inspect (spec §8.5, FS#58815).
    if [ "$(cfg_get media.print_hp)" = true ]; then
        pkg_install hplip
        YAAP_INSTALL_SET="$YAAP_INSTALL_SET hplip"
    fi
    # foo2zjs-nightly is AUR-only and opt-in (not yet wired into this stage);
    # once it is, this guard aborts if both HP and foo2zjs printers are chosen.
    pkg_conflict_guard hplip foo2zjs-nightly
    arch-chroot "$TARGET_ROOT" systemctl enable cups.service avahi-daemon.service >>"$YAAP_LOG" 2>&1 || true
    log_info "cups + avahi enabled"
}

install_scanning() {
    [ "$(cfg_get media.scanning)" = true ] || { log_info "scanning disabled by config"; return 0; }
    log_info "installing scanning stack (SANE)"
    pkg_install sane sane-airscan ipp-usb simple-scan
    arch-chroot "$TARGET_ROOT" systemctl enable ipp-usb.service >>"$YAAP_LOG" 2>&1 || true
    log_info "ipp-usb enabled (required for USB IPP driverless scanners)"
}

# Run vainfo, capture to log; apply AV1 demotion if unsupported.
run_diagnostics() {
    [ "$(cfg_get media.diagnostics)" = true ] || return 0
    mkdir -p "$TARGET_ROOT/var/log/yaaplinux"
    local logf="$TARGET_ROOT/var/log/yaaplinux/vainfo.log"
    log_info "running vainfo in target"
    arch-chroot "$TARGET_ROOT" vainfo >>"$logf" 2>&1 || {
        log_warn "vainfo failed (driver may not be loaded yet; verify post-boot)"
        return 0
    }
    # Encode capability summary.
    grep -o 'VAEntrypointEncSlice[a-z0-9=_.]*' "$logf" 2>/dev/null | sort -u > "$logf.enc" 2>/dev/null || true
    # AV1 demotion when unsupported (spec §8.8).
    if ! grep -qi 'VAProfileAV1' "$logf" 2>/dev/null; then
        log_info "no AV1 hardware decode detected; demoting AV1 GStreamer decoders"
        local cur; cur="$(cfg_get desktop.env.GST_PLUGIN_FEATURE_RANK)"
        if [ -n "$cur" ]; then
            cfg_set desktop.env.GST_PLUGIN_FEATURE_RANK "${cur},avdec_av1:NONE,av1dec:NONE"
        else
            cfg_set desktop.env.GST_PLUGIN_FEATURE_RANK "avdec_av1:NONE,av1dec:NONE"
        fi
    fi
    log_info "vainfo captured -> $logf"
}
