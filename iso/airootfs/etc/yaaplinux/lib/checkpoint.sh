#!/usr/bin/env bash
# lib/checkpoint.sh — resumable stage cursors with config-hash invalidation.
#
# Each completed stage writes  $_CK_DIR/<stage>.done  containing:
#   line 1: ISO timestamp
#   line 2: sha256 of the config consumed
# A stage is "done" only if the file exists AND the stored hash matches the
# current config hash — so a config change forces a re-run.

# Checkpoint directory (install.sh exports YAAP_CK_DIR; default if unset).
_CK_DIR="${YAAP_CK_DIR:-/var/lib/yaaplinux/checkpoints}"

stage_is_done() {
    local name="$1"
    local f="$_CK_DIR/$name.done"
    [ -f "$f" ] || return 1
    local stored; stored="$(sed -n '2p' "$f" 2>/dev/null)"
    [ "$stored" = "$(ck_config_hash)" ]
}

stage_complete() {
    local name="$1"
    mkdir -p "$_CK_DIR"
    { date '+%Y-%m-%dT%H:%M:%S%z'; ck_config_hash; } > "$_CK_DIR/$name.done"
    log_debug "checkpoint: $name complete (hash $(ck_config_hash))"
}

stage_begin() {
    local name="$1"
    export YAAP_STAGE="$name"
    log_debug "stage_begin $name"
}

ck_config_hash() {
    local file; file="$(_cfg_path)"
    if [ -f "$file" ]; then sha256sum "$file" | awk '{print $1}'; else echo none; fi
}
