# Desktop Stack (Hyprland 0.56 + Base16 Theming)

This document describes the desktop the installer builds: the **Hyprland 0.56
Lua compositor stack** (stage 70), the **Base16 cross-layer theming**
(`assets/hypr-theme.sh`), and the **browser / Wayland environment wiring**.

Everything here is grounded in `stages/70-desktop.sh`, `assets/hyprland.lua`,
and `assets/hypr-theme.sh`.

---

## 1. The Hyprland 0.56 desktop (stage 70)

`run_stage()` order: `install_compositor` → `install_session_components` →
`install_browser` → `write_hyprland_config` → `write_session_env` →
`register_session`.

### 1.1 Compositor

```bash
pkg_install hyprland
```

### 1.2 Session components

Installed as one declarative set (`install_session_components`):

| Role | Package(s) |
|---|---|
| Terminal | `kitty` |
| Launcher / dmenu / drun | `fuzzel` |
| Notifications | `mako` |
| Locker | `hyprlock` |
| Wallpaper | `hyprpaper` |
| Status bar | `waybar` |
| Idle/inhibit daemon | `hypridle` |
| Portal (screenshots, file picker) | `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-gtk` |
| Polkit agent | `hyprpolkitagent` |
| Clipboard | `wl-clipboard`, `cliphist` |
| Screenshot / annotate | `grim`, `slurp`, `satty` |
| Brightness / volume | `brightnessctl`, `pavucontrol` |
| File manager | `nautilus` |
| Theme GUI / GTK / cursors / Qt | `nwg-look`, `adw-gtk-theme`, `bibata-cursor-theme`, `qt6ct` |

If `media.steam == true`, `steam-devices` is additionally installed.

### 1.3 Browser — `install_browser`

Chosen by `desktop.browser`:

| Value | Action |
|---|---|
| `firefox` (default) | `pkg_install firefox` |
| `librewolf` | `pkg_install_aur librewolf` (AUR; **non-fatal** — warns if the helper is unavailable) |
| `both` | installs `firefox` **and** `pkg_install_aur librewolf` |
| *(anything else)* | `pkg_install firefox` |

> `librewolf` is an AUR package. The **live ISO ships no AUR helper** (see
> `iso/packages.x86_64`), and `pkg_install_aur` degrades to a warning if no
> helper is present — so a `librewolf`/`both` choice only fully resolves once an
> AUR helper exists on the target.

### 1.4 Hyprland Lua config — `write_hyprland_config`

For the daily-use user only (skips with a warning if no user is set):

- Copies `assets/hyprland.lua` → `~/.config/hypr/hyprland.lua`.
- Backs up a legacy `hyprland.conf` to `~/.config/hypr/hyprland.conf.bak` **if
  the asset ships one** (none ships by default).
- Creates an empty `~/.config/hypr/theme.lua` placeholder (filled later by
  `hypr-theme.sh`).

### 1.5 The `hyprland.lua` file (`assets/hyprland.lua`)

The config targets **Hyprland 0.56.x** with the Lua API. The file header is
explicit about verification status:

- The **only** API form verified this cycle is the environment setter
  `hl.env("KEY", "value")`.
- The section / sub-section syntax mirrors the legacy hyprlang layout and the
  "Lua-ification" announcement, but exact nested-table parity for 0.56 is an
  **open item** (spec §15 #8) to verify against a live 0.56 shell.

Contents:

- **Environment (verified API):**
  ```lua
  hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
  hl.env("MOZ_ENABLE_WAYLAND", "1")
  hl.env("XDG_SESSION_TYPE", "wayland")
  hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
  ```
- **Theme palette load:** `pcall(function() dofile("$HOME/.config/hypr/theme.lua") end)`
  — wrapped in `pcall` so a missing theme never blocks the session; falls back
  to `$HOME` because `hp.configDir` is unverified.
- **Layout:** `master` layout (`mfact = 0.55`); `general` (gaps 4/8, 2px
  border, accent from `THEME.accent`); `decoration` (rounding 8, blur);
  `animations` (easeOutCubic).
- **Bindings (`SUPER` = mod):** `Return`→kitty, `D`→fuzzel launcher, `space`→
  fuzzel drun, `C`→fuzzel run, `X`→grim+satty screenshot, `L`→hyprlock,
  workspace 1–9 + `movetoworkspace`, media-key volume/brightness via `wpctl` /
  `brightnessctl`.
- **Window rules:** floating kitty, special workspace for modals, kitty opacity.

> Hyprland 0.56's Lua API for sourcing *additional* fragments is unverified this
> cycle; extra fragments go in `~/.config/hypr/hyprland.d/` and are to be wired
> up once the sourcing call is confirmed.

### 1.6 Wayland session environment — `write_session_env`

Writes `/etc/profile.d/yaap-wayland.sh`:

```sh
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORMTHEME=qt6ct
```

It then appends every entry in the `desktop.env` YAML mapping (read with
`cfg_map`) — i.e. the driver/gstreamer env hints set in stage 60
(`LIBVA_DRIVER_NAME`, `GST_PLUGIN_FEATURE_RANK`). Values containing spaces are
quoted.

### 1.7 Session registration — `register_session`

Writes `/usr/share/wayland-sessions/hyprland.desktop`:

```ini
[Desktop Entry]
Name=Hyprland
Exec=Hyprland
Type=Application
DesktopNames=Hyprland
```

This makes Hyprland selectable at the login manager (greetd/twigreet, see
[Bootloader & Security](bootloader-and-security.md)).

---

## 2. Base16 theming (`assets/hypr-theme.sh`)

`hypr-theme.sh` generates a **coherent palette across every layer from a single
Base16 scheme** (spec §9.4).

### 2.1 Usage

```bash
assets/hypr-theme.sh list                          # list available schemes
assets/hypr-theme.sh apply <scheme> [--light] [--accent <hex>]
```

- Reads `assets/base16/<scheme>.yaml` (keys `base00`..`base0F`).
- `--light` flips the GTK color-scheme to `prefer-light`.
- `--accent <hex>` overrides `base0A` (the accent colour).
- Writes per-tool configs under the target user's `~/.config`. Apps needing a
  restart are reported; live reload is `hyprctl reload` / `makoctl reload`.

### 2.2 Files written by `hypr-theme apply`

| File | Layer |
|---|---|
| `~/.config/hypr/theme.lua` | `THEME = { base, base1, base2, base3, fg, accent }` table (loaded by `hyprland.lua`) |
| `~/.config/kitty/theme.conf` | terminal 16-colour palette |
| `~/.config/fuzzel/fuzzel.ini` | launcher colours |
| `~/.config/mako/config` | notification colours |
| `~/.config/waybar/style.css` | status bar colours |
| `~/.config/gtk-3.0/gtk.css` | GTK 3 `@define-color` palette |
| `~/.config/gtk-4.0/gtk.css` | GTK 4 `@define-color` palette (+ `gsettings` color-scheme) |
| `~/.config/qt6ct/qt6ct.conf` + `colors/<scheme>.conf` | Qt6 (qt6ct) colour scheme + Bibata cursor |

Colour mapping (from the Base16 scheme): `base` = `base00` (background),
`fg` = `base05` (foreground), `accent` = `base0A`.

Cursors: if a Bibata theme is installed, `gsettings set
org.gnome.desktop.interface cursor-theme Bibata-Modern-Classic`.

### 2.3 Shipped scheme — Catppuccin Mocha (`assets/base16/catppuccin-mocha.yaml`)

The only Base16 scheme bundled:

| Key | Hex | Role | Key | Hex | Role |
|---|---|---|---|---|---|
| `base00` | `1e1e2e` | background | `base08` | `f38ba8` | red |
| `base01` | `313244` | subtle bg | `base09` | `fab387` | peach |
| `base02` | `45475a` | surface | `base0A` | `f9e2af` | yellow (accent) |
| `base03` | `585b70` | subtext | `base0B` | `a6e3a1` | green |
| `base04` | `6c7086` | text | `base0C` | `94e2d5` | teal |
| `base05` | `cdd6f4` | foreground | `base0D` | `89b4fa` | blue |
| `base06` | `a6adc8` | subtext light | `base0E` | `cba6f7` | mauve |
| `base07` | `f5e0dc` | text light | `base0F` | `f2cdcd` | rosewater |

Example:

```bash
assets/hypr-theme.sh apply catppuccin-mocha                 # dark (default)
assets/hypr-theme.sh apply catppuccin-mocha --light --accent 89b4fa
```
