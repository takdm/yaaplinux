#!/usr/bin/env bash
# lib/ui.sh — prompt abstraction. Prefers `gum`; falls back to plain read.
# In --unattended mode every prompt returns its default immediately.
#
# Provides:
#   ui_confirm_true <msg>            -> 0 if yes
#   ui_confirm <default true|false> <msg>   -> sets REPLY=yes|no
#   ui_choose <default> <msg> <opt...>      -> sets REPLY=choice
#   ui_input <default> <msg>               -> sets REPLY=text
#   ui_notify <msg>                        -> status line / notify-send

_ui_default() {  # ui_default <default> <msg> -> REPLY (used internally)
    REPLY="$1"
    [ "${YAAP_UNATTENDED:-0}" = 1 ] && return 0
    if command -v gum >/dev/null 2>&1; then
        # gum draws its TUI on stderr and reports via exit status/stdout.
        # Do NOT redirect stderr to /dev/null — that would make prompts
        # invisible while gum still waits for input on /dev/tty.
        local kind="$2"; shift 2
        case "$kind" in
            confirm)
                gum confirm "$*" --default=true >/dev/null && REPLY=yes || REPLY=no
                ;;
            select)
                REPLY="$(gum choose "$@" | head -n1)"
                [ -z "$REPLY" ] && REPLY="$1"
                ;;
            input)
                REPLY="$(gum input --placeholder "$2")"
                [ -z "$REPLY" ] && REPLY="$1"
                ;;
        esac
        return 0
    fi
    # Plain-stdin fallback.
    local ans
    if [ "${kind:-$2}" = confirm ]; then :; fi
    return 1
}

ui_confirm() {
    local def="$1"; local msg="$2"; shift 2
    REPLY="$def"
    [ "${YAAP_UNATTENDED:-0}" = 1 ] && return 0
    if command -v gum >/dev/null 2>&1; then
        local dyes=true
        [ "$def" = false ] && dyes=false
        gum confirm "$msg" --default="$dyes" >/dev/null && REPLY=yes || REPLY=no
        return 0
    fi
    local prompt ans
    prompt="$msg [${def,,}]: "
    read -r -p "$prompt" ans || ans=""
    case "${ans,,}" in
        y|yes) REPLY=yes ;;
        n|no)  REPLY=no ;;
        '')    REPLY="$def" ;;
        *)     REPLY="$def" ;;
    esac
    return 0
}

ui_confirm_true() {  # convenience: true only on yes
    ui_confirm yes "$@"
    [ "$REPLY" = yes ]
}

ui_choose() {
    local def="$1"; local msg="$2"; shift 2
    local opts=("$@")
    REPLY="$def"
    [ "${YAAP_UNATTENDED:-0}" = 1 ] && return 0
    if command -v gum >/dev/null 2>&1; then
        REPLY="$(gum choose "${opts[@]}" | head -n1)"
        [ -z "$REPLY" ] && REPLY="$def"
        return 0
    fi
    printf '%s\n' "$msg"
    local i=1 o
    for o in "${opts[@]}"; do printf '  %d) %s\n' "$i" "$o"; i=$((i+1)); done
    local ans
    read -r -p "Choice [1]: " ans || ans=""
    if [ -z "$ans" ]; then REPLY="${opts[0]}"; return 0; fi
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
        REPLY="${opts[$((ans-1))]}"
    else
        REPLY="$def"
    fi
    return 0
}

ui_input() {
    local def="$1"; local msg="$2"
    REPLY="$def"
    [ "${YAAP_UNATTENDED:-0}" = 1 ] && return 0
    if command -v gum >/dev/null 2>&1; then
        REPLY="$(gum input --placeholder "$msg")"
        [ -z "$REPLY" ] && REPLY="$def"
        return 0
    fi
    local ans
    read -r -p "$msg [$def]: " ans || ans=""
    [ -z "$ans" ] && ans="$def"
    REPLY="$ans"
    return 0
}

ui_notify() {
    local msg="$1"
    log_info "$msg"
    command -v notify-send >/dev/null 2>&1 && notify-send "YaapLinux" "$msg" 2>/dev/null || true
}
