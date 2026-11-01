#!/usr/bin/env bash
# lib/pkg.sh — pacman / AUR wrappers with conflict guards and the one
# sanctioned full-sync (multilib). All installs use -S (never -Sy) so no
# partial upgrade can occur except inside repo_enable_multilib.
#
# Provides:
#   pkg_install <pkgs...>          # pacman -S --needed; chroot-aware
#   pkg_install_aur <pkgs...>      # via helper; non-fatal
#   pkg_conflict_guard <a> <b>     # abort if both in YAAP_INSTALL_SET
#   repo_enable_multilib           # explicit -Syu exception (spec §8.4)

# Prefix that routes pacman at the target when it is already a bootable system.
_pkg_target_prefix() {
    if [ -x "$TARGET_ROOT/usr/bin/pacman" ]; then echo "chroot"; else echo "live"; fi
}

pkg_install() {
    [ "$#" -eq 0 ] && return 0
    local pkgs=("$@")
    if [ "${YAAP_DRYRUN:-0}" = 1 ]; then
        log_info "DRYRUN pacman -S --needed ${pkgs[*]}"
        return 0
    fi
    local attempt rc
    for attempt in 1 2 3; do
        if [ "$(_pkg_target_prefix)" = chroot ]; then
            YAAP_FAIL_CMD="arch-chroot $TARGET_ROOT pacman -S --needed ${pkgs[*]}"
            arch-chroot "$TARGET_ROOT" pacman -S --needed --noconfirm --noprogressbar "${pkgs[@]}" \
                >>"$YAAP_LOG" 2>&1; rc=$?
        else
            YAAP_FAIL_CMD="pacman -S --needed ${pkgs[*]}"
            pacman -S --needed --noconfirm --noprogressbar "${pkgs[@]}" \
                >>"$YAAP_LOG" 2>&1; rc=$?
        fi
        [ "$rc" = 0 ] && return 0
        log_warn "pacman attempt $attempt failed (rc=$rc) for: ${pkgs[*]}"
        [ "$attempt" = 3 ] || sleep 3
    done
    die "pacman failed after 3 attempts: ${pkgs[*]}"
}

pkg_install_aur() {
    [ "$#" -eq 0 ] && return 0
    local helper="$YAAP_AUR_HELPER"; helper="${helper:-yay}"
    if ! command -v "$helper" >/dev/null 2>&1; then
        if [ "$(_pkg_target_prefix)" = chroot ] && [ -x "$TARGET_ROOT/usr/bin/$helper" ]; then
            : # use inside chroot below
        else
            log_warn "AUR helper '$helper' unavailable; skipping AUR install (non-fatal): $*"
            return 0
        fi
    fi
    log_info "AUR: $helper -S --needed --noconfirm $*"
    if [ "$(_pkg_target_prefix)" = chroot ]; then
        arch-chroot "$TARGET_ROOT" "$helper" -S --needed --noconfirm --noprogressbar "$@" >>"$YAAP_LOG" 2>&1 \
            || { log_warn "AUR build failed (non-fatal): $*"; return 1; }
    else
        "$helper" -S --needed --noconfirm --noprogressbar "$@" >>"$YAAP_LOG" 2>&1 \
            || { log_warn "AUR build failed (non-fatal): $*"; return 1; }
    fi
    return 0
}

# Abort if both packages are present in the pending install set.
pkg_conflict_guard() {
    local a="$1" b="$2"
    local set=" ${YAAP_INSTALL_SET:-} "
    local ha hb
    case "$set" in *" $a "*) ha=1;; *) ha=0;; esac
    case "$set" in *" $b "*) hb=1;; *) hb=0;; esac
    if [ "$ha" = 1 ] && [ "$hb" = 1 ]; then
        die "conflict guard: '$a' and '$b' are mutually exclusive (spec §8.5)"
    fi
}

# The single documented full-sync exception (spec §8.4). Not reachable from any
# other path: callers must invoke this function explicitly.
repo_enable_multilib() {
    log_info "enabling multilib — this triggers a full system sync (-Syu)"
    local pc
    if [ "$(_pkg_target_prefix)" = chroot ]; then pc="$TARGET_ROOT/etc/pacman.conf"; else pc=/etc/pacman.conf; fi

    # Idempotent: already enabled?
    if grep -qE '^\[multilib\]' "$pc" 2>/dev/null; then
        log_info "multilib already enabled"
    else
        # Uncomment [multilib] and its Include line.
        sed -i -E 's/^#?\[multilib\]/[multilib]/; s/^#[[:space:]]*Include = \/etc\/pacman\.d\/multilib\.db/Include = \/etc\/pacman\.d\/multilib\.db/' "$pc"
        if ! grep -qE '^\[multilib\]' "$pc"; then
            printf '\n[multilib]\nInclude = /etc/pacman.d/multilib.db\n' >> "$pc"
        fi
    fi

    if [ "${YAAP_DRYRUN:-0}" = 1 ]; then
        log_info "DRYRUN full sync (pacman -Syu)"
        return 0
    fi

    # Full upgrade, never -Sy.
    if [ "$(_pkg_target_prefix)" = chroot ]; then
        arch-chroot "$TARGET_ROOT" pacman -Syu --noconfirm --noprogressbar >>"$YAAP_LOG" 2>&1 || {
            log_err "multilib full-sync failed; reverting pacman.conf edit"
            sed -i -E 's/^\[multilib\]/#[multilib]/' "$pc"
            return 1
        }
    else
        pacman -Syu --noconfirm --noprogressbar >>"$YAAP_LOG" 2>&1 || {
            log_err "multilib full-sync failed; reverting pacman.conf edit"
            sed -i -E 's/^\[multilib\]/#[multilib]/' "$pc"
            return 1
        }
    fi

    # Verify the repo is populated.
    if ! pacman -Sl multilib >/dev/null 2>&1; then
        log_warn "multilib enabled but package list unavailable"
    fi
    cfg_set media.multilib true
    log_info "multilib enabled and synced"
}
