#!/usr/bin/env bash
# stages/70-desktop.sh — Hyprland desktop, components, theming, session wiring
# (spec §9). Installs the compositor stack, writes the Lua config + theme,
# registers the Wayland session, and configures the browser.

STAGE_ID="70-desktop"

run_stage() {
    ensure_chroot
    # profile=minimal: server profile — the desktop stack is not installed.
    if [ "$(cfg_get profile)" = "minimal" ]; then
        log_info "profile=minimal: skipping desktop stage (server profile)"
        cfg_set meta.stage "done"
        return 0
    fi
    install_compositor
    install_session_components
    install_browser
    write_hyprland_config
    write_session_env
    register_session
    cfg_set meta.stage "bootloader"
    log_info "desktop stage complete"
}

ensure_chroot() {
    [ -x "$TARGET_ROOT/usr/bin/pacman" ] || die "target not bootable"
}

install_compositor() {
    log_info "installing Hyprland (compositor)"
    pkg_install hyprland
}

install_session_components() {
    pkg_install \
        kitty \
        fuzzel \
        mako \
        hyprlock hyprpaper \
        waybar hypridle \
        xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
        hyprpolkitagent \
        wl-clipboard cliphist \
        grim slurp satty \
        brightnessctl pavucontrol \
        nautilus \
        nwg-look adw-gtk-theme bibata-cursor-theme \
        qt6ct

    # Optional second browser already handled in install_browser.
    # steam-devices if Steam opted in.
    [ "$(cfg_get media.steam)" = true ] && pkg_install steam-devices
}

install_browser() {
    case "$(cfg_get desktop.browser)" in
        firefox)   pkg_install firefox ;;
        librewolf) pkg_install_aur librewolf || log_warn "librewolf (AUR) unavailable — install manually" ;;
        both)      pkg_install firefox; pkg_install_aur librewolf || log_warn "librewolf (AUR) unavailable" ;;
        *)         pkg_install firefox ;;
    esac
}

write_hyprland_config() {
    local user; user="$(cfg_get user.name)"
    [ -z "$user" ] && { log_warn "no user; skipping per-user Hyprland config"; return 0; }
    local dst="$TARGET_ROOT/home/$user/.config/hypr"
    mkdir -p "$dst"

    # Generate from the asset template, substituting the palette import.
    cp "$ASSETS_DIR/hyprland.lua" "$dst/hyprland.lua"

    # Retain a legacy .conf backup if the asset ships one (none by default).
    [ -f "$ASSETS_DIR/hyprland.conf" ] && cp "$ASSETS_DIR/hyprland.conf" "$dst/hyprland.conf.bak"

    # Theme file (generated later by hypr-theme; create a placeholder import).
    : > "$dst/theme.lua"
    log_info "wrote $dst/hyprland.lua"
}

# Write /etc/profile.d entries for the Wayland session environment.
write_session_env() {
    local f="$TARGET_ROOT/etc/profile.d/yaap-wayland.sh"
    {
        echo "# YaapLinux Wayland session environment"
        echo "export XDG_SESSION_TYPE=wayland"
        echo "export XDG_CURRENT_DESKTOP=Hyprland"
        echo "export XDG_SESSION_DESKTOP=Hyprland"
        echo "export MOZ_ENABLE_WAYLAND=1"
        echo "export QT_QPA_PLATFORMTHEME=qt6ct"
        # Config-driven env hints (LIBVA_DRIVER_NAME, GST_PLUGIN_FEATURE_RANK, ...).
        # desktop.env is a YAML mapping, so read it with cfg_map (KEY=VALUE).
        cfg_map desktop.env | while IFS= read -r kv; do
            [ -z "$kv" ] && continue
            k="${kv%%=*}"; v="${kv#*=}"
            case "$v" in *[\ ]*) v="\"$v\"";; esac
            echo "export $k=$v"
        done
    } > "$f"
    log_info "wrote session env -> $f"
}

register_session() {
    mkdir -p "$TARGET_ROOT/usr/share/wayland-sessions"
    cat > "$TARGET_ROOT/usr/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland compositor
Exec=Hyprland
Type=Application
DesktopNames=Hyprland
EOF
    log_info "registered Hyprland Wayland session"
}
