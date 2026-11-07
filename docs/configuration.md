# Configuration reference

The installer is driven by `install-config.yaml`. On the live system it defaults
to `/etc/yaaplinux/install-config.yaml` (`YAAP_CONFIG`); if it lacks a `version`
key it is seeded from `assets/install-config.yaml`. The config is copied into the
target at stage 50 and re-copied at stage 90.

The file is both **input** and **working state**: `lib/detect.sh` writes
`hardware.*` on every run, and stages write runtime keys (`storage.*`,
`disk.luks.*`, UUIDs, `desktop.env.*`, …) back into it via `cfg_set`. See
[Configuration](configuration.md) in the index for the read/write contract.

## Reading the table

The **Source** column classifies each key:

| Source | Meaning |
| --- | --- |
| **Config** | User/template-set. Read by the installer; not overwritten by detection (unless noted). |
| **Detected** | Written by `lib/detect.sh` from a live hardware probe on every run. Some are confirmed with the user. |
| **Runtime** | Written by a stage during install (derived/computed values). |

Where a key is *Detected* it is still present in the file so it can be inspected
and hand-edited, but the next run's detection will recompute it.

---

## `version`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `version` | Config schema version. Its presence (`cfg_has version`) decides whether `install.sh` seeds the config from the template. | integer | `2` | Config (template) |

## `meta`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `meta.created` | Seeded creation timestamp. | RFC 3339 string | `"2026-10-31T12:00:00Z"` | Config (template) |
| `meta.installer_version` | Installer version stamp. | string | `"2.0"` | Config (template) |
| `meta.stage` | Human-readable resumption cursor; set to the *next* phase label at the end of each stage. | string label | `"preflight"` | Runtime (stages) |

## `profile`
| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `profile` | Installer profile: full desktop or bare server. | `desktop` (default) | `desktop` | Config |
| | `minimal` | Server-only: the desktop stack (stage 70) is skipped entirely; the system keeps base + drivers/media. | | |


Populated by `detect_all` on every run; user-confirmable values are detected then
offered for confirmation.

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `hardware.firmware` | Boot firmware interface. | `uefi` / `bios` | `uefi` | Detected (confirmable) |
| `hardware.secure_boot.setup_mode` | EFI `SetupMode` flag. | bool | `false` | Detected |
| `hardware.secure_boot.enrolled` | Whether Secure Boot keys are enrolled. | bool | `false` | Detected / Runtime (`sbctl`) |
| `hardware.secure_boot.strategy` | Secure Boot signing strategy (stage 80). | `sbctl` / `systemd` / `none` | `sbctl` | Config |
| `hardware.secure_boot.tpm2_auto_unlock` | TPM2 auto-unlock for LUKS (read by stage 10). | bool | `false` | Config |
| `hardware.cpu.vendor` | CPU vendor. | `intel` / `amd` | `amd` | Detected |
| `hardware.cpu.microcode` | Microcode package installed. | `intel-ucode` / `amd-ucode` | `amd-ucode` | Detected |
| `hardware.gpu.primary` | Primary GPU. | `intel` / `amd` / `nvidia` / `hybrid` / `unknown` | `amd` | Detected |
| `hardware.gpu.intel_gen` | Intel generation class. | `broadwell_plus` / `legacy` / `null` | `null` | Detected |
| `hardware.gpu.vaapi_driver` | VA-API driver chosen by the hardware matrix. | string | `libva-mesa-driver` | Detected |
| `hardware.gpu.needs_linux_firmware_intel` | Intel VA-API needs the firmware subpackage. | bool | `false` | Detected |
| `storage.type` | Target disk interface. | `nvme` / `sata` / `mmc` | `nvme` | Detected |
| `storage.device` | Target disk device. | `/dev/XXX` | `""` | Detected / `--target` |
| `storage.rotational` | HDD (`true`) vs SSD (`false`). | bool | `false` | Detected |
| `peripherals.bluetooth` | Bluetooth present. | bool | `true` | Detected |
| `peripherals.fingerprint` | Fingerprint reader present. | bool | `false` | Detected |
| `peripherals.webcam` | Webcam present. | bool | `true` | Detected |
| `peripherals.printer` | Printer present. | `yes` / `no` / `unknown` | `unknown` | Detected (conditional) |
| `peripherals.scanner` | Scanner present. | `yes` / `no` / `unknown` | `unknown` | Config (not auto-detected) |
| `peripherals.touchpad` | Touchpad present. | bool | `true` | Detected |
| `peripherals.tablet` | Tablet/pen present. | bool | `false` | Detected |
| `peripherals.modem` | Modem present. | bool | `false` | Config (not auto-detected) |
| `battery` | Laptop battery present. | bool | `true` | Detected |

## `disk`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `disk.layout` | Partition/filesystem layout strategy. | `btrfs_subvolumes` | `btrfs_subvolumes` | Config |
| `disk.luks.enabled` | Encrypt the root partition with LUKS2. | bool | `true` | Config |
| `disk.luks.cipher` | LUKS2 cipher. | string | `aes-xts-plain64` | Config |
| `disk.luks.key_size` | LUKS2 key size in bits. | integer | `512` | Config |
| `disk.luks.mapper_name` | `/dev/mapper/` name for the container. | string | `cryptroot` | Config |
| `disk.luks.tpm2_auto_unlock` | Declared TPM2 auto-unlock (note: stage 10 actually reads `hardware.secure_boot.tpm2_auto_unlock`). | bool | `false` | Config |
| `disk.luks.tpm2_wipe_password_slot` | After TPM2 enrolment, wipe the LUKS password slot so TPM is the only unlock. Dangerous — a TPM state change (firmware update, Secure Boot policy change) can make the disk unrecoverable. Off by default; prefer wiping manually after a verified first boot. | bool | `false` | Config |
| `disk.lvm.enabled` | Use LVM (discouraged; no active code path). | bool | `false` | Config |
| `disk.lvm.rationale` | Why LVM is discouraged. | string | `"discouraged unless separate encrypted swap partition wanted"` | Config |
| `disk.swap.style` | Swap strategy (drives fstab + power). | `zram_plus_file` / `partition` / `none` | `zram_plus_file` | Config |
| `disk.swap.zram_percent` | zram size percentage. | integer | `50` | Config (not wired) |
| `disk.swap.file_size_gb` | btrfs swapfile size (GiB). | integer | `8` | Config |
| `disk.swap.hibernation` | Enable the hibernation swapfile + resume. | bool | `false` | Config |
| `disk.swap.swap_subvolume` | Subvolume holding the swapfile. | string | `@swap` | Config |
| `disk.swap.resume_offset` | btrfs `resume_offset` (computed after the swapfile is created). | integer | `0` | Runtime (stage 20) |
| `disk.subvolumes` | btrfs subvolumes to create. | sequence | `@`, `@home`, `@swap`, `@snapshots` | Config |
| `disk.snapshots.enabled` | Enable filesystem snapshots. | bool | `true` | Config |
| `disk.snapshots.tool` | Snapshot tool. | `snapper` / `timeshift` | `snapper` | Config |
| `disk.snapshots.boot_integration` | Snapshot boot integration. | bool | `true` | Config (not wired) |
## `disk.dotfiles`
| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `disk.dotfiles.repo` | Git repository cloned into the target user's home as `~/.dotfiles` (Omarchy-style config layer). Leave empty to skip. | URL string | `""` (none) | Config |
| `disk.dotfiles.branch` | Branch/tag checked out from the dotfiles repository. | string | `main` | Config |


## `kernel`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `kernel.primary` | Primary kernel (installed + used for the UKI). | string | `linux-zen` | Config |
| `kernel.fallback` | Fallback/recovery kernel. | string | `linux` | Config |
| `kernel.firmware_packages` | Firmware packages (declared; microcode is actually handled via `hardware.cpu.microcode`). | sequence | `[]` | Config |

## `bootloader`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `bootloader.uefi` | UEFI bootloader strategy. Both code paths install systemd-boot; GRUB is only used on BIOS firmware. | `systemd-boot` / `grub` | `systemd-boot` | Config |
| `bootloader.unified_kernel_images` | Build UKIs (also grows the ESP to 1 GiB). | bool | `true` | Config |
| `bootloader.ukify_sign` | Declared ukify signing flag (not read by stage 80). | bool | `false` | Config |
| `bootloader.bios_warning_acknowledged` | BIOS-path acknowledgement (set after the user confirms). | bool | `false` | Runtime (stage 80) |

## `login`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `login.manager` | Display-manager strategy. | `greetd` / `tty_autologin` | `greetd` | Config |
| `login.greeter` | Greeter for the greetd path. | string | `tuigreet` | Config |
| `login.autologin_user` | Autologin user (declared; the tty path autologins `root`). | string / `null` | `null` | Config |

## `network`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `network.manager` | Network manager (hardcoded to NetworkManager in stage 50). | string | `NetworkManager` | Config |
| `network.wifi_backend` | WiFi backend (hardcoded to iwd in stage 50). | string | `iwd` | Config |

## `locale`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `locale.lang` | System locale. | string | `en_US.UTF-8` | Config |
| `locale.keymap` | Console keymap. | string | `us` | Config |
| `locale.timezone` | Timezone. | string | `UTC` | Config |

## `system`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `system.hostname` | Hostname (prompts when empty, unless unattended). | string | `yaaplinux` | Config |

## `user`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `user.name` | Daily-use username (prompts when empty, unless unattended). | string | `""` | Config |
| `user.shell` | User shell. | string | `/bin/bash` | Config |
| `user.groups_extra` | Extra supplementary groups beyond the GPU/printer-derived set. | sequence | `[]` | Config |

## `desktop`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `desktop.compositor` | Compositor (hardcoded to hyprland in stage 70). | string | `hyprland` | Config |
| `desktop.hyprland_config` | Hyprland config format. | `lua` | `lua` | Config |
| `desktop.terminal` | Terminal (hardcoded to kitty in stage 70). | string | `kitty` | Config |
| `desktop.launcher` | Application launcher. | string | `fuzzel` | Config |
| `desktop.notifications` | Notification daemon. | string | `mako` | Config |
| `desktop.locker` | Screen locker. | string | `hyprlock` | Config |
| `desktop.wallpaper` | Wallpaper tool. | string | `hyprpaper` | Config |
| `desktop.browser` | Browser. | `firefox` / `librewolf` / `both` | `firefox` | Config |
| `desktop.portal` | Desktop portal. | string | `xdg-desktop-portal-hyprland` | Config |
| `desktop.env` | Session env hints (populated at runtime by driver/GStreamer tuning; emitted into the Wayland session env). | mapping | `{}` | Runtime (stage 60) |

## `media`

All `media.*` toggles below are opt-in features (default off unless shown).

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `media.codecs` | Install the codec stack (`ffmpeg` + GStreamer). | bool | `true` | Config |
| `media.gstreamer_ugly` | Include `gst-plugins-ugly` (opt-out available). | bool | `true` | Config |
| `media.vaapi` | VA-API enabled (drivers are still installed per the detected GPU). | bool | `true` | Config |
| `media.diagnostics` | Run `vainfo`/`vdpauinfo` and apply GStreamer tuning. | bool | `true` | Config |
| `media.multilib` | Enable multilib (triggers a full `-Syu` sync). | bool | `false` | Config |
| `media.printing` | Install the CUPS printing stack. | bool | `false` | Config |
| `media.print_hp` | Install `hplip` for HP printers. | bool | `false` | Config |
| `media.scanning` | Install the SANE scanning stack. | bool | `false` | Config |
| `media.steam` | Install `steam-devices`. | bool | `false` | Config |

## `power`

| Key | Meaning | Allowed values | Default | Source |
| --- | --- | --- | --- | --- |
| `power.daemon` | Laptop power daemon — mutually exclusive with `tlp`; only one is installed. | `power-profiles-daemon` / `tlp` / `none` | `power-profiles-daemon` | Config |

---

## Runtime-injected keys

These are **not** in the seed template; stages create/overwrite them via
`cfg_set` during a run. They are shown here for completeness.

| Key | Written by | Meaning |
| --- | --- | --- |
| `storage.root_partition` | stage 10 | Resolved root partition path. |
| `disk.luks.open_mapper` | stage 10 | Opened LUKS mapper name (`""` when LUKS off). |
| `disk.luks.unattended` | stage 10 | Set `true` when an unattended passphrase was generated. |
| `disk.swap.resume_offset` | stage 20 | btrfs `resume_offset` for the swapfile. |
| `storage.root_uuid` | stage 30 | btrfs root UUID. |
| `storage.esp_uuid` | stage 30 | ESP UUID. |
| `bootloader.cmdline` | stage 80 | Assembled UKI/kernel command line. |
| `bootloader.bios_warning_acknowledged` | stage 80 | Set `true` after BIOS-path acknowledgement. |
| `hardware.secure_boot.enrolled` | stage 80 | Set `true` after a successful `sbctl` enrolment. |
| `desktop.env.*` | stage 60 | Env hints such as `LIBVA_DRIVER_NAME` and `GST_PLUGIN_FEATURE_RANK`. |
