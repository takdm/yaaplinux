#!/usr/bin/env bash
# lib/dotfiles.sh — dotfiles provisioning shared by the YaapLinux installer
# (stage 50-base-config) and the installed-system CLI
# (/etc/yaaplinux/yaap).
#
# Config contract (read with cfg_get/cfg_set from lib/config.sh, which must be
# sourced first):
#   disk.dotfiles.repo    Git URL of the user's dotfiles repository. Empty =>
#                         dotfiles are not installed (Omarchy default for this
#                         feature: no repo, no work).
#   disk.dotfiles.branch  Branch/tag to check out. Empty => "main".
#
# The repository is cloned into the target user's home as ~/.dotfiles:
#   /home/<user>/.dotfiles
#
# Cloning is idempotent: an existing clone is fast-forward pulled instead of
# re-cloned. Nothing outside ~/.dotfiles is touched.
#
# Public functions:
#   yaap_dotfiles_clone    <root> <user> <repo> <branch>
#                          Idempotent clone/pull of the dotfiles repo into the
#                          target user's home. Returns 0 if the clone/pull was
#                          attempted (and failed non-fatally); returns 1 on
#                          misuse (empty user or repo).
#   yaap_dotfiles_status   <root> <user>
#                          Prints "installed" when ~/.dotfiles exists in the
#                          target user's home, "missing" otherwise.
#   yaap_target_test       <root> <expr> [args...]
#                          Runs a `bash -c "<expr>" _ <args...>` test inside the
#                          target via arch-chroot (use $1..$n in <expr>).
#   yaap_dotfiles_clone_cmd <root> <dst> <repo> <branch>
#   yaap_dotfiles_pull_cmd <root> <dst> <branch>
#                          The chrooted git actions. Override these (and
#                          yaap_target_test) only in test harnesses — the
#                          default implementation runs `arch-chroot`.

# yaap_target_test <root> <expr> [args...]
#   Run a test expression inside the target's filesystem.
yaap_target_test() {
    local root="$1"; shift
    arch-chroot "$root" bash -c "$1" _ "${@:2}"
}

# yaap_dotfiles_clone_cmd <root> <dst> <repo> <branch>
#   Default: clone the repo into the target. Override for test harnesses.
yaap_dotfiles_clone_cmd() {
    local root="$1" dst="$2" repo="$3" branch="$4"
    arch-chroot "$root" git clone --depth 1 --branch "$branch" "$repo" "$dst" \
        >>"$YAAP_LOG" 2>&1
}

# yaap_dotfiles_pull_cmd <root> <dst> <branch>
#   Default: fast-forward pull an existing clone in the target.
yaap_dotfiles_pull_cmd() {
    local root="$1" dst="$2" branch="$3"
    arch-chroot "$root" git -C "$dst" pull --ff-only origin "$branch" \
        >>"$YAAP_LOG" 2>&1
}

# yaap_dotfiles_clone <root> <user> <repo> <branch>
#   Idempotently provision the dotfiles repo into the target user's home.
#   Returns 0 if the clone/pull was attempted (success or non-fatal failure).
yaap_dotfiles_clone() {
    local root="$1" user="$2" repo="$3" branch="$4"
    local home dst
    [ -n "$user" ] || return 1
    [ -n "$repo" ] || return 1
    home="$root/home/$user"
    dst="$home/.dotfiles"
    if yaap_target_test "$root" '-d "$1"' "$dst/.git"; then
        log_info "dotfiles already present at $dst; pulling"
        yaap_dotfiles_pull_cmd "$root" "$dst" "$branch" \
            || log_warn "dotfiles pull failed (non-fatal)"
    else
        log_info "cloning dotfiles from $repo (branch=$branch) -> $dst"
        yaap_dotfiles_clone_cmd "$root" "$dst" "$repo" "$branch" \
            || log_warn "dotfiles clone failed (non-fatal)"
    fi
    return 0
}

# yaap_dotfiles_status <root> <user>
#   Print the dotfiles state of the target user's home: "installed" or "missing".
yaap_dotfiles_status() {
    local root="$1" user="$2" dst
    [ -n "$user" ] || { echo "missing"; return 1; }
    dst="$root/home/$user/.dotfiles"
    if yaap_target_test "$root" '-d "$1"' "$dst/.git"; then
        echo "installed"
    else
        echo "missing"
    fi
}
