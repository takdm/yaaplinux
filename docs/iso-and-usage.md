# Building the ISO & Running the Installer

This document covers the archiso image build (`iso/` profile) and how to run the
installer both interactively and unattended. It is grounded in
`iso/profiledef.sh`, `iso/packages.x86_64`, `iso/pacman.conf`,
`iso/airootfs/root/.automated_script.sh`, `iso/airootfs/usr/local/bin/yaap-install`,
and `install.sh`.

---

## 1. The archiso profile (`iso/`)

YaapLinux is an **archiso** profile. The build produces a bootable live ISO
whose airootfs carries the whole installer tree at `/etc/yaaplinux/`.

### 1.1 `profiledef.sh`

| Variable | Value |
|---|---|
| `iso_name` | `yaaplinux` |
| `iso_label` | `YAAPLINUX_$(date +%Y%m)` |
| `iso_version` | `$(date +%Y.%m.%d)` |
| `install_dir` | `arch` |
| `buildmodes` | `('iso')` |
| `bootmodes` | `('uefi.systemd-boot' 'bios.syslinux')` |
| `arch` | `x86_64` |
| `airootfs_image_type` | `squashfs` (tool options: `xz -Xbcj x86 -b 1M -Xdict-size 1M`) |

`file_permissions` pins modes for `/etc/shadow` (0400), `/etc/passwd` (0644),
`/etc/sudoers.d` (0755), `/root` (0750), `/root/.automated_script.sh` (0755),
`/usr/local/bin/yaap-install` (0755), `/etc/yaaplinux` (0755), the installer
script (0755), and the config (0644).

### 1.2 `packages.x86_64` — the live-environment payload

The live image is **lean on purpose**: it carries only what the installer
*itself* needs to run. The real payload (the desktop, codecs, etc.) is fetched
onto the **target** during `pacstrap` and the later stages.

```
base  arch-install-scripts  pacman  mkinitcpio  linux  linux-firmware
btrfs-progs  cryptsetup  dosfstools  exfatprogs  parted  gptfdisk  efibootmgr
networkmanager  iwd  reflector  git  libarchive  sudo  vim
gum  syslinux  sbctl
```

| Tool | Why it's in the live image |
|---|---|
| `gum` | prompt UI (`lib/ui.sh` prefers `gum` over plain `read`) |
| `sbctl` | Secure Boot enrolment (stage 80) |
| `reflector` | refresh the mirrorlist in preflight |
| `gptfdisk`/`parted`/`efibootmgr`/`cryptsetup`/`btrfs-progs`/`dosfstools`/`exfatprogs` | partitioning, encryption, formatting |
| `arch-install-scripts` | `pacstrap`, `genfstab`, `locale-gen`, etc. |

> **There is deliberately no `yay` in the live image.** `yay` is an AUR package
> and cannot be pacman-installed — listing it in `packages.x86_64` would abort
> the ISO build with "target not found". An AUR helper is used on the **target**
> only when the user opts in; `lib/pkg.sh` degrades to a warning if none is
> present.

### 1.3 `pacman.conf` — the live-environment repo config

Mirrors the stock archiso layout: **official repos only** (`core`, `extra`).
`[multilib]` is **commented out** here and enabled opt-in by the installer
(`repo_enable_multilib`, see [Hardware & Media](hardware-and-media.md)).
`SigLevel = Optional TrustAll` is a build-time convenience (skip signature files
some mirrors 404); it affects only the ISO's build-time install, never the
target's own `pacman.conf` (which the installer writes fresh).

### 1.4 airootfs layout

```
airootfs/
├── etc/yaaplinux/
│   ├── install.sh                    # orchestrator
│   ├── install-config.yaml           # seeded default config
│   ├── lib/    (log, config, checkpoint, ui, detect, pkg, chroot)
│   ├── stages/ (00–90)
│   └── assets/ (hyprland.lua, hypr-theme.sh, base16/, greetd-config.toml,
│                snapper-root.conf, hooks/)
├── usr/local/bin/yaap-install        # convenience wrapper (see §4)
└── root/.automated_script.sh         # unattended entry point (see §5)
```

### 1.5 Boot entries (archiso stock)

- **UEFI** (`iso/efiboot/loader/`): systemd-boot, `timeout 3`, default
  `01-archiso-linux.conf` → `/arch/boot/x86_64/vmlinuz-linux` with
  `archisobasedir`/`archisosearchuuid`.
- **BIOS** (`iso/syslinux/`): syslinux, serial + menu, same kernel path via
  `syslinux-linux.cfg`.

---

## 2. Building the image

From the repo root (the installer tree must live at `/etc/yaaplinux/` inside the
airootfs):

```bash
cp -a . iso/airootfs/etc/yaaplinux/                 # copy installer tree in
# .automated_script.sh already ships under iso/airootfs/root/
mkarchiso -v -w ./work -o ./out iso
```

`mkarchiso` reads `iso/profiledef.sh`, uses `iso/packages.x86_64` and
`iso/pacman.conf`, and packages `iso/airootfs/` into a squashfs under `iso/out/`.

**Bootable-initramfs requirement.** `iso/packages.x86_64` must include
`mkinitcpio-archiso` and `iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf` must
set the archiso `HOOKS`. Without them mkinitcpio builds a stock initramfs that
cannot mount the live rootfs — the ISO builds fine but drops to an emergency
shell at "Failed to start Switch Root" on every boot. (This exact bug shipped
in the v2.0 release ISO; see troubleshooting.)

`iso/airootfs/etc/systemd/system/systemd-firstboot.service` is a symlink to
`/dev/null` so the ISO boots straight to a login prompt instead of the
interactive systemd-firstboot wizard.

`iso/airootfs/etc/shadow` ships an empty root password (`root::14871::::::`,
same as the releng profile) — without it root login is locked and the ISO
cannot be used from the console at all. Its permissions (`0:0:400`) are set in
`profiledef.sh`.

## 2a. Boot-testing in a VM

`test-vm.sh` (repo root) boots any ISO in QEMU/KVM with a throwaway 30G qcow2
disk, 2G RAM and user-mode networking:

```bash
sudo apt install -y qemu-system-x86 qemu-utils ovmf   # one-time, on Debian/Ubuntu hosts
./test-vm.sh --iso out/yaaplinux-<date>-x86_64.iso    # UEFI (OVMF)
./test-vm.sh --bios --iso out/yaaplinux-<date>-x86_64.iso
```

Delete `~/.cache/yaaplinux-vm/disk.qcow2` to reset the test machine. On a
non-Arch host the whole ISO build itself can also run inside the VM: boot the
official Arch ISO, `pacman -S archiso`, copy the repo tree in, and run
`mkarchiso` there — that is how the v2.0.1 ISO was produced.

> Test **both** the UEFI and BIOS boot paths in a VM before writing to USB
> (README).

---

## 3. Running the installer interactively

Run from the Arch/YAAPLINUX live ISO as root:

```bash
./install.sh --target /dev/nvme0n1          # interactive
./install.sh --target /dev/nvme0n1 --dry-run --debug
./install.sh --help
```

On the live ISO the bundled wrapper works identically (see §4):

```bash
yaap-install --target /dev/nvme0n1
```

**Options** (`install.sh` argv):

| Flag | Effect |
|---|---|
| `--config PATH` | use `PATH` as `install-config.yaml` (default `/etc/yaaplinux/install-config.yaml`) |
| `--target DEV` | target disk (default: auto-detect) |
| `--unattended` | never prompt; rely on config + `--target` |
| `--force` | skip destructive-stage re-confirmation on resume |
| `--dry-run` | log intended mutations, perform none |
| `--debug` | verbose debug logging |

**Flow:** the config is seeded from the template on first run, then the stage
graph runs `00-preflight → 10-partition → 20-format → 30-mount → 40-pacstrap →
50-base-config → 60-drivers-media → 70-desktop → 80-bootloader → 90-postinstall`.
Stages `10-partition` and `20-format` are **destructive** and re-confirm even on
resume (unless `--force`). Safe to re-run: it resumes from the first incomplete
stage.

---

## 4. The `yaap-install` wrapper

`iso/airootfs/usr/local/bin/yaap-install` is a thin pass-through:

```bash
exec /etc/yaaplinux/install.sh "$@"
```

So `yaap-install --help`, `yaap-install --unattended --config /path`, etc. all
work. It is chmod 0755 in `profiledef.sh`.

---

## 5. Unattended runs

Two ingredients: a **config file** and `--target` (the installer **never**
auto-selects a disk in unattended mode).

```bash
install.sh --unattended --config /path/to/install-config.yaml --target /dev/nvme0n1
```

- Every `ui_*` prompt returns its default immediately in `--unattended`.
- Firmware/disk are still detected; in unattended mode a missing target disk is
  a hard error ("use --target /dev/XXX").
- LUKS (if enabled) generates and persists a passphrase to the ESP keyfile so
  the system is unlockable after reboot.
- Missing `user.name` → user creation is skipped with a warning; hostname
  defaults to `yaaplinux`.

### 5.1 `.automated_script.sh` — the ISO-label entry point

`iso/airootfs/root/.automated_script.sh` is the auto-run hook. It looks for a
config in this order:

```
/run/archiso/yaap/install-config.yaml
/mnt/yaap/install-config.yaml
/etc/yaaplinux/automated/install-config.yaml
```

- If found → `exec /etc/yaaplinux/install.sh --unattended --config "$AUTOMATED_CONFIG"`.
- If not found → `exec /etc/yaaplinux/install.sh` (interactive).

It **never** auto-selects a disk: an unattended config must still carry a valid
target (via `--target` on the command line, or a pre-resolved
`storage.device`). To ship a fully unattended image, place the config on the ISO
label filesystem or a second USB partition at one of the paths above.
