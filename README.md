# YaapLinux Custom Flavor

**Yaap** = *Yet Another Archinstall Profile*. A modular, resumable Bash installer
that produces a Wayland-native Arch Linux desktop flavour built on **Hyprland**.
Implements specification revision 2.0.

## Design at a glance

- **Official repos first.** AUR is opt-in behind a helper (`yay`).
- **Wayland-native** defaults; no X11-only tooling in the default path.
- **Modern defaults with escape hatches.** btrfs subvolumes, LUKS2, Secure Boot,
  UKIs — every one toggleable in `install-config.yaml`.
- **Resumable.** Every stage writes a checkpoint (`/var/lib/yaaplinux/checkpoints/`).
  Re-running `install.sh` continues from the first incomplete stage; a stage
  whose consumed config hash changed is re-run.
- **Hardware-detected.** Firmware, GPU VA-API drivers, and peripheral stacks are
  chosen from live probe results (`lib/detect.sh`).
- **Fail loudly, recover gracefully.** Destructive ambiguity aborts; Secure Boot
  enrolment failure leaves a bootable unsigned system.

## Layout

```
yaaplinux/
├── install.sh                 # orchestrator / entry point
├── assets/
│   ├── install-config.yaml    # default config (seeded on first run)
│   ├── hyprland.lua           # 0.56.x Lua compositor config
│   ├── hypr-theme.sh          # Base16 cross-layer theming
│   ├── base16/                # scheme definitions
│   ├── greetd-config.toml     # login manager
│   ├── snapper-root.conf      # snapshot config reference
│   └── hooks/                 # pacman hooks (snapper, gutenprint)
├── lib/
│   ├── log.sh                 # logging + transcript + die()
│   ├── ui.sh                  # gum/read prompt abstraction
│   ├── config.sh              # nested-YAML get/set
│   ├── checkpoint.sh          # stage cursor + resume
│   ├── detect.sh              # hardware probing
│   ├── pkg.sh                 # pacman/AUR wrappers, conflict guards, multilib
│   └── chroot.sh              # arch-chroot helpers
├── stages/
│   ├── 00-preflight.sh
│   ├── 10-partition.sh
│   ├── 20-format.sh
│   ├── 30-mount.sh
│   ├── 40-pacstrap.sh
│   ├── 50-base-config.sh
│   ├── 60-drivers-media.sh
│   ├── 70-desktop.sh
│   ├── 80-bootloader.sh
│   └── 90-postinstall.sh
└── iso/                       # archiso profile
```

## Usage

Run from the Arch ISO as root:

```bash
./install.sh --target /dev/nvme0n1          # interactive
./install.sh --target /dev/nvme0n1 --unattended   # config-driven, no prompts
./install.sh --target /dev/nvme0n1 --dry-run --debug
./install.sh --help
```

Re-run to resume; add `--force` to skip the destructive-stage re-confirmation.

## Configuration

`install-config.yaml` is seeded to `/etc/yaaplinux/install-config.yaml` on the
live system and copied into the target at stage 50. Edit it to change defaults;
hardware sections are overwritten by detection on each run.

Key toggles: `disk.luks.enabled`, `disk.swap.hibernation`, `disk.snapshots.tool`,
`bootloader.uefi`, `login.manager`, `media.multilib/printing/scanning`,
`power.daemon` (XOR with `tlp`).

## Theming

```bash
assets/hypr-theme.sh list
assets/hypr-theme.sh apply catppuccin-mocha            # dark
assets/hypr-theme.sh apply catppuccin-mocha --light --accent 89b4fa
```

## Media / VA-API

The codec stack ships no `freeworld` variants — Arch already compiles patent
codecs into `ffmpeg`/`mesa`. VA-API drivers follow the hardware matrix in spec
§8.2; `vainfo` output is captured to `/var/log/yaaplinux/vainfo.log` and AV1
decoders are auto-demoted when unsupported.

## ISO build

The installer tree must live at `/etc/yaaplinux/` inside the airootfs:

```bash
cp -a . iso/airootfs/etc/yaaplinux/
mkdir -p iso/airootfs/root
cp iso/airootfs/root/.automated_script.sh iso/airootfs/root/   # already present
mkarchiso -v -w ./work -o ./out iso
```

Test both UEFI and BIOS boot paths in a VM before writing to USB.

## Post-install

- Report: `/root/install-report.txt` (also in the target).
- Install log: `/var/log/yaaplinux/`.
- VA-API log: `/var/log/yaaplinux/vainfo.log`.

## Open items

See spec §15 (e.g. `libdvdcss`/`librewolf` repo placement, Secure Boot firmware
failure list, Hyprland 0.56 Lua API parity). These are design-decision flags, not
installer bugs.
