#!/usr/bin/env bash
# install.sh — YaapLinux Custom Flavor installer / orchestrator.
# Revision 2.0. Resumable, checkpointed, hardware-detected.
#
# Usage:
#   install.sh [--config PATH] [--unattended] [--debug] [--dry-run]
#              [--target /dev/XXX] [--force] [-h|--help]
#
# Resume: re-running continues from the first incomplete stage. A stage whose
# consumed config hash changed is re-run; destructive stages re-ask for
# confirmation even on resume.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
LIB_DIR="$SCRIPT_DIR/lib"
ASSETS_DIR="$SCRIPT_DIR/assets"
STAGES_DIR="$SCRIPT_DIR/stages"
ISO_DIR="$SCRIPT_DIR/iso"

export YAAP_VERSION="2.0"
export YAAP_STAGE="pre"

# Runtime paths (live system during install; target copy lands in stage 50).
export YAAP_LOG_DIR="${YAAP_LOG_DIR:-/var/log/yaaplinux}"
export YAAP_CK_DIR="${YAAP_CK_DIR:-/var/lib/yaaplinux/checkpoints}"
export TARGET_ROOT="${YAAP_TARGET_ROOT:-/mnt}"
# Unattended LUKS: where the generated passphrase is staged (stage 10) and then
# copied to the ESP keyfile (stage 30). See stages/10 and stages/30.
export YAAP_LUKS_PASSPHRASE_FILE="${YAAP_LUKS_PASSPHRASE_FILE:-/var/lib/yaaplinux/luks-passphrase}"

# Options (defaults; overridden by argv).
YAAP_UNATTENDED=0
YAAP_DEBUG=0
YAAP_DRYRUN=0
YAAP_FORCE=0
YAAP_CONFIG=""                       # resolved after lib/config.sh is sourced
YAAP_CONFIG_TEMPLATE="$ASSETS_DIR/install-config.yaml"

usage() {
    cat <<EOF
YaapLinux Flavour installer v$YAAP_VERSION

Options:
  --config PATH     Use PATH as install-config.yaml (default:
                    /etc/yaaplinux/install-config.yaml)
  --target DEV      Target disk, e.g. /dev/nvme0n1 (default: auto-detect)
  --unattended      Never prompt; rely on config + --target
  --force           Skip destructive-stage re-confirmation on resume
  --dry-run         Log intended mutations, perform none
  --debug           Verbose debug logging
  -h, --help        This help

Safe to re-run: resumes from the first incomplete stage.
EOF
}

# ---- argv -----------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --unattended) YAAP_UNATTENDED=1 ;;
        --debug)      YAAP_DEBUG=1 ;;
        --dry-run)    YAAP_DRYRUN=1 ;;
        --force)      YAAP_FORCE=1 ;;
        --config=*)   YAAP_CONFIG="${arg#*=}" ;;
        --target=*)   export YAAP_TARGET_DISK="${arg#*=}" ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "install.sh: unknown argument '$arg'" >&2; usage; exit 2 ;;
    esac
done
export YAAP_UNATTENDED YAAP_DEBUG YAAP_DRYRUN

# ---- libs (log first; config path resolved then) --------------------------
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"

# Resolve config path now so lib/config.sh can pick it up.
export YAAP_CONFIG="${YAAP_CONFIG:-/etc/yaaplinux/install-config.yaml}"
# shellcheck source=/dev/null
source "$LIB_DIR/config.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/checkpoint.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/ui.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/detect.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/pkg.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/chroot.sh"

# ---- runtime bootstrap ----------------------------------------------------
mkdir -p "$YAAP_LOG_DIR" "$YAAP_CK_DIR" "$(dirname "$YAAP_CONFIG")"
export YAAP_LOG="$YAAP_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
log_init "$YAAP_LOG"

log_info "YaapLinux installer v$YAAP_VERSION starting (config=$YAAP_CONFIG)"
[ "$YAAP_DRYRUN" = 1 ] && log_warn "DRY-RUN: no destructive action will be taken"
[ "$YAAP_UNATTENDED" = 1 ] && log_info "UNATTENDED mode: no prompts"

# Seed config from template if absent.
if ! cfg_has version; then
    if [ -f "$YAAP_CONFIG_TEMPLATE" ]; then
        cp "$YAAP_CONFIG_TEMPLATE" "$YAAP_CONFIG"
        log_info "seeded config from template -> $YAAP_CONFIG"
    else
        die "no config at $YAAP_CONFIG and no template at $YAAP_CONFIG_TEMPLATE"
    fi
fi

# ---- stage graph ----------------------------------------------------------
STAGE_ORDER=(
    00-preflight
    10-partition
    20-format
    30-mount
    40-pacstrap
    50-base-config
    60-drivers-media
    70-desktop
    80-bootloader
    90-postinstall
)
declare -A STAGE_DESTRUCTIVE=(
    [10-partition]=1
    [20-format]=1
)

# Compute resume point (first incomplete stage).
resume=""
for s in "${STAGE_ORDER[@]}"; do
    if ! stage_is_done "$s"; then resume="$s"; break; fi
done
log_info "resume point: ${resume:-<all stages complete>}"

# Post-install report (orchestrator-owned so it is always available, even on
# resume when the final stage is skipped).
write_report() {
    local dst="$TARGET_ROOT/etc/yaaplinux"
    local report="$TARGET_ROOT/root/install-report.txt"
    {
        echo "=============================================="
        echo " YaapLinux Flavour — Post-Install Report"
        echo " generated $(date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "=============================================="
        echo
        echo "Completed stages:"
        local s
        for s in "${STAGE_ORDER[@]}"; do
            if [ -f "$_CK_DIR/$s.done" ]; then
                echo "  [x] $s  ($(sed -n '1p' "$_CK_DIR/$s.done" 2>/dev/null))"
            else
                echo "  [ ] $s (pending)"
            fi
        done
        echo
        echo "Detected hardware:"
        echo "  firmware:    $(cfg_get hardware.firmware)"
        echo "  secure boot: setup_mode=$(cfg_get hardware.secure_boot.setup_mode) enrolled=$(cfg_get hardware.secure_boot.enrolled)"
        echo "  cpu:         $(cfg_get hardware.cpu.vendor) ($(cfg_get hardware.cpu.microcode))"
        echo "  gpu:         $(cfg_get hardware.gpu.primary) (intel_gen=$(cfg_get hardware.gpu.intel_gen))"
        echo "  storage:     $(cfg_get storage.device) ($(cfg_get storage.type), rotational=$(cfg_get storage.rotational))"
        echo "  battery:     $(cfg_get battery)"
        echo
        echo "Configuration:"
        echo "  target root: $TARGET_ROOT"
        echo "  user:        $(cfg_get user.name) (shell $(cfg_get user.shell))"
        echo "  hostname:    $(cfg_get system.hostname)"
        echo "  kernel:      $(cfg_get kernel.primary) + fallback $(cfg_get kernel.fallback)"
        echo "  bootloader:  $(cfg_get bootloader.uefi) + UKIs=$(cfg_get bootloader.unified_kernel_images)"
        echo "  login:       $(cfg_get login.manager)/$(cfg_get login.greeter)"
        echo "  LUKS:        $(cfg_get disk.luks.enabled)"
        echo "  swap:        $(cfg_get disk.swap.style) (hibernation=$(cfg_get disk.swap.hibernation))"
        echo "  snapshots:   $(cfg_get disk.snapshots.enabled) ($(cfg_get disk.snapshots.tool))"
        echo "  multilib:    $(cfg_get media.multilib)"
        echo "  printing:    $(cfg_get media.printing)"
        echo "  scanning:    $(cfg_get media.scanning)"
        echo
        echo "Manual follow-up items:"
        [ "$(cfg_get hardware.secure_boot.enrolled)" != true ] && \
            echo "  - Secure Boot not enrolled; enroll manually if desired: sbctl enroll -v"
        [ "$(cfg_get media.multilib)" != true ] && \
            echo "  - multilib disabled (enable for Steam/Wine)."
        if [ "$(cfg_get disk.luks.unattended)" = true ]; then
            echo "  - UNATTENDED LUKS: passphrase saved to /boot/efi/keys/<mapper>.key on the ESP"
            echo "    (weakens physical-attack protection; move/delete after first boot if desired)."
        fi
        grep -q 'VAEntrypoint' "$TARGET_ROOT/var/log/yaaplinux/vainfo.log" 2>/dev/null \
            || echo "  - Verify VA-API after first boot: vainfo"
        echo "  - Reboot, then log in at the greetd prompt."
        echo
        echo "Useful paths:"
        echo "  Install log: $YAAP_LOG"
        echo "  VA-API log:  $TARGET_ROOT/var/log/yaaplinux/vainfo.log"
        echo "  Config:      $dst/install-config.yaml"
    } > "$report" 2>/dev/null
    cp "$report" /root/install-report.txt 2>/dev/null || true
    log_info "post-install report -> $report"
}


# ---- main loop ------------------------------------------------------------
for s in "${STAGE_ORDER[@]}"; do
    if stage_is_done "$s"; then
        log_info "skip $s (complete; config unchanged)"
        continue
    fi

    f="$STAGES_DIR/${s}.sh"
    [ -f "$f" ] || die "stage file missing: $f"

    # Warn if a later stage is somehow already done while this one is not.
    seen_this=0
    for later in "${STAGE_ORDER[@]}"; do
        [ "$later" = "$s" ] && seen_this=1 && continue
        if [ "$seen_this" = 1 ] && stage_is_done "$later"; then
            log_warn "stage '$later' is done but '$s' is not — config hash drift?"
        fi
    done

    # Destructive re-confirmation (even on resume), unless --force.
    if [ "${STAGE_DESTRUCTIVE[$s]:-0}" = 1 ] && [ "$YAAP_FORCE" != 1 ]; then
        if ! ui_confirm_true "Stage '$s' performs DESTRUCTIVE disk operations. Continue?"; then
            die "aborted at destructive stage $s (user declined)"
        fi
    fi

    log_info "==================== stage $s ===================="
    # shellcheck source=/dev/null
    source "$f"
    stage_begin "$s"
    run_stage
    stage_complete "$s"
    log_info "==================== stage $s complete ===================="
done

write_report
log_info "install sequence finished. See $YAAP_LOG and /root/install-report.txt"
[ "$YAAP_UNATTENDED" = 1 ] || ui_notify "Install sequence complete. Reboot to finish."

exit 0
