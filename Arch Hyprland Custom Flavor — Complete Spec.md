# YaapLinux Custom Flavor — Complete Installer Specification

**Version:** 2.0
**Date:** November 7, 2026
**Status:** Implemented. This revision describes the installer as shipped —
§15 lists the decisions still open.

---

## Executive Summary

YaapLinux (*Yet Another Archinstall Profile*) is a modular, resumable Bash
installer that produces a Wayland-native Arch Linux desktop built on Hyprland
0.56.x (Lua compositor config). It is also an archiso profile: the same tree
builds the bootable live ISO the installer runs from.

Revision 2.0 replaces the revision-1.0 component model (components/01–04,
flat config keys, in-config checkpoint booleans) with the shipped design:

1. **Staged pipeline** — ten stages (`stages/00`–`90`) driven by `install.sh`.
2. **Nested YAML config** — `install-config.yaml` consumed through
   `cfg_get`/`cfg_set` dotted paths; it is both user input and working state.
3. **File-based checkpoints** — `<stage>.done` stamps tied to a config hash.
4. **Hardware detection** — `lib/detect.sh` probes firmware, CPU, GPU,
   storage, and peripherals on every run and writes the answers into config.
5. **archiso profile** — `iso/` builds the live medium; the installer tree is
   embedded at `/etc/yaaplinux/` inside the airootfs.

The permanent subsystems (encryption, swap/hibernation, snapshots, UKIs,
Secure Boot, theming, unattended operation) are each toggleable from the
config and documented in the numbered sections below.

---

## 1. Design principles

| Principle | Implementation |
|---|---|
| Official repos first | AUR is opt-in and isolated in `pkg_install_aur` (non-fatal). The live ISO ships no AUR helper. |
| Wayland-native first | Hyprland + fuzzel/mako/waybar/kitty/hyprlock; X11 compatibility only where unavoidable. |
| Idempotent | `pacman -S --needed`, idempotent detectors, idempotent subvolume/user/sudoers creation. |
| Fail-fast, recover gracefully | `set -uo pipefail`; `die()` captures stage, failing command, and log context. Secure Boot failure degrades to a bootable unsigned system (§10.3), never bricks. |
| Checkpoint-based | `.done` files + config-hash invalidation (§4.2). |
| No partial upgrades | All installs are `-S --needed`, never `-Sy`. One sanctioned full-sync exception: multilib (§8.4). |
| Values detected, not guessed | Every detector is idempotent; user-confirmable values are detected then confirmed unless `--unattended`. |

---

## 2. Repository and module layout

```
yaaplinux/
├── install.sh          orchestrator: argv, lib loading, config seeding,
│                       resume-point computation, stage loop, post-install report
├── lib/                sourced helper libraries (log, config, checkpoint, ui,
│                       detect, pkg, chroot, dotfiles) + the yaap post-install CLI
├── stages/             one NN-name.sh per pipeline stage; each defines
│                       STAGE_ID and run_stage
├── assets/             seed config template and desktop assets shipped in the
│                       airootfs (hyprland.lua, hypr-theme.sh, base16/,
│                       greetd-config.toml, snapper-root.conf, hooks/)
├── docs/               documentation suite (architecture, stages, configuration,
│                       hardware & media, desktop, bootloader & security,
│                       ISO & usage, troubleshooting)
├── iso/                archiso profile (§11)
└── test-vm.sh          QEMU/KVM boot-test harness for a built ISO (§11.6)
```

**Embedded-copy rule (normative).** The built ISO ships the copy of the tree at
`iso/airootfs/etc/yaaplinux/`, not the source tree. Any code change must be
mirrored into that copy before a release build, and the copy verified with
`diff -rq` against the source. A source-only fix silently never ships.

### 2.1 Library modules and load order

`install.sh` sources the libraries in this fixed order: `log.sh`,
`config.sh`, `checkpoint.sh`, `ui.sh`, `detect.sh`, `pkg.sh`, `chroot.sh`.

| Module | Provides |
|---|---|
| `lib/log.sh` | `log_init`, `log_info/warn/err/debug`, `die` (stage, failing command, last 20 lines of context). |
| `lib/ui.sh` | `ui_confirm*`, `ui_choose`, `ui_input`, `ui_notify` — prefers `gum`, falls back to `read`; every prompt returns its default immediately in `--unattended`. |
| `lib/config.sh` | `cfg_path`, `cfg_get`, `cfg_set`, `cfg_has`, `cfg_array`, `cfg_map`. |
| `lib/checkpoint.sh` | `stage_is_done`, `stage_begin`, `stage_complete`, `ck_config_hash`. |
| `lib/detect.sh` | `detect_firmware`, `detect_secure_boot_state`, `detect_cpu_vendor`, `detect_gpu`, `detect_storage`, `detect_peripherals`, `detect_all`. |
| `lib/pkg.sh` | `pkg_install` (3-retry, chroot-aware), `pkg_install_aur`, `pkg_conflict_guard`, `repo_enable_multilib`. |
| `lib/chroot.sh` | `chroot_run`, `chroot_run_bash`, `chroot_enable` wrappers over `arch-chroot`. |

---

## 3. Configuration contract (`install-config.yaml`)

### 3.1 Location, seeding, and lifecycle

- Live-system config: `/etc/yaaplinux/install-config.yaml` (`YAAP_CONFIG`).
- Seeded from `assets/install-config.yaml` on first run when the file lacks a
  `version` key (`cfg_has version` is the seed test).
- Copied into the target at `/etc/yaaplinux/install-config.yaml` in stage 50
  and re-copied in stage 90.
- The file is both input and working state: `lib/detect.sh` writes
  `hardware.*`/`peripherals.*`/`battery` on every run; stages write
  `storage.*`, `disk.luks.*`, UUIDs, `bootloader.cmdline`, `desktop.env.*`.

### 3.2 Accessors and their limits

`lib/config.sh` is a minimal awk-based nested-YAML accessor. Assumptions:
2-space indentation, scalar leaves on touched paths, no inline comments on
read paths, arrays treated as raw block text.

| Function | Contract |
|---|---|
| `cfg_get <dotted.path>` | Prints the scalar; empty when absent. |
| `cfg_has <dotted.path>` | Exit 0 if the key exists (even when empty). |
| `cfg_set <dotted.path> <value>` | Atomic (temp file + mv). Rewrites a scalar in place or appends a leaf under its parent, converting `env: {}` to block form. **Never mutates arrays.** A `cfg_set` whose parent key is missing from the template is a silent no-op — every dotted path used in code must exist in `assets/install-config.yaml`. |
| `cfg_array <dotted.path>` | Read-only raw sequence body (`disk.subvolumes`, `user.groups_extra`). |
| `cfg_map <dotted.path>` | Read-only `KEY=VALUE` lines of a mapping (`desktop.env`). |

### 3.3 Schema overview

Top-level sections (full per-key reference: `docs/configuration.md`):

| Section | Contents |
|---|---|
| `version`, `meta.*` | Schema version (template `2`), installer version stamp, human resumption cursor. |
| `profile` | `desktop` (default) or `minimal` (server; stage 70 skipped). |
| `hardware.*`, `peripherals.*`, `battery` | Detection output, rewritten every run (`detect_all`). |
| `storage.*` | Detected target disk plus stage-written partition paths and UUIDs. |
| `disk.*` | Layout, LUKS2 parameters, swap strategy + hibernation, subvolumes, snapshots, dotfiles repo. |
| `kernel.*` | Primary (`linux-zen`) and fallback (`linux`) kernels. |
| `bootloader.*` | UEFI strategy, UKI toggle, BIOS acknowledgement, assembled cmdline. |
| `login.*` | Login manager (`greetd` / `tty_autologin`) and greeter (`tuigreet`). |
| `network.*` | NetworkManager + iwd (hardcoded in stage 50). |
| `locale.*`, `system.*`, `user.*` | Locale/keymap/timezone, hostname, user + shell + extra groups. |
| `desktop.*` | Hyprland stack selections plus the runtime `desktop.env` hint mapping. |
| `media.*` | Opt-in gates: codecs, ugly plugins, VAAPI diagnostics, multilib, printing, HP, scanning, steam. |
| `power.daemon` | `power-profiles-daemon` (default) XOR `tlp` XOR `none`, on battery only. |

---

## 4. Orchestrator (`install.sh`)

### 4.1 CLI

Both `--opt=VALUE` and `--opt VALUE` forms are accepted for valued options.

| Flag | Effect |
|---|---|
| `--config PATH` | Use PATH as the active config (default `/etc/yaaplinux/install-config.yaml`). |
| `--target DEV` | Target disk (default: auto-detect; **required** unattended). |
| `--unattended` | Never prompt; every `ui_*` prompt returns its default. |
| `--force` | Skip destructive-stage re-confirmation on resume. |
| `--dry-run` | Log intended mutations, perform none (§4.4). |
| `--debug` | Verbose logging. |

### 4.2 Pipeline and checkpoints

```text
STAGE_ORDER=(00-preflight 10-partition 20-format 30-mount 40-pacstrap
             50-base-config 60-drivers-media 70-desktop 80-bootloader
             90-postinstall)
STAGE_DESTRUCTIVE=( [10-partition]=1 [20-format]=1 )
```

Checkpoints live in `YAAP_CK_DIR` (`/var/lib/yaaplinux/checkpoints`). Each
completed stage writes `<stage>.done`:

```text
<ISO-8601 timestamp>
<sha256 of the whole config file at that moment>
```

- `stage_is_done` is true only when the file exists **and** its stored hash
  equals the current `ck_config_hash`. Editing the config invalidates every
  stamp whose recorded hash no longer matches — that is the re-run trigger;
  no explicit `--resume` flag exists. Re-running always resumes from the
  first incomplete stage.
- Destructive stages re-confirm on **every** execution, resume included,
  unless `--force` (`ui_confirm_true`; declining aborts).
- Drift guard: a later stage stamped done while an earlier one is not logs a
  `config hash drift?` warning.
- Each stage ends by setting `meta.stage` to a human-readable label of the
  next phase (audit cursor, distinct from the `.done` stamps).
- After the loop, the orchestrator-owned `write_report` emits the
  post-install report (so it also runs when the final stage is skipped on
  resume, and in dry-run).

### 4.3 Runtime environment variables

Defaults shown; all overridable from the environment.

| Variable | Default | Purpose |
|---|---|---|
| `YAAP_CONFIG` | `/etc/yaaplinux/install-config.yaml` | Active config. |
| `YAAP_LOG_DIR` | `/var/log/yaaplinux` | Transcript directory. |
| `YAAP_CK_DIR` | `/var/lib/yaaplinux/checkpoints` | Checkpoint directory. |
| `YAAP_TARGET_ROOT` → `TARGET_ROOT` | `/mnt` | Target root. |
| `YAAP_TARGET_DISK` | auto-detect | From `--target`. |
| `YAAP_LUKS_PASSPHRASE_FILE` | `/var/lib/yaaplinux/luks-passphrase` | Staged unattended LUKS passphrase (stage 10 → 30). |
| `YAAP_UNATTENDED` / `YAAP_DEBUG` / `YAAP_DRYRUN` / `YAAP_FORCE` | `0` | Run-mode flags. |
| `YAAP_INSTALL_SET` | — | Pending package set inspected by `pkg_conflict_guard`. |
| `YAAP_AUR_HELPER` | `yay` | Helper for `pkg_install_aur`; absence degrades to a warning. |

### 4.4 Dry-run contract

Dry-run is enforced in the orchestrator loop, not inside stages:

- Stages `10-partition`, `20-format`, `30-mount` are skipped with a log line —
  no disk mutation is possible.
- The run stops before `50-base-config` (the target root was never populated),
  writes the report, and exits 0.
- Stage `00-preflight` runs (detection is read-only); stage `40-pacstrap` is
  dry-run aware and logs instead of pacstrapping.

---

## 5. Stage 00 — preflight

Pre-mutation checks. Hard failures abort before a disk is touched.

| Check | Hard? | Behaviour |
|---|---|---|
| `check_root` | yes | Must run as root. |
| `check_arch_live` | no | Warns when not on an Arch live env; prompts unless unattended. |
| `check_internet` | yes | `ping 1.1.1.1`/`8.8.8.8` or `curl https://archlinux.org`. |
| `check_clock` | yes | `timedatectl` NTP sync; tries `set-ntp` then re-checks. |
| `resolve_target_disk` | yes | `--target` → `storage.device` → detect → prompt; hard error unattended without a disk. |
| `check_disk_size` | yes | Target ≥ 32 GiB. |
| `check_firmware_branch` | no | UEFI/BIOS detection; BIOS ⇒ Secure Boot unavailable; confirmed unless unattended. |
| `check_secure_boot_preflight` | no | Logs the detected setup-mode state (§10.3). |
| `check_ram` | yes | ≥ 768 MiB; < 2048 MiB warns. |
| `check_mirrorlist` | no | `reflector` refresh when available. |

---

## 6. Disk stack — stages 10, 20, 30

### 6.1 Partitioning (stage 10, destructive)

GPT always. `sgdisk --zap-all`, zero the first 2 GiB, fresh `sgdisk -o`.

| Partition | Type | Size | Present |
|---|---|---|---|
| ESP (`p1`) | `ef00` | 1024 MiB with UKIs on, else 512 MiB | always |
| BIOS boot | `ef02` | 1 MiB | BIOS firmware only |
| root | `8300` | remainder | `p3` on BIOS, `p2` on UEFI |

`partprobe` + `sync`, then the root partition path is resolved
(`pN`/`N` suffix handling) into `storage.root_partition`.

### 6.2 LUKS2 (stage 10, gated by `disk.luks.enabled`, default true)

```bash
cryptsetup luksFormat --type luks2 \
  --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id <root-partition>
```

Cipher, key size, and mapper name (default `cryptroot`) come from
`disk.luks.*`. The opened mapper is recorded in `disk.luks.open_mapper`.

- **Interactive:** passphrase prompted twice via `ui_input`.
- **Unattended:** a random passphrase is generated and persisted to
  `$YAAP_LUKS_PASSPHRASE_FILE`; `disk.luks.unattended=true` is set. The
  passphrase is never discarded at this point — losing it bricks the
  post-reboot unlock. Unattended `luksOpen` uses it via `--key-file`.
- **TPM2 auto-unlock** (opt-in via `hardware.secure_boot.tpm2_auto_unlock` +
  confirmation): `systemd-cryptenroll --tpm2-device=auto`. The passphrase
  slot is kept; wiping it is a separate, dangerous opt-in
  (`disk.luks.tpm2_wipe_password_slot`) best done manually after a verified
  first boot — a TPM state change can otherwise leave the disk unrecoverable.

### 6.3 Formatting and subvolumes (stage 20, destructive)

- ESP: `mkfs.fat -F32` (intentionally not mounted here).
- Root: `mkfs.btrfs -L archroot` on the raw partition or the LUKS mapper.
- Subvolumes from `cfg_array disk.subvolumes` (default `@ @home @swap
  @snapshots`), created on a temp mount with `compress=zstd:3`.
- Hibernation swapfile (`disk.swap.hibernation=true`): `btrfs filesystem
  mkswapfile --size <disk.swap.file_size_gb>GiB` (CoW disabled; `fallocate`
  fallback), then `disk.swap.resume_offset` recorded from
  `btrfs inspect-internal map-swapfile -r`.

### 6.4 Mounting and fstab (stage 30)

- `@` → `TARGET_ROOT` with `noatime,compress=zstd:3,space_cache=v2`;
  `@home`/`@swap`/`@snapshots` bind-mounted; ESP → `/boot/efi`.
- Unattended LUKS: the staged passphrase is copied to
  `/boot/efi/keys/<mapper>.key` (mode 600) so the system is unlockable after
  reboot. This lives on the **unencrypted ESP** and weakens physical-attack
  protection by design; the post-install report flags it for manual removal.
- `store_uuids` (`storage.root_uuid`, `storage.esp_uuid` via `blkid`), then
  `write_fstab`: btrfs subvol entries for `/`, `/home`, `/swap`,
  `/.snapshots`; ESP as vfat `umask=0077`; a `/swap/swap` line when
  hibernation is on with `zram_plus_file`.

### 6.5 Swap model

`disk.swap.style` is config-declared: `zram_plus_file` (default), `partition`,
or `none`. The installer's concrete work happens only when
`disk.swap.hibernation=true` (§6.3): swapfile creation, `resume_offset`,
fstab entry, `initramfs.conf.d/resume.conf` (`RESUME=UUID=…`,
`RESUME_OFFSET=…`) and the `resume` mkinitcpio hook in stage 50, and
`resume=UUID=… resume_offset=…` folded into the UKI cmdline in stage 80.
zram itself is not provisioned by any stage (§15).

---

## 7. Base system — stages 40 and 50

### 7.1 pacstrap (stage 40)

`pacman-key --init --populate archlinux`, then `pacstrap -K --needed` with:

```text
base base-devel linux-zen linux linux-firmware btrfs-progs dosfstools
exfatprogs ntfs-3g networkmanager iwd sudo vim nano man-db man-pages
```

`linux-zen` is the primary kernel, `linux` the recovery fallback (both get
initrds in stage 50). `genfstab -U` regenerates fstab from the live mounts;
`append_swap_fstab` re-adds the hibernation swapfile line genfstab cannot
see.

### 7.2 Base configuration (stage 50, chroot)

- **Locale/clock/hostname** — `locale.gen` + `locale.conf` from
  `locale.lang`; `vconsole.conf` from `locale.keymap`; `set-timezone` +
  `hwclock --systohc` from `locale.timezone`; `/etc/hostname` + `/etc/hosts`
  from `system.hostname` (default/prompt `yaaplinux`).
- **Microcode** — `hardware.cpu.microcode` (`intel-ucode`/`amd-ucode`)
  installed **before** initramfs regeneration so it is embedded.
- **initramfs** — `mkinitcpio.conf` hooks:
  `base systemd autodetect modconf block keymap consolefont keyboard btrfs`
  plus `resume` (hibernation) and `sd-encrypt` (LUKS — the bare `encrypt`
  hook is deliberately not used next to `systemd`); `COMPRESSION="zstd"`;
  then `mkinitcpio -P`.
- **User** — `useradd -m -s <user.shell>`; unattended + empty `user.name`
  skips creation with a warning. Groups: `wheel` always; `video render audio
  input storage` when a GPU is known; `lp` with a printer; `scanner` with an
  acknowledged scanner (§8.1); plus `user.groups_extra`. Password prompted,
  or random when unattended. Passwords are never logged.
- **sudo** — `/etc/sudoers.d/00-wheel-nopasswd_prompt` (`%wheel ALL=(ALL:ALL)
  ALL`, 0440), validated with `visudo -cf`.
- **Network** — NetworkManager enabled (never systemd-networkd — they
  conflict), `WifiBackend=iwd` drop-in.
- **Persistence** — config copied to the target; installer tree to
  `/opt/yaaplinux`; `assets/hooks/*.hook` to `/etc/pacman.d/hooks/` (snapper
  pre/post transaction snapshots; gutenprint PPD regeneration, §8.6).
- **Dotfiles** — `disk.dotfiles.repo`/`branch` cloned into the target user's
  home as `~/.dotfiles`, idempotent clone/pull. The post-install CLI
  (`lib/yaap`) is installed at `/etc/yaaplinux/yaap` with `status`, `report`,
  `reboot`, `dotfiles sync|status` subcommands.

---

## 8. Hardware detection, drivers, and media (`lib/detect.sh`, stage 60)

### 8.1 Detection

`detect_all` runs the full sweep; every detector is idempotent and writes via
`cfg_set`.

| Detector | Source | Keys written |
|---|---|---|
| `detect_firmware` | `/sys/firmware/efi` presence | `hardware.firmware` (`uefi`/`bios`) |
| `detect_secure_boot_state` | `/sys/firmware/efi/systab` (`SetupMode=1` wins over `SecureBoot=1`) | `hardware.secure_boot.setup_mode`, `.enrolled` |
| `detect_cpu_vendor` | `vendor_id` in `/proc/cpuinfo` | `hardware.cpu.vendor`, `.microcode` |
| `detect_gpu` | `lspci -mm` (monster mode — numeric mode makes the vendor greps always miss) | `hardware.gpu.primary`, `.intel_gen`, `.vaapi_driver`, `.needs_linux_firmware_intel` |
| `detect_storage` | `YAAP_TARGET_DISK` else first non-hotplug disk; refuses the live medium (`sr0`/`sg*`/`sd?_cd`) | `storage.device`, `.type`, `.rotational` |
| `detect_peripherals` | `lspci`, `lsusb`, `/proc/bus/input/devices`, `/dev/video0`, `/sys/class/power_supply` | `peripherals.*`, `battery` |

Scanner presence is **not** auto-detected: `peripherals.scanner` keeps its
seeded `unknown` unless set by hand (affects only the `scanner` group in
stage 50; the scanning package stack is gated by `media.scanning`, §8.7).

### 8.2 VA-API driver matrix

Selected in stage 60 (`install_vaapi_drivers`) from the detected GPU:

| GPU | Packages | `LIBVA_DRIVER_NAME` |
|---|---|---|
| `amd` | `mesa libva-mesa-driver` | *(not set)* |
| `intel` `broadwell_plus` (Iris/UHD/Arc/Haswell→Meteor) | `mesa libva-mesa-driver intel-media-driver` | `iHD` |
| `intel` `legacy` | `mesa libva-mesa-driver libva-intel-driver` | *(not set)* |
| `nvidia` | `mesa nvidia-utils libva-nvidia-driver` | `nvidia` |
| `unknown` | *(none — warns)* | *(not set)* |

Broadwell-plus Intel asserts `linux-firmware-intel` in the target and warns
when missing — Skylake+ VA-API can fail silently without it. Env hints go to
`/etc/profile.d/yaap-vaapi.sh` **and** `desktop.env.LIBVA_DRIVER_NAME` (so
stage 70 re-emits them into the Wayland session). The user is asserted into
the `video` group.

The codec stack ships no `freeworld`/`libdvdcss` variants — Arch compiles
patent codecs into `ffmpeg`/`mesa` (see §15 for the open `libdvdcss` question).

### 8.3 Codecs, GStreamer tuning, and diagnostics

Gates: `media.codecs` (ffmpeg + GStreamer base/good/bad/libav, plus
`gst-plugins-ugly` unless `media.gstreamer_ugly=false`) and
`media.diagnostics` (`libva-utils`, `vdpauinfo`), plus:

- NVIDIA: `desktop.env.GST_PLUGIN_FEATURE_RANK` ranks the `nv*` hardware
  decoders `MAX`.
- `vainfo` is run in the target and captured to
  `/var/log/yaaplinux/vainfo.log` (non-fatal — the driver may not load until
  first boot). When no `VAProfileAV1` is reported, the AV1 GStreamer decoders
  are auto-demoted to `NONE`.

### 8.4 Multilib — the single sanctioned full-sync

Every package install in the installer is `pacman -S --needed` — never
`-Sy`, so no partial upgrade can occur — with exactly one exception:
`repo_enable_multilib`, reachable only from `apply_multilib_if_requested`
when `media.multilib=true`:

1. Idempotently uncomments/appends `[multilib]` in the **target**
   `/etc/pacman.conf`.
2. Runs a full `pacman -Syu`.
3. On failure, reverts the pacman.conf edit and returns non-zero (the
   caller's warning is non-fatal).
4. Verifies with `pacman -Sl multilib` and records `media.multilib true`.

### 8.5 Package conflict guards

`pkg_conflict_guard <a> <b>` aborts when both packages appear in the pending
`YAAP_INSTALL_SET` (seeded by `build_install_set` as `base base-devel linux
linux-firmware` plus `video-render-utils` when the GPU is known). The live
guard is `hplip` ↔ `foo2zjs-nightly` (the known foo2zjs/hplip PPD conflict,
FS#58815); `foo2zjs-nightly` is AUR-only and opt-in.

### 8.6 Printing (gated by `media.printing`)

`cups system-config-printer avahi ghostscript gsfonts gutenprint`, plus
`hplip` when `media.print_hp`; `cups.service` + `avahi-daemon.service`
enabled. The gutenprint maintenance hook (installed stage 50) runs
`cups-genppdupdate` and restarts CUPS on every gutenprint/foomatic upgrade,
automating the PPD regeneration that otherwise silently breaks printers.

### 8.7 Scanning (gated by `media.scanning`)

`sane sane-airscan ipp-usb simple-scan`; `ipp-usb.service` enabled (required
for USB IPP driverless scanners).

### 8.8 Universal drivers (always, unless gated)

Audio (`pipewire` family + `wireplumber` + `sof-firmware`), filesystems,
`lm_sensors`, `smartmontools` (+ `nvme-cli` on nvme) are unconditional.
Peripheral stacks install only on detection: bluez (bluetooth), libinput
(touchpad), v4l-utils (webcam), libwacom (tablet), fprintd (fingerprint),
modemmanager (modem). On battery, exactly one power daemon per
`power.daemon`.

---

## 9. Desktop — stage 70 and theming

Skipped entirely when `profile=minimal` (server profile; `meta.stage=done` is
recorded so resume still looks complete).

### 9.1 Stack

Compositor `hyprland`, then one declarative component set: `kitty fuzzel mako
hyprlock hyprpaper waybar hypridle xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk hyprpolkitagent wl-clipboard cliphist grim slurp satty
brightnessctl pavucontrol nautilus nwg-look adw-gtk-theme
bibata-cursor-theme qt6ct` (+`steam-devices` when `media.steam`).

Browser by `desktop.browser`: `firefox` (default), `librewolf` (AUR,
non-fatal — the live ISO ships no AUR helper), or `both`.

### 9.2 Hyprland Lua config

`assets/hyprland.lua` (Hyprland 0.56.x Lua API) is copied to
`~/.config/hypr/hyprland.lua` with an empty `theme.lua` placeholder. The
**only** API form verified this cycle is `hl.env("KEY", "value")`; the
section/binding syntax mirrors the documented 0.56 layout, but nested-table
parity is unverified (§15 #8). Theme loading is `pcall`-wrapped so a missing
theme never blocks the session. Bindings: `SUPER+Return` kitty, `SUPER+D`
fuzzel, `SUPER+space` fuzzel drun, `SUPER+X` grim+satty, `SUPER+L` hyprlock,
workspaces 1–9, `wpctl`/`brightnessctl` media keys.

### 9.3 Session environment and GTK/Qt wiring

`/etc/profile.d/yaap-wayland.sh` exports the `XDG_*`/`MOZ_ENABLE_WAYLAND`/
`QT_QPA_PLATFORMTHEME` set plus every `desktop.env` entry (read via
`cfg_map`). Session registration:
`/usr/share/wayland-sessions/hyprland.desktop` (`Exec=Hyprland`) so the
greeter can select the session.

GTK 4 is **not** covered by nwg-look — the color-scheme is set via
`gsettings` and a `~/.config/gtk-4.0/gtk.css` palette; GTK 3 gets the same
palette file; Qt 6 is themed through `qt6ct` with a Bibata cursor.

### 9.4 Base16 cross-layer theming (`assets/hypr-theme.sh`)

```bash
assets/hypr-theme.sh list
assets/hypr-theme.sh apply <scheme> [--light] [--accent <hex>]
```

Generates a coherent palette from one Base16 scheme
(`assets/base16/<scheme>.yaml`; the shipped scheme is Catppuccin Mocha):
`hypr/theme.lua`, kitty, fuzzel, mako, waybar `style.css`, GTK 3 + GTK 4
`gtk.css` (+ `gsettings` color-scheme), and `qt6ct`. Mapping: `base=base00`,
`fg=base05`, `accent=base0A` (overridable with `--accent`). Bibata cursor
applied via `gsettings` when installed.

---

## 10. Bootloader, security, and login — stage 80

The most fragile stage; it runs last among the mutating stages. Firmware is
re-resolved via `detect_firmware`, and the branches are:

### 10.1 Bootloader by firmware

- **UEFI — always systemd-boot.** `bootctl install`; `loader.conf` with
  `default arch-linux-zen.conf`, `timeout 5`, `editor off`; an efibootmgr
  NVRAM entry (`--create-only … --label "YaapLinux"`, warning-only on
  failure). Even `bootloader.uefi=grub` routes to systemd-boot on UEFI —
  UKIs pair with systemd-boot (§15).
- **BIOS — GRUB.** First requires the *BIOS-untested acknowledgement*
  (`bootloader.bios_warning_acknowledged=true` or an interactive prompt;
  unattended hard-fails without it). Then `grub-install --target=i386-pc`
  onto the bios_grub partition and `grub-mkconfig`.

### 10.2 UKIs and kernel cmdline

Cmdline assembled once into `bootloader.cmdline`:
`root=UUID=<btrfs-root-uuid> rw quiet splash` (LUKS is unlocked by the
initramfs `sd-encrypt` hook before root mounts), plus
`resume=UUID=… resume_offset=…` with hibernation.

With `bootloader.unified_kernel_images=true` (default), `build_uki` uses
`ukify`: output `/boot/efi/EFI/Linux/arch-linux-zen.efi`, kernel + initramfs
+ CPU-matched microcode + `/usr/lib/os-release` + the cmdline above.
systemd-boot auto-discovers `EFI/Linux/*.efi` — no manual entries. A missing
or failing `ukify` warns and falls back to the split `/boot` layout. The ESP
is sized to 1 GiB when UKIs are on (§6.1).

### 10.3 Secure Boot — graceful-abort contract

Driven by `hardware.secure_boot.strategy` (`sbctl` / `systemd` / `none`) and
the detected state:

| Strategy | Behaviour |
|---|---|
| `none` | Skips; UKI stays unsigned. |
| `sbctl` | State `setup_mode` or `enabled` → `arch-chroot sbctl enroll -v`; otherwise warns and leaves unsigned. |
| `systemd` | Documented placeholder (§15); leaves unsigned. |

**Normative:** enrolment failure must leave a bootable unsigned system.
`graceful_sb_abort` sets `hardware.secure_boot.enrolled=false`, logs that
Secure Boot is left DISABLED and the UKI remains bootable unsigned, points to
`/root/install-report.txt` for the manual `sbctl enroll -v` follow-up, and
touches nothing else. The system is never left half-enrolled with an unsigned
boot chain. Firmware known to refuse enrolment (Framework, Lenovo Lunar Lake
class) is handled by this path (§15).

### 10.4 Key and report hygiene

- Unattended LUKS publishes a keyfile to the unencrypted ESP (§6.4) — the
  report calls it out as a manual follow-up.
- A successful `sbctl enroll` sets `hardware.secure_boot.enrolled=true`; the
  report reminds the user to verify and (once enrolled) to back up the sbctl
  keys.

### 10.5 Login manager

| `login.manager` | Behaviour |
|---|---|
| `greetd` (default) | `greetd tuigreet`; `assets/greetd-config.toml` → `/etc/greetd/config.toml`; `greetd.service` enabled. The shipped config runs `tuigreet --time --gemini --remember --remember-user-session --cmd Hyprland`, pointing at the session registered in §9.3. |
| `tty_autologin` | `getty@tty1.service.d/autologin.conf` override autologging in `root`. |

---

## 11. ISO profile (`iso/`)

### 11.1 Profile goals

YaapLinux is an archiso profile (`uefi.systemd-boot` + `bios.syslinux`
bootmodes, x86_64, squashfs xz). The live medium is lean on purpose: it
carries only what the installer itself needs; the real payload is fetched
onto the target during pacstrap and later stages.

### 11.2 `profiledef.sh`

| Variable | Value |
|---|---|
| `iso_name` | `yaaplinux` |
| `iso_label` | `YAAPLINUX_$(date +%Y%m)` |
| `iso_version` | `$(date +%Y.%m.%d)` |
| `install_dir` | `arch` |
| `buildmodes` / `bootmodes` | `('iso')` / `('uefi.systemd-boot' 'bios.syslinux')` |
| `airootfs_image_type` | `squashfs` (`xz -Xbcj x86 -b 1M -Xdict-size 1M`) |

`file_permissions` pins `/etc/shadow` 0400, `/etc/passwd` 0644, `/root` 0750,
`/root/.automated_script.sh` 0755, `/usr/local/bin/yaap-install` 0755,
`/etc/yaaplinux` 0755 (script 0755, config 0644).

### 11.3 `packages.x86_64` — live payload

```text
base arch-install-scripts pacman mkinitcpio linux linux-firmware
btrfs-progs cryptsetup dosfstools exfatprogs parted gptfdisk efibootmgr
networkmanager iwd reflector git libarchive sudo vim gum syslinux sbctl
```

Hard rule one: the list must include `mkinitcpio-archiso` (and the
`airootfs/etc/mkinitcpio.conf.d/archiso.conf` HOOKS must ship the archiso
entries) or the ISO builds fine but drops to an emergency shell at "Failed to
start Switch Root" on every boot. Hard rule two: **never list `yay`** — it is
an AUR package and its presence aborts the build with "target not found".
`pacman.conf` is official-repos-only with `[multilib]` commented (enabled
opt-in by §8.4); its `SigLevel = Optional TrustAll` affects only the
build-time install, never the target.

### 11.4 airootfs layout

```text
airootfs/
├── etc/yaaplinux/                    embedded installer tree (§2 copy rule)
├── etc/shadow                        empty root password (root::14871::::::)
├── etc/systemd/system/
│   ├── systemd-firstboot.service     symlink to /dev/null (skip the wizard)
│   └── multi-user.target.wants/      NetworkManager.service enabled
├── usr/local/bin/yaap-install        exec /etc/yaaplinux/install.sh "$@"
└── root/.automated_script.sh         unattended entry point (§11.7)
```

Three entries in this list are the difference between a buildable and a
usable ISO: the empty root password (else the console is unloginable), the
enabled NetworkManager (else the live env has only loopback), and the masked
systemd-firstboot (else an interactive wizard blocks the console).

### 11.5 Building

```bash
cp -a install.sh lib stages assets iso/airootfs/etc/yaaplinux/
mkarchiso -v -w ./work -o ./out iso
```

mkarchiso runs on Arch only; on a non-Arch host the build runs inside a VM
booted from the official Arch ISO (`pacman -S archiso`, copy the tree in, run
mkarchiso there). Artifact verification before publishing: checksum the ISO,
then boot it (§11.6) — buildability alone proves nothing (§11.3).

### 11.6 Boot-testing

```bash
./test-vm.sh --iso out/yaaplinux-<date>-x86_64.iso          # UEFI (OVMF)
./test-vm.sh --bios --iso out/yaaplinux-<date>-x86_64.iso   # legacy BIOS
```

Both firmware paths are tested before a release. When driving QEMU manually,
`-append archisosearchuuid=` must equal the **built** ISO's UUID, not a
previous release's — a stale UUID boots to the archiso "device not found"
shell.

### 11.7 Unattended entry point

`root/.automated_script.sh` looks for a config at, in order:

```text
/run/archiso/yaap/install-config.yaml
/mnt/yaap/install-config.yaml
/etc/yaaplinux/automated/install-config.yaml
```

Found → `exec install.sh --unattended --config <file>`; not found →
interactive `install.sh`. It never auto-selects a disk: a fully unattended
config must still carry `--target` or a resolved `storage.device`.

---

## 12. Post-install (stage 90 and artifacts)

- **Snapshots** — `disk.snapshots.enabled=true` + `tool=snapper`:
  `snapper -c root createconfig -r /` plus `snapper-timeline`/`cleanup`
  timers (`timeshift` alternative: install only, interactive setup
  post-boot). Pacman hooks from stage 50 create pre/post snapshot pairs
  around every transaction.
- **Config finalisation** — the config is re-copied into the target.
- **Report** — `/root/install-report.txt` (and the target copy): completed
  stages, detected hardware, configuration summary, and manual follow-ups
  (Secure Boot not enrolled; multilib off; unattended-LUKS ESP keyfile;
  verify VA-API with `vainfo`).
- **`yaap` CLI** — `/etc/yaaplinux/yaap`: `status`, `report`, `reboot`,
  `dotfiles sync|status`.
- **Paths** — install log `/var/log/yaaplinux/`, VA-API log
  `/var/log/yaaplinux/vainfo.log`, config `/etc/yaaplinux/install-config.yaml`.

---

## 13. Decision summary

| Topic | Decision | Notes |
|---|---|---|
| Kernel | `linux-zen` primary, `linux` fallback | Both pacstrapped; fallback is the recovery path. |
| Filesystem | btrfs, no LVM | Subvolumes `@ @home @swap @snapshots`, zstd:3. |
| LUKS | LUKS2 default-on toggle | argon2id, aes-xts-plain64/512; TPM2 auto-unlock opt-in. |
| Swap | `zram_plus_file` declared; hibernation off by default | Install work only happens with hibernation on (§6.5). |
| Network | NetworkManager + iwd | Never both NM and systemd-networkd. |
| Bootloader | systemd-boot (UEFI) / GRUB (BIOS) | UEFI value `grub` is nominal (§10.1). |
| UKIs | Default on, ESP 1 GiB | ukify; split-`/boot` fallback. |
| Secure Boot | Opt-in, sbctl, graceful abort | §10.3 contract. |
| Login | greetd + tuigreet | tty_autologin alternative. |
| Desktop | Hyprland 0.56 Lua config | fuzzel/mako/waybar/kitty/hyprlock stack. |
| Theming | Base16 via `hypr-theme.sh` | Catppuccin Mocha shipped; §9.4. |
| Media | Codecs on; multilib/printing/scanning/steam off | §8 gates; §8.4 full-sync exception. |
| AUR | Opt-in helper (`yay`), non-fatal | None on the live ISO (§11.3). |
| Snapshots | snapper default-on | Pre/post pacman hooks; `boot_integration` declares intent (§15). |

---

## 14. Verification and failure handling

### 14.1 Error handling

| Failure | Recovery |
|---|---|
| Partition/format fails mid-run | Reboot to the live env, wipe, start over. Partial partitions are never rolled back automatically. |
| Stage after 30 fails | Fix the cause, re-run `install.sh`; resume skips completed, hash-valid stages. |
| Secure Boot enrolment fails | §10.3 graceful abort; enroll manually post-boot (`sbctl enroll -v`). |
| Config edited between runs | Downstream stamps invalidate; affected stages re-run on next invocation. |
| Dry-run | §4.4: no disk mutation possible; run stops before stage 50. |

### 14.2 Release verification checklist

- [ ] `bash -n` clean on every edited shell file.
- [ ] Embedded copy in sync: `diff -rq` source tree vs
  `iso/airootfs/etc/yaaplinux/` silent.
- [ ] ISO build completes; checksum recorded.
- [ ] ISO boots UEFI **and** BIOS in a VM to a login prompt.
- [ ] Full `--dry-run` completes the stage graph and writes the report.
- [ ] Docs (`configuration.md`, `stages.md`, `bootloader-and-security.md`)
  match the code paths changed.

---

## 15. Open design-decision items

Flags, not installer bugs. Resolve deliberately; each has a documented
workaround in the docs.

1. **`libdvdcss` repo placement** — DVD decryption is legal-grey; not shipped
   (§8.2). Decide whether to document an opt-in path.
2. **`librewolf` repo placement** — AUR-only; `pkg_install_aur` is non-fatal,
   so `librewolf`/`both` resolves fully only once a helper exists on the
   target (§9.1).
3. **Secure Boot firmware failure list** — firmware known to refuse
   enrolment (Framework, Lenovo Lunar Lake class) is handled by §10.3 but not
   enumerated; the `systemd` signing strategy is still a placeholder.
4. **zram provisioning** — `zram_plus_file` declares zram, but no stage calls
   `zramctl`/`systemd-zram-setup` (§6.5). Decide the runtime zram mechanism.
5. **Snapshot boot integration** — `disk.snapshots.boot_integration: true`
   declares intent; bootable-snapshot menu entries are not generated.
6. **Scanner group** — `peripherals.scanner` is never auto-set; only the
   group in stage 50 is affected (§8.1). Decide whether to probe.
7. **`hyprland.d` fragment sourcing** — the 0.56 Lua API for sourcing
   additional fragments is unverified; fragments land in
   `~/.config/hypr/hyprland.d/` unwired (§9.2).
8. **Hyprland 0.56 Lua API parity** — only `hl.env()` is verified; nested
   section/table syntax must be validated against a live 0.56 shell (§9.2).
9. **GRUB-on-UEFI** — `bootloader.uefi=grub` is accepted but nominal; UEFI
   always installs systemd-boot (§10.1). Either honour or remove the value.
10. **TPM2 PIN and slot-wipe workflow** — auto-unlock weakens
    physical-attack protection without a PIN; the slot-wipe opt-in is
    footgun-shaped (§6.2). Decide the recommended post-boot flow.

---

## Revision history

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-10-31 | Initial specification (component model: components/01–04, flat config, in-config checkpoints). |
| 2.0 | 2026-11-07 | Revised to match the implemented system: ten-stage pipeline, nested YAML config + cfg accessors, file checkpoints with config-hash invalidation, detect-on-every-run, LUKS2/TPM2/unattended-keyfile flows, UKI + graceful Secure Boot abort, stage-60 media matrix, stage-70 desktop + Base16 theming, real archiso profile (§11), numbered open items (§15). Section numbers 8–11 and 15 are load-bearing: README, docs, and asset headers cite them. |

---

*End of Specification*
