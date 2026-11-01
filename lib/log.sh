#!/usr/bin/env bash
# lib/log.sh — logging, transcript, and fatal-error handling.
# Sourced by install.sh. Provides:
#   log_init <transcript_path>
#   log_info|log_warn|log_err|log_debug <msg>
#   die <msg>            # log_err + abort with stage context

_log_transcript=""

log_init() {
    _log_transcript="$1"
    mkdir -p "$(dirname "$_log_transcript")" 2>/dev/null || true
    : > "$_log_transcript" 2>/dev/null || true
    export YAAP_STAGE="${YAAP_STAGE:-pre}"
}

_log_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_raw() {
    local lvl="$1"; shift
    local line
    line="[$(_log_ts)] [$lvl] $*"
    case "$lvl" in
        ERR)   printf '\033[31m%s\033[0m\n' "$line" >&2 ;;
        WARN)  printf '\033[33m%s\033[0m\n' "$line" ;;
        DEBUG) [ "${YAAP_DEBUG:-0}" = 1 ] && printf '\033[90m%s\033[0m\n' "$line" ;;
        *)     printf '%s\n' "$line" ;;
    esac
    if [ -n "$_log_transcript" ]; then
        printf '%s\n' "$line" >> "$_log_transcript" 2>/dev/null || true
    fi
}

log_info()  { log_raw INFO  "$@"; }
log_warn()  { log_raw WARN  "$@"; }
log_err()   { log_raw ERR   "$@"; }
log_debug() { [ "${YAAP_DEBUG:-0}" = 1 ] && log_raw DEBUG "$@" || true; }

# die <msg> — record stage, failing command (YAAP_FAIL_CMD), and last 20 lines
# of the file named by YAAP_FAIL_CTX, then abort.
die() {
    local msg="$1"
    log_err "FATAL [$YAAP_STAGE]: $msg"
    if [ -n "${YAAP_FAIL_CMD:-}" ]; then
        log_err "  command: $YAAP_FAIL_CMD"
    fi
    if [ -n "${YAAP_FAIL_CTX:-}" ] && [ -f "${YAAP_FAIL_CTX:-/nonexistent}" ]; then
        log_err "  last output:"
        while IFS= read -r l; do log_err "    $l"; done < <(tail -n 20 "$YAAP_FAIL_CTX" 2>/dev/null)
    fi
    exit 1
}
