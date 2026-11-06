# Stages

The installer runs ten stages in numeric order. Each stage file defines a
`STAGE_ID` and a `run_stage` function; `install.sh` sources the file and calls
`run_stage`, then marks the stage complete via a checkpoint. This document
describes what each stage actually does, in execution order, grounded in the
code under `stages/`.

The pipeline:

```
00-preflight → 10-partition → 20-format → 30-mount → 40-pacstrap
             → 50-base-config → 60-drivers-media → 70-desktop
             → 80-bootloader → 90-postinstall
```

---

## 00-preflight

Pre-mutation checks (any *hard* failure aborts before a disk is touched). Sets
`meta.stage=partitioning` on success.

- `check_root` — must run as root (`die` otherwise).
- `check_arch_live` — warns if `/etc/arch-release` / `/run/archos` are absent;
  prompts to continue unless unattended.
- `check_internet` (**hard**) — reachability via `ping` (1.1.1.1, 8.8.8.8) or
  `curl https://archlinux.org`.
- `check_clock` (**hard**) — requires `timedatectl` NTP synchronisation; tries
  `set-ntp` then re-checks.
- `resolve_target_disk` (**hard**) — uses `--target`/`storage.device`, else
  `detect_storage`, else prompts; refuses to run unattended without a disk.
- `check_disk_size` (**hard**) — target must be ≥ 32 GiB.
- `check_firmware_branch` — `detect_firmware`; confirms UEFI/BIOS (BIOS ⇒
  Secure Boot unavailable); confirms unless unattended.
- `check_secure_boot_preflight` — `detect_secure_boot_state`; logs `setup_mode`.
- `check_battery` — `detect_peripherals`; logs laptop/desktop.
- `check_ram` (**hard**) — ≥ 768 MiB required; < 2048 MiB warns.
- `check_mirrorlist` — refreshes `/etc/pacman.d/mirrorlist` via `reflector` if
  present (non-fatal).

## 10-partition *(destructive)*

GPT layout + optional LUKS2 container. Sets `meta.stage=format`. Does **not**
format or mount.

- Wipes (`sgdisk --zap-all`, zero first 2 GiB) and creates a fresh GPT
  (`sgdisk -o`).
- **ESP** (partition 1, type `ef00`): `esp_size_for` ⇒ 1024 MiB when
  `bootloader.unified_kernel_images`, else 512 MiB.
- **BIOS boot** (type `ef02`) only on BIOS firmware; then root starts at
  partition 3, else partition 2.
- **Root** — the remainder, type `8300`. `partprobe` + `sync`; resolves the
  partition path (`${dev}pN` or `${dev}N`) into `storage.root_partition`.
- **LUKS2** (if `disk.luks.enabled`) — `setup_luks`: `cryptsetup luksFormat
  --type luks2` with `disk.luks.cipher` (default `aes-xts-plain64`),
  `disk.luks.key_size` (default 512), PBKDF `argon2id`, mapper
  `disk.luks.mapper_name` (default `cryptroot`), opened as
  `/dev/mapper/<mapper>` and recorded in `disk.luks.open_mapper`.
  - **Unattended**: generates a passphrase, persists it to
    `YAAP_LUKS_PASSPHRASE_FILE`, and sets `disk.luks.unattended=true` (it is
    published to the ESP in stage 30).
  - **TPM2 auto-unlock**: if `hardware.secure_boot.tpm2_auto_unlock` and the user
    confirms, `systemd-cryptenroll --tpm2-device=auto` (warns on failure); the
    password slot is kept unless `disk.luks.tpm2_wipe_password_slot` is true.
  - `luksOpen` is non-interactive in unattended mode (keyfile from
    `YAAP_LUKS_PASSPHRASE_FILE`).

## 20-format *(destructive)*

Filesystems and btrfs subvolumes. Sets `meta.stage=mount`.

- Formats the ESP (partition 1) FAT32 (`mkfs.fat -F32`).
- Formats btrfs (`mkfs.btrfs -L archroot`) on the root partition, or the LUKS
  mapper when encryption is on.
- `btrfs_create_subvolumes` — mounts the btrfs device on a temp dir with
  `compress=zstd:3` and creates the subvolumes listed in `cfg_array
  disk.subvolumes` (default `@ @home @swap @snapshots`).
- If `disk.swap.hibernation` is true, `create_swapfile` builds a CoW-disabled
  btrfs swapfile (`btrfs filesystem mkswapfile`, size `disk.swap.file_size_gb`,
  default 8 GiB) and records `disk.swap.resume_offset` from
  `btrfs inspect-internal map-swapfile`.
- The ESP is intentionally **not** mounted here (it is mounted in stage 30).

## 30-mount

Mounts the btrfs subvolumes and ESP at their final locations so pacstrap/chroot
operate on the target tree. Sets `meta.stage=pacstrap`.

- Mounts the root subvolume `@` → `TARGET_ROOT` with
  `noatime,compress=zstd:3,space_cache=v2`.
- Bind-mounts `@home`, `@swap`, `@snapshots` into place.
- Mounts the ESP → `/boot/efi`.
- **Unattended LUKS**: copies the staged passphrase to
  `/boot/efi/keys/<mapper>.key` (chmod 600) so the system is unlockable after
  reboot.
- `store_uuids` — records `storage.root_uuid` and `storage.esp_uuid`
  (`blkid`), then `write_fstab` generates `/etc/fstab` (btrfs subvol entries for
  `/`, `/home`, `/swap`, `/.snapshots`; ESP as vfat; and a `/swap/swap` line when
  `disk.swap.hibernation` with `style=zram_plus_file`).

## 40-pacstrap

Installs the base system onto the target. Sets `meta.stage=base-config`. Uses
`pacstrap` directly (not `pkg_install`) because the target is not yet a system.

- `pacman-key --init/--populate archlinux`, then
  `pacstrap -K --needed` the payload: `base base-devel linux-zen linux
  linux-firmware btrfs-progs dosfstools exfatprogs ntfs-3g networkmanager iwd
  sudo vim nano man-db man-pages`.
- `genfstab -U` regenerates `/etc/fstab` from the live mounts, then
  `append_swap_fstab` re-adds `/swap/swap` for hibernation (genfstab only sees
  mountpoints, not the swapfile).

## 50-base-config

Chroot configuration. Persists the installer into the target. Sets
`meta.stage=drivers-media`.

- `configure_locale` — writes `/etc/locale.gen` from `locale.lang`, runs
  `locale-gen`, sets `/etc/locale.conf`, and `locale.keymap` into
  `/etc/vconsole.conf` (`loadkeys`).
- `configure_clock` — `set-timezone` from `locale.timezone`, then
  `hwclock --systohc`.
- `configure_hostname` — `system.hostname` (default/prompt `yaaplinux`); writes
  `/etc/hostname` and `/etc/hosts`.
- `install_microcode` — installs `hardware.cpu.microcode` (`intel-ucode` /
  `amd-ucode`).
- `configure_initramfs` — writes `mkinitcpio.conf` with hooks
  `base systemd autodetect modconf block keymap consolefont keyboard btrfs`,
  adding `resume` when hibernation is on and `sd-encrypt` when LUKS is on;
  writes `initramfs.conf.d/resume.conf` (`RESUME`/`RESUME_OFFSET`) when
  hibernation; runs `mkinitcpio -P`.
- `create_user` — `user.name` (prompt unless unattended; unattended skips if
  empty), `useradd -m -s <user.shell>`, `passwd` (random when unattended).
  Supplementary groups: `wheel` always, plus `video render audio input storage`
  when the GPU is known, `lp` if a printer is present, `scanner` if a scanner is
  present, plus `cfg_array user.groups_extra`.
- `configure_sudo` — writes `sudoers.d/00-wheel-nopasswd_prompt`
  (`%wheel ALL=(ALL:ALL) ALL`, 0440) and validates it with `visudo -cf`.
- `configure_network` — `pkg_install networkmanager iwd`, enables
  `NetworkManager.service`, and writes `NetworkManager/conf.d/10-iwd.conf`
  (`WifiBackend=iwd`).
- `copy_installer_artifacts` — copies the config to
  `/etc/yaaplinux/install-config.yaml`, the installer tree to `/opt/yaaplinux`,
  and `install_hooks` copies `assets/hooks/*.hook` to
  `/etc/pacman.d/hooks/`.

## 60-drivers-media

Codecs, the VA-API driver matrix, universal drivers, multilib, printing,
scanning, and GStreamer tuning. Largely declarative: build an install set, run
conflict guards, install, verify. Sets `meta.stage=desktop`.

- `build_install_set` — seeds `YAAP_INSTALL_SET`.
- `apply_multilib_if_requested` — `media.multilib` ⇒ `repo_enable_multilib`
  (the sanctioned `-Syu`; non-fatal on failure).
- `install_universal_drivers` — audio (`pipewire` stack, `sof-firmware`),
  filesystems, `lm_sensors`, `smartmontools` (+`nvme-cli` on nvme) **always**;
  gated peripherals (`bluez`/`libinput`/`v4l-utils`/`libwacom`/`fprintd`/
  `modemmanager`); and on battery, exactly one power daemon per
  `power.daemon` (`power-profiles-daemon` / `tlp` / `none`).
- `install_codecs` — `media.codecs` ⇒ `ffmpeg` + GStreamer stack (skip
  `gst-plugins-ugly` when `media.gstreamer_ugly=false`); `media.diagnostics` ⇒
  `libva-utils vdpauinfo`.
- `install_vaapi_drivers` — per `hardware.gpu.primary`: `amd` ⇒
  `mesa libva-mesa-driver`; `intel broadwell_plus` ⇒ `+intel-media-driver` and
  `LIBVA_DRIVER_NAME=iHD` (warns if `linux-firmware-intel` is missing on
  Skylake+); `intel legacy` ⇒ `+libva-intel-driver`; `nvidia` ⇒
  `nvidia-utils libva-nvidia-driver` and `LIBVA_DRIVER_NAME=nvidia`. Env hints
  are written to `desktop.env` via `write_env_hint`; `assert_video_group`
  ensures the user is in `video`.
- `install_gstreamer_tuning` — `media.diagnostics` ⇒ NVIDIA decoder feature
  rank into `desktop.env.GST_PLUGIN_FEATURE_RANK`.
- `install_printing` — `media.printing` ⇒ CUPS stack; `media.printing_hp` ⇒
  `hplip`; `pkg_conflict_guard hplip foo2zjs-nightly`; enables `cups` +
  `avahi-daemon`.
- `install_scanning` — `media.scanning` ⇒ SANE stack; enables `ipp-usb`.
- `run_diagnostics` — `media.diagnostics` ⇒ `vainfo` captured to
  `/var/log/yaaplinux/vainfo.log`; demotes AV1 GStreamer decoders to `NONE` when
  no `VAProfileAV1` is reported.

## 70-desktop

Hyprland desktop, components, theming wiring, and session registration. Sets
`meta.stage=bootloader`.

- `install_compositor` — `pkg_install hyprland`.
- `install_session_components` — terminal/launcher/notification/lock/wallpaper/
  panel/portal/polkit/clipboard/screenshot/utility set: `kitty fuzzel mako
  hyprlock hyprpaper waybar hypridle xdg-desktop-portal-hyprland
  xdg-desktop-portal-gtk hyprpolkitagent wl-clipboard cliphist grim slurp satty
  brightnessctl pavucontrol nautilus nwg-look adw-gtk-theme
  bibata-cursor-theme qt6ct`; plus `steam-devices` when `media.steam`.
- `install_browser` — `desktop.browser`: `firefox` (installed), `librewolf`
  (AUR, non-fatal), or `both`.
- `write_hyprland_config` — copies `assets/hyprland.lua` to
  `~/.config/hypr/hyprland.lua` for the user and creates a `theme.lua`
  placeholder.
- `write_session_env` — writes `/etc/profile.d/yaap-wayland.sh` with the
  `XDG_*`/`MOZ_ENABLE_WAYLAND`/`QT_QPA_PLATFORMTHEME` exports and every entry of
  `desktop.env` (via `cfg_map`).
- `register_session` — writes
  `/usr/share/wayland-sessions/hyprland.desktop`.

## 80-bootloader

Bootloader, UKIs, Secure Boot, and the login manager. The most fragile stage;
runs last among the mutating stages. Sets `meta.stage=postinstall`.

- Re-resolves firmware via `detect_firmware`, then branches:
  - **BIOS** — `require_bios_ack` (requires `bootloader.bios_warning_acknowledged
    =true` or a prompt; unattended demands the ack), then `install_grub_bios`
    (`grub-install --target=i386-pc` to the bios_grub partition, `grub-mkconfig`).
  - **UEFI** — `install_uefi_boot` (`systemd` + `efibootmgr`); both
    `bootloader.uefi` values route to `install_systemd_boot`.
- `install_systemd_boot` — `bootctl install`; writes `loader/loader.conf`
  (`default arch-linux-zen.conf`, `timeout 5`, `editor off`); creates an
  efibootmgr entry; `build_uki_cmdline` (`root=UUID=… rw quiet splash`, plus
  `resume`/`resume_offset` when hibernation); and if `unified_kernel_images`,
  `build_uki` (via `ukify`, microcode included for Intel/AMD).
- `maybe_sign_secure_boot` — per `hardware.secure_boot.strategy`: `none` skips;
  `sbctl` enrolls in setup/enabled mode; `systemd` is a documented placeholder.
  `sign_sbctl` **gracefully aborts** on failure (`graceful_sb_abort` leaves a
  bootable unsigned system, sets `enrolled=false`), never bricking the install.
- `install_login_manager` — `greetd` ⇒ `greetd tuigreet`, copies
  `greetd-config.toml`, enables `greetd.service`; `tty_autologin` ⇒ a
  `getty@tty1` autologin override for root.

## 90-postinstall

Snapshots, config finalisation, and the report. Non-destructive and safe to
re-run. Sets `meta.stage=done`.

- `configure_snapshots` — `disk.snapshots.enabled` ⇒ `snapper`
  (`createconfig -r /` + enable `snapper-timeline`/`snapper-cleanup` timers) when
  `disk.snapshots.tool=snapper`, or `timeshift` otherwise.
- `finalize_config_copy` — re-copies the config to
  `/etc/yaaplinux/install-config.yaml`.
- `write_report` — the orchestrator's post-install report (also invoked here so
  it is written even when run as part of the stage loop), summarising completed
  stages, detected hardware, configuration, and manual follow-up items.
