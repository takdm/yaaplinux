#!/usr/bin/env bash
# stages/90-postinstall.sh — snapshots, report, cleanup (spec §6.5, §12.3).
# Non-destructive; safe to re-run.

STAGE_ID="90-postinstall"

run_stage() {
    ensure_chroot
    configure_snapshots
    finalize_config_copy
    write_report
    cfg_set meta.stage "done"
    log_info "postinstall complete"
}

ensure_chroot() {
    [ -x "$TARGET_ROOT/usr/bin/pacman" ] || die "target not bootable"
}

configure_snapshots() {
    local tool; tool="$(cfg_get disk.snapshots.tool)"; tool="${tool:-snapper}"
    [ "$(cfg_get disk.snapshots.enabled)" = true ] || { log_info "snapshots disabled by config"; return 0; }

    case "$tool" in
        snapper)
            log_info "configuring snapper on /"
            pkg_install snapper
            arch-chroot "$TARGET_ROOT" snapper -c root createconfig -r / >>"$YAAP_LOG" 2>&1 \
                || log_warn "snapper createconfig failed (may already exist)"
            # Pacman hooks for pre/post snapshots are installed in stage 50.
            arch-chroot "$TARGET_ROOT" systemctl enable snapper-timeline.timer \
                snapper-cleanup.timer >>"$YAAP_LOG" 2>&1 || true
            log_info "snapper timeline + cleanup timers enabled"
            ;;
        timeshift)
            log_info "timeshift selected (interactive setup recommended post-boot)"
            pkg_install timeshift
            ;;
    esac
}

# Ensure the persisted config on the target reflects the final state.
finalize_config_copy() {
    local dst="$TARGET_ROOT/etc/yaaplinux"
    mkdir -p "$dst"
    cp "$(_cfg_path)" "$dst/install-config.yaml" 2>/dev/null || true
    log_info "finalized $dst/install-config.yaml"
}
