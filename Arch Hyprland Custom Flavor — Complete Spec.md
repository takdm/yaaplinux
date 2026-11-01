# Arch Hyprland Custom Flavor — Complete Installer Specification

**Version:** 1.0  
**Date:** October 31, 2026  
**Status:** Finalized  

---

## Executive Summary

This specification defines an automated Arch Linux installer for a custom Hyprland-flavored system. It covers five components:

1. **Partitioning & Disk Setup** — btrfs, LUKS (optional), zram + swap file hybrid
2. **Base System + Chroot** — linux-zen kernel, NetworkManager, AUR helper (opt-out yay)
3. **Bootloader + Initramfs + Login** — systemd-boot/GRUB, greetd + tuigreet, Secure Boot support
4. **Hyprland Desktop** — Lua config, fuzzel launcher, Wayland-native-first stack
5. **Orchestrator** — Single entry point, persistent config, checkpoint-based recovery

**Additional:** ISO baking instructions for creating a self-contained live installation media.

---

## Design Principles

| Principle | Implementation |
|---|---|
| **Official repos first** | AUR is opt-in, isolated, clearly marked |
| **Wayland-native-first** | At every choice point, prefer Wayland/Hyprland-native tools |
| **Idempotent** | Re-running must not duplicate work or fail |
| **Fail-fast** | Clear error messages, no silent failures |
| **Checkpoint-based** | Resume from failure without restarting entire install |
| **No partial upgrades** | Never interleave -Sy and -S; always full sync or none |

---

## Component 1: Partitioning & Disk Setup

```text
## COMPONENT: DISK PARTITIONING & FILESYSTEM SETUP

Goal: Partition and format the target disk for Arch Linux with btrfs,
offering LUKS encryption as an optional toggle. Skip LVM; use plain
LUKS on top of the raw device (if enabled). Single filesystem for root
(no separate /home partition). Include swap file with interactive sizing.

### Environment assumptions
- Running from Arch live ISO with root privileges.
- Target machine may be UEFI or BIOS; auto-detect via:
    UEFI: /sys/firmware/efi/fw_platform_size exists
- Network is up (may be needed for reflector/mirror updates).

### User interaction flow
1. Show detected drives (lsblk -f) and prompt user to select target device.
2. Ask: "Enable full-disk LUKS encryption? [Y/n]" (toggle).
3. If LUKS enabled, prompt for passphrase (twice, with confirmation).
4. Ask swap style (zram, swapfile, partition, hybrid) and hibernation toggle.
5. Ask for swap file size (offer recommended value based on detected RAM).
6. Warn: "This will WIPE ALL DATA on <device>. Confirm?" (explicit ack).
7. Proceed with partitioning and formatting.
8. Log all actions to timestamped file.

### Disk detection & validation
- List available block devices: lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
- Filter out loop devices and obviously small USB sticks (<1GB).
- Require explicit device path (e.g., /dev/nvme0n1, /dev/sda).
- Validate device exists; exit cleanly with error if not.
- Check device is not mounted; refuse if any partitions are active.

### Partition scheme (UEFI or BIOS detected)

#### UEFI path (most common)
┌──────────────┬─────────┬───────────┬────────────────────────────────┐
│ Partition    │ Size    │ Type      │ Notes                        │
├──────────────┼─────────┼───────────┼────────────────────────────────┤
│ p1           │ 1GB     │ EFI       │ vfat32, FAT32, mount /boot     │
│ p2           │ Rest    │ Linux     │ btrfs (or encrypted)           │
└──────────────┴─────────┴───────────┴────────────────────────────────┘

#### BIOS path (fallback if no EFI detected)
┌──────────────┬─────────┬───────────┬────────────────────────────────┐
│ Partition    │ Size    │ Type      │ Notes                        │
├──────────────┼─────────┼───────────┼────────────────────────────────┤
│ p1           │ 512MB   │ BIOS Boot │ grub requires ~1MB, use 512MB  │
│ p2           │ Rest    │ Linux     │ btrfs (or encrypted)           │
└──────────────┴─────────┴───────────┴────────────────────────────────┘

Implementation:
- Use parted or fdisk/gdisk for partition creation.
- Set partition type: ef00 (UEFI) or 83 (BIOS Linux).
- Verify partition table written before proceeding.

### LUKS encryption (optional, toggle-driven)
- If enabled on root partition:
  * luksFormat <root_partition> with user passphrase
  * luksOpen -> maps to mapper/<device_name>-crypt
  * Create filesystem on mapper device, not raw partition
- If disabled:
  * Create filesystem directly on raw partition
- Store encryption status in a persistent config file the script
  can re-read on re-run (for idempotency checks).

### Filesystem: btrfs (always)
- Format the root partition (raw or LUKS-mapped) as btrfs.
- Create subvolumes on first boot:
  * @         (root, default subvol)
  * @home     (if user chooses later, script should support adding)
  * @swap     (for swapfile isolation from snapshots)
  * @snapshots (for snapper, optional future enhancement)
- Mount with: mount -o subvol=@,compress=zstd:1
- Add appropriate entry to /etc/fstab using UUID (blkid).
- Document btrfs mount options in the config comments.

### Swap configuration (prompted)

Prompt 1: "Enable hibernation support? [y/N]"
  - Store as HIBERNATE=yes|no in the install config.
  - If yes, this constrains everything below.

Prompt 2: "Swap style:" (menu, filtered by HIBERNATE)
  Options:
    1) zram only                     [hidden/disabled if HIBERNATE=yes]
    2) swap file only
    3) swap partition only
    4) zram + swap file              [RECOMMENDED DEFAULT]
    5) zram + swap partition
    6) zswap + disk swap
    7) no swap                       [hidden/disabled if HIBERNATE=yes]
  - If HIBERNATE=yes and the user picks 1 or 7, explain WHY it cannot
    work (logind refuses to hibernate to zram) and re-prompt.
    Do not silently override the user.

Prompt 3: "Swap size:"
  - If HIBERNATE=yes: recommend RAM size (round up to nearest GB,
    plus 1GB headroom). State clearly that this is the conservative
    choice and that smaller sizes may work but are not guaranteed.
  - If HIBERNATE=no: recommend min(RAM/2, 8GB) for a file,
    or RAM/2 for zram.
  - If hybrid (zram + disk swap) and HIBERNATE=yes: recommend
    RAM + zram size, per community guidance.
  - Always allow a custom value and a "skip" escape hatch.

### Swap file creation on btrfs (CORRECTED — earlier draft was ext4-only)
- Do NOT use the naive dd + mkswap + swapon sequence.
- Preferred: btrfs filesystem mkswapfile --size <N>g <path>
  (handles NODATACOW and no-compression correctly in one step)
- If that subcommand is unavailable, fall back to:
    * create the file EMPTY first
    * chattr +C on the file (or its parent directory) to disable CoW
    * set btrfs property compression none
    * then dd into it, chmod 600, mkswap, swapon
- Place the swapfile in a dedicated location, not scattered in /.
  Suggested: /swap/swapfile on its own subvolume (@swap), so it is
  never captured by root snapshots.
- VERIFY with swapon --show before proceeding.

### Swap partition (only if style 3 or 5 chosen)
- Add a swap partition to the layout. Size per Prompt 3.
- ENCRYPTION INTERACTION — flag this to the user explicitly:
    * Without LVM, an encrypted swap partition requires a SECOND
      LUKS container and therefore a SECOND passphrase at boot.
    * A keyfile cannot solve this: it would live inside the
      encrypted root, which is not yet unlocked.
    * Unencrypted swap leaks full RAM contents (including secrets)
      to disk on every hibernation.
  If LUKS=yes and style includes a swap partition, print this
  trade-off and require explicit acknowledgement, or offer to
  switch to a swap file inside the encrypted root instead.

### Mount points & fstab
- Mount hierarchy:
  * /mnt                 (base)
  * /mnt/boot            (UEFI) or /mnt/boot (BIOS grub)
  * /mnt                 (root partition)
- Generate /etc/fstab with:
  * UUID-based entries for reliability across reboots
  * Proper filesystem type (btrfs) and mount options
  * Comment header explaining subvolumes and encryption
- Run genfstab -U /mnt >> /mnt/etc/fstab after mounting.
- Verify fstab parses correctly before proceeding.

### Hard requirements for this component
- set -euo pipefail; log all partitioning commands.
- Never write to /dev/sdX without explicit user confirmation.
- Exit gracefully if user cancels at any prompt (no partial writes).
- Idempotent: re-running detects existing partition table and either:
    (a) confirms and skips, or
    (b) offers to re-partition (with data loss warning).
- No destructive defaults; every dangerous action requires a yes/no.
- At completion, display a summary table:
    Device, Partitions created, Encryption status, Swap size,
    Filesystem type, UUIDs for reference.

### Edge cases to guard against
- Device busy: refuse if any partition is mounted or in use.
- Insufficient space: warn if target is smaller than recommended (10GB min).
- Existing partitions: show them before wiping; don't assume blank disk.
- LUKS failures: if luksOpen fails, report error and abort chroot setup.
- BIOS/UEFI confusion: check for /sys/firmware/efi and adapt accordingly.
- btrfs errors: run btrfs filesystem check if mount fails.

### Post-partitioning verification checklist
- [ ] Target disk partitioned with correct scheme (UEFI/BIOS)
- [ ] Filesystem formatted (btrfs) on target partition
- [ ] LUKS encryption applied (if selected) and opens successfully
- [ ] Swap file created, sized, and enabled
- [ ] fstab generated and validates with mount -a (simulated)
- [ ] Summary logged with UUIDs for recovery documentation
- [ ] User notified that chroot setup is next step
```

---

## Component 2: Base System + Chroot Configuration

```text
## COMPONENT: BASE SYSTEM + CHROOT CONFIGURATION

Goal: Install the base Arch system, configure identity/locale/services,
and prepare the environment for the desktop and bootloader components.
Official repositories primarily, with an opt-out AUR helper (yay).

### Environment assumptions
- Runs from the live ISO, AFTER partitioning and mounting, BEFORE
  the bootloader component.
- Target mounted at /mnt with /mnt/boot as the separate ESP.
- Network is up (needed for pacstrap).
- Reads the persistent install config; writes new keys to it.

### Mirrors and pacman hygiene
- Run reflector (official repo package) to rank mirrors.
- Configure /etc/pacman.conf: Color, ILoveCandy, ParallelDownloads,
  VerbosePkgLists.
- CRITICAL — NO PARTIAL UPGRADES. Refreshing the database and then
  installing individual packages (-Sy then -S) breaks the system.
  The installer must either:
    (a) install from the ISO's existing sync databases without -Sy, or
    (b) perform a full -Syu first, then install packages.
  Pick one path and document it. Never interleave.
- Verify the keyring is current before installing (archlinux-keyring
  + pacman-key init/refresh) so signature failures don't abort mid-install.

### pacstrap — base packages
Minimum set:
  base linux-FIRMWARE-SUBPACKAGES linux-zen linux base-devel
  git man-db man-pages texinfo
  sudo
  networkmanager iwd wpa_supplicant (see below)
  nano vim (fallback editors, install both)

KERNEL CHOICE:
  PRIMARY: linux-zen (optimised for desktop responsiveness,
          the default choice)
  FALLBACK: linux (stock, conservative, recovery path)
  
  If user selects a different primary:
  - Allow selection from menu (linux, linux-zen, linux-lts,
    linux-hardened)
  - Always recommend keeping stock linux as fallback
  - Document that each kernel multiplies UKI size (if UKIs in use)
  - Flag ESP growth warning if both kernels use UKIs

MICROCODE (auto-detect CPU vendor, install BEFORE initramfs regen):
  Intel -> intel-ucode
  AMD   -> amd-ucode
  
  ORDERING IS CRITICAL: microcode must be installed before
  mkinitcpio -P runs, or it will not be embedded. The bootloader
  component regenerates initramfs, so this component must finish
  microcode installation first. Assert this ordering.

### Firmware subpackages (hardware-detected, replaces blanket install)
- Do NOT install the linux-firmware meta package AND subpackages.
  Choose ONE path:
    Path A (recommended): install only matching subpackages
    Path B: install the meta package (simple, larger footprint)
  
- Detection mapping (detect wifi/GPU vendor from lspci/lsusb):
    GPU AMD      -> linux-firmware-amdgpu
    GPU NVIDIA   -> linux-firmware-nvidia
    GPU Intel    -> linux-firmware-intel
    GPU Radeon   -> linux-firmware-radeon
    Wifi Atheros -> linux-firmware-atheros
    Wifi Broadcom-> linux-firmware-broadcom
    Wifi MediaTek-> linux-firmware-mediatek
    Wifi Realtek -> linux-firmware-realtek
    Other        -> linux-firmware-other
    
- linux-firmware-whence is a shared dependency; let pacman pull it.
- VERIFY after install that no file-ownership conflicts exist between
  the meta package and any subpackage. Abort loudly if they collide.
- Install sof-firmware if machine has modern onboard audio (many
  recent laptops need it) — detect via presence of SOF hardware.

### Network stack (NetworkManager, not systemd-networkd)
Install:
  networkmanager iwd wpa_supplicant
  
Configure:
  - Enable NetworkManager.service
  - iwd as the wifi backend (more modern than wpa_supplicant)
  - No additional .network files required; NetworkManager manages
    all interfaces automatically
  - Optionally install networkmanager-tui or nmcli for CLI management
  
Why NetworkManager over networkd:
  - Better laptop roaming (user can travel between networks)
  - Waybar integration (waybar has a network module)
  - Single daemon, less manual configuration
  - Still uses iwd for wifi (matches native-first rule)
  
Note: do NOT enable both NetworkManager and systemd-networkd
simultaneously. They conflict.

### Time synchronization
- Use systemd-timesyncd (native, no extra daemon) unless the user
  requests chrony/ntp.
- Enable and verify it is actually syncing, not merely enabled.

### Identity and access
- Hostname: prompt, validate (RFC-1123: alphanumeric + hyphen,
  no leading/trailing hyphen, reasonable length). Write /etc/hostname
  and matching /etc/hosts entries.
- Root password: prompt. Warn if weak. Never log it.
- Create the primary user:
    * username: prompt, validate against existing system accounts
    * groups: wheel plus any detected peripheral groups (video,
      render, audio, input, storage, lp) — add only those that exist
    * password: prompt twice, never logged
    * shell: bash (the standard Arch default)
- sudo: install sudo, create /etc/sudoers.d/10-wheel granting %wheel
  with NOPASSWD or PASSWD based on user preference (document the
  security implication). VALIDATE with visudo -c before finishing —
  a malformed sudoers file locks the user out.
  
Alternative: offer doas as a lighter substitute. Default to sudo
for familiarity and better documentation.

### Locale, keymap, timezone (RELLOCATED FROM HYPRLAND COMPONENT)
NOTE: This logic now belongs HERE, not under Hyprland. The Hyprland
component should READ the resulting values, not re-prompt.
  
- Locale: menu of common locales + "show all"; write /etc/locale.gen,
  run locale-gen, set LANG in /etc/locale.conf. Also set LC_TIME if
  the user wants a different date format from their language.
- Console keymap: write /etc/vconsole.conf KEYMAP.
- XKB layout/variant: persist for the Hyprland component to consume.
- Timezone: auto-detect, else region/city menu. Symlink /etc/localtime,
  then `hwclock --systohc`.
- All values written to the persistent install config so they can be
  changed later without reinstalling.

### AUR helper (OPT-OUT — INSTALLED BY DEFAULT)
Prompt: "Skip installing yay AUR helper? [y/N]"
  - Default: N (meaning install yay)
  - If user types Y, skip entirely; else proceed with bootstrap
  
Bootstrap manually (no helper can install itself):
  1. Install base-devel and git if not already present
  2. Clone yay from AUR (git clone https://aur.archlinux.org/yay.git)
  3. Run makepkg -si inside the cloned directory
  4. Install into the target system (/mnt), not the live ISO
  
Maintenance caveat (surface in output):
  - Sources conflict on paru's release cadence; one testing article
    reports paru's last release as July 2025 with reported libalpm
    compatibility issues on paru-bin.
  - yay is confirmed shipping releases as of June 2026.
  - Default to yay for stability; offer paru as an explicit
    alternative with the caveat displayed.
  
Rules:
  - Install into a temp dir OUTSIDE /mnt, then remove the build tree
  - Never run an AUR helper as root; build as the new user
  - Record AUR_HELPER=<yay|paru|none> in the install config

### Services to enable
- NetworkManager (network component)
- timesyncd (time component)
- greetd (bootloader component) — coordinated via contract
- bluetooth.service (ONLY if hardware detected)
  
Bluetooth:
  - Install bluez bluez-utils if adapter exists
  - Enable bluetooth.service
  - Don't install or enable blind; waste resources on non-hardware
  
VERIFY each service with `systemctl is-enabled` rather than assuming
the enable command succeeded.

### Optional hardening (prompt, default OFF)
- Firewall: nftables with a minimal default-deny inbound ruleset.
  Consistent with LUKS + Secure Boot posture.
- journald size cap via /etc/systemd/journald.conf.d/
- pacman cache limit via paccache.timer (pacman-contrib)
- ufw as a simpler firewall frontend if the user prefers

### Chroot entry/exit discipline
- Mount /proc, /sys, /dev, /dev/pts, /run before chrooting.
- Verify all five are mounted; abort if any is missing.
- Use arch-chroot so resolv.conf and mounts are handled correctly.
- On exit, unmount in reverse order and verify nothing is still
  mounted under /mnt before declaring completion.

### Persistent install config (accumulating contract)
Keys written by this component:
  HOSTNAME, USERNAME, USER_SHELL, ROOT_PW_SET, KERNEL_PRIMARY,
  KERNEL_FALLBACK, CPU_VENDOR, MICROCODE_PKG, FIRMWARE_PATH,
  FIRMWARE_SUBPKGS, NETWORK_STACK, TIMEZONE, LOCALE, LANG,
  CONSOLE_KEYMAP, XKB_LAYOUT, XKB_VARIANT, AUR_HELPER,
  BLUETOOTH, FIREWALL

Keys read from earlier components:
  firmware type, LUKS on/off, mapper name, swap style, swap location,
  hibernation on/off, GPU vendor

- Formal schema definition belongs to the orchestration component,
  but every key must be validated on read. Abort naming the missing
  key rather than substituting a default silently.

### Hard requirements
- set -euo pipefail; timestamped log.
- NEVER log passwords, passphrases, or LUKS keys.
- Idempotent: re-running must not duplicate users, groups, sudoers
  fragments, or service enables.
- Validate every generated config file with its own checker where one
  exists (visudo -c, locale-gen dry run, systemd-analyze verify).
- No partial upgrades. Ever.
- Final checklist: base installed, kernel(s) present, microcode
  embedded, firmware matched, network stack enabled, user created,
  sudoers validated, locale generated, timezone set, services
  verified, AUR helper state, and all unresolved warnings.

### Edge cases
- Keyring out of date -> refresh archlinux-keyring before pacstrap,
  not after a failure.
- Firmware meta/subpackage collision -> abort with the conflicting
  file list.
- Weak or empty password -> warn, require confirmation, allow
  override but never silently accept.
- Username collides with a system account (e.g. "nobody") -> reject.
- No wifi hardware -> skip iwd, don't enable a service with nothing
  to manage.
- Disk full mid-pacstrap -> detect, report clearly, and instruct the
  user that the install must be restarted from partitioning.
- Fallback kernel requested but UKIs in use -> warn about ESP growth
  before proceeding.
```

---

## Component 3: Bootloader + Initramfs + Login Manager

```text
## COMPONENT: BOOTLOADER + INITRAMFS + LOGIN MANAGER

Goal: Make the installed system bootable, land the user in a Hyprland
session after authentication, and optionally complete Secure Boot.
Prefer official repositories and Wayland-native components throughout.

### Environment assumptions
- Runs INSIDE the chroot (/mnt) after pacstrap and base config.
- Firmware type and LUKS status are READ from the install config,
  never re-detected blindly.
- Single-boot target: no other OS to preserve.

### Firmware branching

UEFI:
  - Bootloader: systemd-boot
  - Secure Boot: AVAILABLE (gated on the toggle below)
  - ESP: separate 1GB FAT32 partition mounted at /boot

BIOS:
  - Bootloader: GRUB (target i386-pc)
  - Secure Boot: NOT AVAILABLE — physically impossible, UEFI-only feature
  - Display a blocking acknowledgement prompt before proceeding:
      "This installer is developed and tested on UEFI systems.
       BIOS/legacy installs are UNTESTED and may fail. Secure Boot
       is not available on BIOS. Continue anyway? [y/N]"
  - Default to N. Require an explicit affirmative.
  - Record BIOS_UNTESTED_ACK=yes in the install config.

### Secure Boot (UEFI only, Option C gating)

Gate: Secure Boot toggle is offered ONLY when UEFI is detected.
On BIOS the toggle is hidden/disabled with explanatory text —
not silently skipped, and not shown as an option that cannot work.

PRE-FLIGHT (before install begins):
  - Install sbctl, run `sbctl status`.
  - Parse for Setup Mode.
  - If Setup Mode is NOT enabled:
      Explain that Setup Mode must be enabled in firmware settings,
      that the procedure differs per manufacturer, and that the
      installer cannot do it.
      Offer three choices:
        (1) Abort — user reboots to firmware, enables Setup Mode,
            re-runs the installer.
        (2) Continue install, DEFER Secure Boot to a separate
            secureboot.sh script run later.
        (3) Continue install WITHOUT Secure Boot.
      Never silently downgrade. Never assume.

SIGNING SEQUENCE (order is mandatory — PK must be enrolled LAST):
  1. Build the UKI (see below)
  2. Sign the UKI
  3. Sign the bootloader binary (systemd-bootx64.efi)
  4. sbctl create-keys
  5. sbctl enroll-keys -m   <- -m is REQUIRED, see note
  6. Instruct user to enable Secure Boot in firmware and reboot
  7. Verify with sbctl status on next boot

WHY -m: Microsoft CA certificates are needed because some hardware
firmware (notably GPU option ROMs) is signed with Microsoft's key.
Omitting -m can produce unbootable hardware. Default to -m and
explain the reason in the output.

SIGNING PATH — pick ONE and document it:
  Path 1 (sbctl):   sbctl sign -s <file>  (records file in sbctl's
                    database for later sbctl sign-all)
  Path 2 (systemd): /usr/lib/systemd/systemd-sbsign sign
                      --private-key <key> --certificate <cert>
                      --output <out> <in>
                    plus bootctl install --secure-boot-auto-enroll yes
                      --certificate <cert> --private-key <key>
  Prefer Path 2 if it works on the target, since it is systemd-native
  and matches the project's native-first rule. Fall back to Path 1.

HARD FAILURE HANDLING (verified real-world failure modes):
  - If sbctl enroll-keys fails with a missing SetupMode efivar, or
    sbctl status reports "system is not booted with UEFI" while in
    Setup Mode, ABORT CLEANLY. Do not proceed to enable Secure Boot.
  - Known affected: some Framework and Lenovo (Lunar Lake) firmware.
  - Print the exact error, state that this is a firmware limitation
    rather than a script bug, and leave the system bootable with
    Secure Boot DISABLED rather than half-configured.
  - Never leave the system in a state where keys are enrolled but
    the boot chain is unsigned.

RE-SIGNING ON UPDATES:
  - Kernel and bootloader updates invalidate signatures. The system
    will fail to boot after an update if re-signing is not automated.
  - sbctl maintains a database of signed files (sbctl sign -s);
    sbctl sign-all re-signs them.
  - Whether sbctl ships a pacman hook for this is UNVERIFIED. The
    script must CHECK for an existing hook and install one if absent,
    rather than assuming either way.
  - Document this prominently in the generated README — this is the
    single most likely way a user bricks their own system later.

KEY BACKUP (mandatory if Secure Boot is enabled):
  - Copy /var/lib/sbctl/keys (or equivalent) to a user-readable
    location and TELL THE USER to back it up externally.
  - State clearly: losing these keys means the system cannot be
    re-signed and Secure Boot must be reset in firmware.

### Initramfs configuration
- DO NOT hardcode a hook array. Read the shipped /etc/mkinitcpio.conf
  and modify in place. Back up to .orig.<timestamp> first.
- If LUKS is enabled, ensure the encryption hook is present and
  correctly ordered relative to filesystem hooks.
- Verify hook names exist in this mkinitcpio version by inspecting
  /usr/lib/initcpio/install/. Fail loudly if a required hook is
  missing rather than producing an unbootable system.
- HIBERNATION: if the systemd hook is present (default on current
  Arch), resume is handled automatically — do NOT add a resume hook
  blindly. Only insert one if the systemd hook is absent.
- Regenerate: mkinitcpio -P

### Kernel command line
- Build ONCE into a single variable, consumed by whichever boot path
  is chosen. Contents:
    * root= using PARTUUID (preferred over /dev nodes)
    * LUKS parameters if encryption is enabled, referencing the
      mapper name from the partitioning component
    * NVIDIA: nvidia_drm.modeset=1 (plus fbdev where applicable)
    * RESUME_SPEC if hibernation was selected (see partitioning)
- UEFI note: systemd can locate the resume device via the
  HibernateLocation EFI variable, so resume= is redundant there.
  Write it anyway — harmless, required on BIOS, and deterministic.
- UKI note: the cmdline is baked into the image. Changing
  resume_offset later requires rebuilding the UKI. Document this.

### Path A: systemd-boot + UKI (UEFI)
- Install systemd-ukify only if assembling UKIs manually.
- bootctl install (ESP already mounted at /boot)
- Convert the mkinitcpio preset to UKI output:
    default_uki="esp/EFI/Linux/arch-linux.efi"
    fallback_uki="esp/EFI/Linux/arch-linux-fallback.efi"
  Confirm the correct ESP path prefix for how /boot is mounted.
- systemd-boot auto-discovers esp/EFI/Linux/*.efi — no manual loader
  entry required.
- Set a sane loader.conf timeout and default.
- Rebuild kernels so the UKIs are produced.
- VERIFY the .efi files exist and are non-trivial in size.

### Path B: GRUB (BIOS)
- grub-install --target=i386-pc <disk>
- grub-mkconfig -o /boot/grub/grub.cfg
- If LUKS is enabled, CONFIRM the generated config actually contains
  the crypt parameters. Do not assume.
- VERIFY grub.cfg exists and references the correct root identifier.

### Login manager: greetd + tuigreet
- Install: greetd greetd-tuigreet  (both in the official extra repo)
- Configure /etc/greetd/config.toml with tuigreet as the greeter
  command, pointed at the Hyprland session.
- Enable greetd.service.
- Ensure a Wayland session desktop entry exists so the session is
  discoverable by the greeter.
- Expose configure_session_start() as the SINGLE integration point
  consumed by the Hyprland component. Do not duplicate session-launch
  logic in two places.
- Note: tuigreet is a console/TUI greeter, not graphical. It is
  Wayland-session-aware and pulls in no Qt or X11 stack.

### Coupling contract
READS: firmware type, BIOS_UNTESTED_ACK, LUKS on/off, mapper name,
       root PARTUUID, GPU vendor, hibernation on/off, swap style,
       swap location, username, secureboot on/off.
PROVIDES: configure_session_start() to the Hyprland component.
Validate every value read; abort naming the missing key if absent.

### Hard requirements
- set -euo pipefail; timestamped log.
- Idempotent: no duplicate boot entries, no corrupted loader config.
- Back up every file before modifying it.
- Never declare success without verifying artifacts on disk.
- Final checklist: bootloader installed, UKI or entries present,
  initramfs regenerated, greetd enabled, session entry found,
  Secure Boot state (enabled / deferred / declined / failed),
  and all unresolved warnings.

### Edge cases
- ESP too small for UKIs -> detect free space, warn, suggest GRUB
  with traditional initramfs instead of failing mid-build.
- Missing encryption hook -> abort before regenerating initramfs.
- Secure Boot firmware bugs -> abort cleanly, leave system bootable
  with SB disabled (see HARD FAILURE HANDLING).
- Chroot lacking /proc, /sys, /dev mounts -> verify before running
  bootctl or grub-install.
- BIOS path -> the untested-acknowledgement gate must have been
  passed; assert BIOS_UNTESTED_ACK=yes or refuse.
```

---

## Component 4: Hyprland Desktop Environment

```text
## COMPONENT: DESKTOP ENVIRONMENT (HYPRLAND)

Goal: install and configure a Hyprland Wayland session on Arch Linux,
preferring official repositories and Wayland/Hyprland-native software
at every choice point. AUR use is a last resort and must be isolated
in a clearly marked function.

### Environment assumptions
- Running from the Arch live ISO, network already connected.
- Target system is systemd-based (do NOT install elogind).
- Script runs as root or via sudo; define a USERNAME variable early
  and use it consistently for user-level config and systemctl --user.

### Package groups (install from official repos)

Core compositor:
  hyprland hyprcursor hyprutils hyprlang hyprgraphics

Hypr ecosystem utilities:
  hyprlock hypridle hyprpaper hyprpicker hyprpolkitagent

Portals and Wayland plumbing:
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  wl-clipboard xorg-xwayland (compat layer for legacy X11 apps only)

Desktop shell components (WAYLAND-NATIVE FIRST):
  waybar mako fuzzel kitty

Media and utilities:
  pipewire pipewire-pulse pipewire-alsa wireplumber
  grim slurp wf-recorder playerctl brightnessctl

### GPU support (detect and branch)
- Detect vendor from lspci.
- AMD: mesa, vulkan-radeon, libva-mesa-driver, mesa-vdpau
- Intel: mesa, vulkan-intel, intel-media-driver, libva-intel-driver
- NVIDIA: nvidia-open-dkms (or nvidia-dkms), nvidia-utils,
  libva-nvidia-driver, egl-wayland
- NVIDIA-specific requirements:
    * kernel parameter nvidia_drm.modeset=1
    * add nvidia_drm.fbdev=1 where applicable
    * set env vars in the Hyprland config:
        LIBVA_DRIVER_NAME=nvidia
        __GLX_VENDOR_LIBRARY_NAME=nvidia
        GBM_BACKEND=nvidia-drm
- Multi-GPU / hybrid laptops: detect and warn, do not guess.
- Print a summary of what was detected and installed; allow override.

### Input handling (auto-detect, user-overridable in installer)
- Detect keyboard layout candidates from the live environment;
  present a selection menu (console keymap + XKB layout + variant).
- Persist: /etc/vconsole.conf KEYMAP, and the Hyprland config
  input section kb_layout / kb_variant.
- Locale: present a menu of common locales plus a "show all" option;
  write /etc/locale.gen, run locale-gen, set LANG in /etc/locale.conf.
- Timezone: auto-detect via timedatectl/geoip if available, otherwise
  present a region/city menu. Set /etc/localtime and hwclock.
- All three must be changeable later without reinstalling: write the
  values to a persistent config the script can re-read on re-run.

### Session start at login
- Requirement: Hyprland starts automatically at login.
- Implementation depends on the display manager chosen in the
  LOGIN MANAGER component (decoupled via configure_session_start()).
- Ensure a Wayland session desktop entry exists and that the DM
  selects it by default.

### Config generation (Lua format, Hyprland 0.55+)
- CRITICAL: Generate ~/.config/hypr/hyprland.lua using Lua scripting
  (hl.bind(...) API), NOT hyprland.conf (deprecated).
- Use the upstream Lua API; do not hand-write legacy hyprlang syntax.
- Companion configs to generate: hypridle.conf, hyprlock.conf,
  hyprpaper.conf, waybar config + style.css, mako config,
  fuzzel.ini, kitty.conf.
- Autostart entries: waybar, hyprpaper, mako, hyprpolkitagent
  (systemctl --user start hyprpolkitagent), hypridle.
- Bind SUPER+L to hyprlock, and configure hypridle to lock then
  suspend on idle.
- SUPER+Return binds to kitty.
- SUPER space binds to fuzzel (app launcher).

### Lock screen fallback
- Primary: hyprlock.
- Fallback: swaylock (maintained, Wayland-native, ext-session-lock-v1).
- Do NOT use swaylock-effects: upstream is unmaintained.
- Detect at runtime whether a usable hyprlock config exists; if not,
  fall back rather than leaving the session unlockable.

### Audio
- Enable pipewire, pipewire-pulse, wireplumber for the user.
- Verify the user services are enabled and report status.
- Do not require a reboot to validate: check with pactl/wpctl.

### Hard requirements for this component
- set -euo pipefail; every install step logged to a timestamped file.
- Idempotent: re-running must not duplicate config blocks or fail.
- Never overwrite an existing user config without backing it up to
  <file>.bak.<timestamp>.
- Fail loudly with a clear message if a package is unavailable,
  listing the exact package name.
- No silent AUR usage; if AUR is required, print a warning and
  require explicit confirmation.
- At the end, print a verification checklist: packages installed,
  configs written, services enabled, detected GPU, and any warnings.
```

---

## Component 5: Orchestrator (Entry Point + Config Schema)

```text
## COMPONENT: ORCHESTRATOR (ENTRY POINT + CONFIG SCHEMA)

Goal: Coordinate all components in the correct sequence, manage the
persistent configuration that flows between them, handle failures
gracefully, and provide a user-facing interface (CLI menu or prompts).
Single entry point with modular components.

### Design principles
- Single source of truth: /tmp/install-config.yaml (or .json)
- Each component is a source file that can be sourced independently
- Idempotency: re-running the installer can resume from checkpoints
- Dry-run mode: show what WILL happen without executing
- Fail-fast with clear error messages and recovery instructions
- All state persisted to install-config.yaml after each major step

### Directory structure
```
installer/
├── install.sh           # Main entry point
├── config.schema.yaml   # Schema definition (validation rules)
├── config.yaml          # Persistent config (generated during install)
├── components/
│   ├── _common.sh       # Utility functions shared by all
│   ├── 01_partitioning.sh
│   ├── 02_base_system.sh
│   ├── 03_bootloader.sh
│   └── 04_hyprland.sh
├── hooks/               # Optional extension points
│   ├── pre-partitioning.sh
│   ├── post-install.sh
│   └── ...
├── logs/
│   └── install-$(date +%Y%m%d-%H%M%S).log
└── README.md            # Generated post-install
```

### Persistent config schema (install-config.yaml)

```yaml
# FORMAT: YAML (human-readable, editable manually if needed)
# LOCATION: Written to /tmp first, copied to /mnt/etc/install-config.yaml
#           on successful completion for future reference

version: "1.0"
timestamp: "2026-10-31T14:30:00Z"

# FIRMWARE DETECTION
firmware_type: "uefi"          # "uefi" | "bios"
uefi_verified: true            # Was EFI boot verified?
secure_boot_capable: true      # Does firmware support it?
secure_boot_enabled: false     # Did user enable it?

# DISK AND PARTITIONS
target_device: "/dev/nvme0n1"  # User-selected disk
luks_enabled: true             # Full-disk LUKS?
luks_mapper_name: "luks-root"  # Derived device name
luks_passphrase_hash: "<hash>" # NEVER store plaintext
luks_acknowledged: true        # User acknowledged data destruction

partitions:
  - mount: "/boot"
    device: "/dev/nvme0n1p1"
    size: "1GB"
    fs: "vfat32"
    type: "efi"
  - mount: "/"
    device: "/dev/nvme0n1p2"
    size: "Rest"
    fs: "btrfs"
    encrypted: true
    lvm: false                 # LVM disabled per design

swap_configuration:
  style: "zram_swapfile"       # See choices below
  hibernate_enabled: false     # Off by default
  swapfile_size_gb: 8
  zram_compression: "zstd"
  hibernate_resume_spec: ""    # Populated if hibernation yes

# KERNEL
kernel_primary: "linux-zen"    # User-selected
kernel_fallback: "linux"       # Stock for recovery
microcode_package: "intel-ucode" # Detected CPU vendor

# NETWORK
network_stack: "networkmanager" # "networkmanager" | "systemd-networkd"
wifi_backend: "iwd"             # Always iwd when possible

# USER AND ACCESS
hostname: "hyprland-workstation"
primary_user: "alice"
primary_user_shell: "/bin/bash"
root_password_set: true
sudo_wheel_group: true         # Standard %wheel sudoers

# LOCALIZATION
locale: "en_US.UTF-8"
console_keymap: "us"
xkb_layout: "us"
xkb_variant: ""
timezone: "America/New_York"

# AUR HELPER
aur_helper: "yay"              # "yay" | "paru" | "none"
aur_bootstrap_skipped: false   # Did user skip bootstrap?

# HYPRLAND AND DESKTOP
hyprland_version: "0.55+"      # Detected or assumed
hyprland_config_format: "lua"  # "lua" | "conf" (we chose lua)
app_launcher: "fuzzel"
lock_screen: "hyprlock"
lock_fallback: "swaylock"
polkit_agent: "hyprpolkitagent"
waybar_config: true
notification_daemon: "mako"
audio_stack: "pipewire"
lock_autostart: true           # Start Hyprland at login via greetd

# SECURITY (OPTIONAL)
firewall_enabled: false        # Default OFF, opt-in
journal_size_limit_mb: 500     # Prevent log growth
pacman_cache_limit_gb: 2

# BOOTLOADER
bootloader_type: "systemd-boot" # "systemd-boot" | "grub" | "limine"
uki_enabled: true              # Unified kernel images?
sbctl_installed: false         # Key manager installed
secure_boot_keys_enrolled: false # Keys in firmware?
grub_target: ""                # For BIOS: target device path

# COMPONENT CHECKPOINTS
checkpoints:
  partitioning_complete: false
  base_system_complete: false
  bootloader_complete: false
  hyprland_complete: false
  install_complete: false

# WARNINGS AND ACKNOWLEDGMENTS
bios_untested_acknowledged: false  # If BIOS: explicit OK
firmware_confirmed_uefi: true      # If claimed UEFI
key_backup_reminded: false         # Secure Boot reminder
hibernation_tested: false          # User hasn't tested yet

# HARDWARE DETECTION OUTPUT
detected_gpu_vendor: "amd"         # "intel" | "amd" | "nvidia" | "unknown"
detected_cpu_vendor: "intel"       # "intel" | "amd"
detected_ram_gb: 32
detected_wifi_chipset: "rtl8852"   # Vendor/model if known
dual_gpu_detected: false           # Integrated + discrete
```

### Component sequencing (dependency graph)

```
┌─────────────────────────────────────────────────────────────┐
│                    INSTALL START                            │
│  - Pre-flight: network, firmware mode, disk detection       │
│  - Load or initialize install-config.yaml                   │
│  - Run pre-partitioning hooks (if any)                      │
└───────────────────────┬─────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  1. PARTITIONING                                            │
│  - Detect and validate target disk                          │
│  - Branch on firmware type (UEFI → systemd-boot, BIOS → GRUB)│
│  - Create partitions (LUKS if enabled, swap style from menu) │
│  - Format filesystems (btrfs, vfat32 for ESP)               │
│  - Mount hierarchy (/mnt, /mnt/boot, etc.)                  │
│  - Write firmware type and partition IDs to config          │
│  ✓ Checkpoint: partitioning_complete                        │
└───────────────────────┬─────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  2. BASE SYSTEM                                             │
│  - Mount /proc, /sys, /dev, /dev/pts, /run                  │
│  - Select mirrors, verify keyring                           │
│  - pacstrap base + kernel + microcode + network stack      │
│  - chroot, create user, set locale/timezone/hostname       │
│  - Enable services (NetworkManager, timesyncd)             │
│  - Bootstrap AUR helper (yay) if not skipped               │
│  - Write identity config to /etc                           │
│  - Exit chroot, unmount, checkpoint                       │
│  ✓ Checkpoint: base_system_complete                         │
└───────────────────────┬─────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  3. BOOTLOADER + INITRAMFS                                  │
│  - Re-enter chroot                                          │
│  - Configure mkinitcpio (hooks, microcode order)           │
│  - Build initramfs for both kernels (main + fallback)      │
│  - Install bootloader:                                     │
│    * UEFI: systemd-boot, configure UKI paths              │
│    * BIOS: grub-install (i386-pc), grub-mkconfig           │
│  - Set kernel cmdline (root=, LUKS, GPU params, resume=)  │
│  - If Secure Boot:                                        │
│    * Verify Setup Mode pre-flight                        │
│    * Build/sign UKIs with sbctl or systemd-sbsign       │
│    * Enroll keys (-m mandatory for Microsoft CA)        │
│    * Warn about firmware bug risk (Framework/Lenovo)    │
│  - Verify boot entry exists                               │
│  - Exit chroot, checkpoint                              │
│  ✓ Checkpoint: bootloader_complete                          │
└───────────────────────┬─────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  4. HYPRLAND                                                │
│  - Re-enter chroot                                          │
│  - Install desktop packages (official repos only)          │
│  - Generate configs:                                       │
│    * ~/.config/hypr/hyprland.lua (Lua API, not .conf)     │
│    * hypridle.conf, hyprlock.conf, fuzzel.ini            │
│    * waybar, mako, kitty, pipewire configs               │
│    * xdg-desktop-portal-hyprland config                  │
│  - Configure greetd + tuigreet:                          │
│    * /etc/greetd/config.toml                             │
│    * enable greetd.service                               │
│  - Set up autostart: waybar, hyprpaper, mako, polkit    │
│  - Configure idle actions (lock, suspend/hibernate)     │
│  - Apply input/locale settings from base config         │
│  - Exit chroot, checkpoint                            │
│  ✓ Checkpoint: hyprland_complete                            │
└───────────────────────┬─────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  POST-INSTALL                                               │
│  - Generate README.md with hardware summary                │
│  - Copy install-config.yaml to /mnt/etc/ for reference    │
│  - Print reboot instructions                              │
│  - Remind about:                                         │
│    * Testing hibernation if enabled                       │
│    * Backing up Secure Boot keys (if enabled)            │
│    * Updating kernels triggers UKI re-signing            │
│    * Checking /var/log/install-*.log for issues          │
│  ✓ Checkpoint: install_complete                             │
└─────────────────────────────────────────────────────────────┘
```

### Error handling and rollback strategy

| Scenario | Recovery Path |
|---|---|
| **Partitioning fails mid-way** | User must reboot into live ISO and manually wipe partitions; no automatic rollback (partial partitions are unsafe) |
| **Base system install fails** | Re-run from checkpoint 1; re-partitioning not required if mount points intact |
| **Bootloader fails** | Check ESP size, verify bootctl/grub commands, re-run component 3 only |
| **Secure Boot setup fails** | Document firmware bug possibility; fall back to unsecured boot; user can retry later |
| **Chroot environment broken** | Remount, verify mounts, re-enter; may need to re-pacstrap if corruption occurred |
| **Final system won't boot** | Use fallback kernel; if UKI-signed and signed incorrectly, disable Secure Boot in firmware temporarily |

### Pre-flight checks (must pass before install begins)

```text
CHECKLIST (failures abort with explanation):
  [ ] Network connectivity (ping archive.archlinux.org)
  [ ] Time synchronized (timedatectl status shows synced)
  [ ] Target disk detected (lsblk shows selection)
  [ ] Firmware mode detected (/sys/firmware/efi exists)
  [ ] If BIOS: user acknowledged untested warning
  [ ] If Secure Boot requested: sbctl status shows Setup Mode
  [ ] Sufficient RAM for compilation (yay bootstrap needs ~2GB)
  [ ] Enough disk space for targets (≥20GB free on target)
  [ ] Keyring current (pacman-key --verify succeeds)
  [ ] Target not mounted (lsblk -f shows clean state)
  [ ] User confirmed data destruction on target
```

### Dry-Run Mode

When `--dry-run` is specified:
- Parse all prompts and selections WITHOUT writing to disk
- Show predicted partition layout, package list, services to enable
- Print estimated disk space usage (base + kernel + desktop)
- Output the install-config.yaml that would be written
- List all warnings that would be presented during real install
- Never run pacstrap, never touch partitions, never enable services

### Graceful Exit Handler

Trap SIGINT and SIGTERM to clean up before exit:

```bash
trap 'cleanup_and_exit' EXIT INT TERM

cleanup_and_exit() {
  # Unmount if chroot is active
  # Verify no orphaned mounts under /mnt
  # Write checkpoint state to config
  # Inform user where they left off
  # Exit with appropriate code (0=success, 1=cancelled, 2=error)
}
```

### Script Entry Point Skeleton (install.sh)

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE

source "${SCRIPT_DIR}/components/_common.sh"
source "${SCRIPT_DIR}/config.schema.yaml"  # Validate schema

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --resume) RESUME=1 ;;
    --skip-aur) SKIP_AUR=1 ;;
    --config) CONFIG_FILE="$2"; shift ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# Main execution flow
main() {
  log_info "Starting Hyprland Arch Installer v1.0"
  
  if ! pre_flight_checks; then
    log_error "Pre-flight checks failed. Fix issues and re-run."
    exit 1
  fi
  
  if [[ "${RESUME:-}" == "1" ]]; then
    load_checkpoint_state || log_warn "No checkpoint found, starting fresh"
  fi
  
  if [[ -z "${CHECKPOINTS.partitioning_complete:-}" ]]; then
    log_info "Step 1/4: Partitioning"
    source "${SCRIPT_DIR}/components/01_partitioning.sh"
    run_partitioning
    write_checkpoint "partitioning_complete"
  fi
  
  if [[ -z "${CHECKPOINTS.base_system_complete:-}" ]]; then
    log_info "Step 2/4: Base System"
    source "${SCRIPT_DIR}/components/02_base_system.sh"
    run_base_system
    write_checkpoint "base_system_complete"
  fi
  
  if [[ -z "${CHECKPOINTS.bootloader_complete:-}" ]]; then
    log_info "Step 3/4: Bootloader"
    source "${SCRIPT_DIR}/components/03_bootloader.sh"
    run_bootloader
    write_checkpoint "bootloader_complete"
  fi
  
  if [[ -z "${CHECKPOINTS.hyprland_complete:-}" ]]; then
    log_info "Step 4/4: Hyprland Desktop"
    source "${SCRIPT_DIR}/components/04_hyprland.sh"
    run_hyprland
    write_checkpoint "hyprland_complete"
  fi
  
  generate_post_install_readme
  log_info "Install complete. Reboot when ready."
}

main "$@"
```

---

## Component 6: ISO Baking (Custom Live Environment)

```text
## COMPONENT: CUSTOM ARCH ISO WITH PRE-INSTALLED HYPRLAND

Goal: Create a bootable Arch Linux ISO that includes the Hyprland
flavor pre-installed, so users can boot directly into the configured
desktop environment without running the installer.

This transforms the installer into a LIVE ENVIRONMENT, allowing:
1. Immediate testing before committing to disk installation
2. Offline installation (all packages pre-loaded)
3. Distribution of the custom flavor as a ready-made image

### Tools Required

Primary tool: **archiso** (official Arch tool for building ISOs)

Installation on host system:
  sudo pacman -S archiso

Alternative: manual ISO construction via syslinux/grub/isolinux
(Not recommended — archiso handles all edge cases)

### Directory Structure for ISO Build

```
custom-hyprland-iso/
├── profiledef.sh           # Profile metadata
├── airootfs/              # Custom root overlay
│   ├── root/              # Root user home
│   ├── etc/               # Custom config files
│   └── usr/share/...      # Icons, themes, etc.
├── packages.x86_64        # Package list for live system
├── builder.config         # Build settings
└── hooks/                 # Pre/post build scripts
```

### Package List (packages.x86_64)

Essential packages to include in the ISO (all from official repos):

```text
# Base system
base base-devel linux-zen linux-firmware linux intel-ucode amd-ucode

# Desktop environment
hyprland hyprcursor hyprutils hyprlang hyprgraphics
hyprlock hypridle hyprpaper hyprpicker hyprpolkitagent
waybar mako fuzzel kitty pipewire wireplumber

# Networking
networkmanager iwd wpa_supplicant

# Utilities
git sudo reflector man-db

# Arch installation tools (for disk installer)
arch-install-scripts archiso

# Fonts
ttf-dejavu ttf-liberation noto-fonts
```

**Total ISO size estimate:** ~1.5–2GB (compressed)

### profiledef.sh

```bash
#!/bin/bash
# Profile definition for custom Hyprland ISO

dir_name="arch-hyprland-custom"
profile_name="Arch Hyprland Custom Flavor"
profile_description="Custom Arch Linux with Hyprland pre-installed"
archiso_version="unknown"

# Root filesystem overlay
airootfs_dir="${PROFILE_BASE}/airootfs"

# Packages to install in live environment
packages_file="${PROFILE_BASE}/packages.x86_64"

# Custom syslinux/syslinux-efi config (optional)
custom_syslinux_cfg="${PROFILE_BASE}/syslinux/custom.cfg"

# Boot options
syslinux_default_timeout="10"

# Label for the ISO
iso_label="ARCH_HYPRLAND"
```

### airootfs Overlay Configuration

Create custom configuration files that appear in the live environment:

**/airootfs/etc/xdg/autostart/hyprland.desktop**
```ini
[Desktop Entry]
Type=Application
Exec=Hyprland
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Hyprland
Comment=Start Hyprland Wayland compositor
```

**/airootfs/root/.bashrc** (custom live environment welcome message)
```bash
echo "Welcome to Arch Hyprland Custom Flavor!"
echo "Run 'install-hyprland' to begin installation to disk."
echo "Or use the desktop directly to test the environment."
```

**/airootfs/usr/bin/install-hyprland** (symlink to the installer)
```bash
#!/bin/bash
exec /opt/installer/install.sh "$@"
```

### Builder Configuration

```bash
# builder.config
ISO_TYPE="hybrid"              # UEFI + BIOS bootable
COMPRESSION="xz"               # Compress the ISO
INCLUDE_PKGMGR="yes"           # Include pacman in live env
INCLUDE_NETWORK="yes"          # Network managers enabled
```

### Build Process

```bash
# 1. Navigate to the profile directory
cd custom-hyprland-iso/

# 2. Build the ISO
sudo mkarchiso -v -w /tmp/work_dir -o /tmp/output .

# 3. Output location
# ISO will be in /tmp/output/arch-hyprland-custom-x86_64.iso
```

### Adding the Installer to the ISO

Copy the installer scripts into the ISO:

```bash
# Inside airootfs structure
mkdir -p airootfs/opt/installer/
cp -r ../../installer/* airootfs/opt/installer/
chmod +x airootfs/opt/installer/install.sh
```

### Testing the ISO Before Distribution

```bash
# 1. Test in QEMU (virtual machine)
qemu-system-x86_64 -cdrom arch-hyprland-custom-x86_64.iso -m 4G

# 2. Test in VirtualBox/VMware
# Load the ISO as virtual optical drive

# 3. Write to USB and test on real hardware
sudo dd if=arch-hyprland-custom-x86_64.iso of=/dev/sdX bs=4M status=progress
sync
```

### Custom Boot Menu Configuration

Create /airootfs/etc/brltty/themes/hyprland-theme or use isolinux/syslinux:

**syslinux/custom.cfg**
```text
DEFAULT menu.c32
MENU TITLE Arch Hyprland Custom Boot Menu

TIMEOUT 50

LABEL arch-hyprland
  MENU LABEL Boot Arch Hyprland (Live)
  LINUX /arch/boot/x86_64/vmlinuz-linux-zen
  INITRD /arch/boot/x86_64/intel-ucode.img, /arch/boot/x86_64/amd-ucode.img, /arch/boot/x86_64/initramfs-linux-zen.img
  APPEND img_dev= /img_path=/ archisobasedir=%INSTALL_DIR% config=/airootfs/etc/arch-install/config
  TEXT HELP
  Boot the Arch Hyprland live environment.
  Allows you to test before installing to disk.
  TEXT END

LABEL install
  MENU LABEL Install to Disk
  LINUX /arch/boot/x86_64/vmlinuz-linux-zen
  INITRD /arch/boot/x86_64/initramfs-linux-zen.img
  APPEND img_dev= /img_path=/ archisobasedir=%INSTALL_DIR%
  TEXT HELP
  Begin installation to disk.
  TEXT END
```

### Distribution Considerations

| Aspect | Recommendation |
|---|---|
| **ISO signing** | GPG-sign the ISO for verification |
| **Checksums** | SHA256SUMS file included in download |
| **Release notes** | Include CHANGELOG.md with version history |
| **Documentation** | README.md with installation instructions |
| **Update cycle** | Monthly ISO rebuilds with latest packages |

### Security Considerations

- Do NOT include passwords in the ISO (live user is ephemeral)
- Do NOT store private keys or tokens in airootfs
- The live environment should be read-only except /tmp
- Document that the live user session is wiped on reboot

### Post-Install Cleanup

After successful installation from ISO, the user should:
1. Remove the ISO from USB/optical drive
2. Reboot into the newly installed system
3. Verify Secure Boot keys if enabled
4. Test hibernation if configured

---

## Decision Summary Table

| Topic | Decision | Rationale |
|---|---|---|
| **Kernel primary** | linux-zen | Desktop responsiveness optimization |
| **Kernel fallback** | linux (stock) | Recovery path if zen regresses |
| **Shell** | bash | Standard Arch default |
| **Network stack** | NetworkManager + iwd | Better roaming, waybar integration |
| **Swap style** | zram + swap file (hybrid) | Best performance + hibernate support |
| **Hibernation** | Off by default, toggle | Conservative, avoids complexity |
| **LUKS** | Optional toggle | Balance security vs. convenience |
| **Filesystem** | btrfs | Subvolumes, snapshot-ready |
| **LVM** | Skip (optional toggle) | Not needed with swap file approach |
| **ESP size** | 1GB | Accommodate UKIs + fallback |
| **Secure Boot** | Opt-in, gated on UEFI | Matches privacy/security posture |
| **Bootloader** | systemd-boot (UEFI) / GRUB (BIOS) | Native where possible, fallback elsewhere |
| **Login manager** | greetd + tuigreet | Official repo, Wayland-native, no Qt |
| **Config format** | Lua (hyprland.lua) | Current standard since Hyprland 0.55 |
| **App launcher** | fuzzel | Modern, fast, Wayland-native |
| **Lock screen** | hyprlock + swaylock fallback | Native first, maintained fallback |
| **AUR helper** | yay (opt-out default) | Stability over paru (maintenance concerns) |
| **Firmware packages** | Hardware-detected subpackages | Reduce footprint, avoid collisions |

---

## Final Checklist

### Pre-Install Verification

- [ ] Hardware detected correctly (GPU, WiFi, CPU)
- [ ] Firmware mode identified (UEFI vs BIOS)
- [ ] Secure Boot Setup Mode verified if enabled
- [ ] Target disk confirmed (no accidental data loss)
- [ ] Network connectivity for pacstrap
- [ ] RAM >= 2GB for AUR helper bootstrap

### During Install Verification

- [ ] Partition table written correctly
- [ ] LUKS opens successfully (if enabled)
- [ ] fstab validates (mount -a simulation)
- [ ] pacstrap completes without errors
- [ ] User created successfully
- [ ] sudoers validates (visudo -c)
- [ ] Bootloader installed and verified
- [ ] Hyprland configs generated
- [ ] greetd service enabled
- [ ] All services verified (systemctl is-enabled)

### Post-Install Verification

- [ ] Reboot into new system successful
- [ ] Login manager presents tuigreet
- [ ] Authentication launches Hyprland
- [ ] Waybar displays correctly
- [ ] Network connects via NetworkManager
- [ ] Audio works via pipewire
- [ ] Terminal (kitty) opens properly
- [ ] App launcher (fuzzel) responds
- [ ] Lock screen (hyprlock) functions
- [ ] Fallback kernel boots if primary fails
- [ ] Secure Boot status verified (if enabled)
- [ ] Install logs reviewed for warnings

### Optional Validation Tests

- [ ] Hibernation test (if enabled): systemctl hibernate
- [ ] Snapshot rollback test (if btrfs + snapper configured)
- [ ] Kernel update test: verify UKIs re-signed
- [ ] Network roaming test (laptop): switch networks
- [ ] Bluetooth test: pair device
- [ ] Screenshot test: grim + slurp

---

## Support & Documentation Locations

| Resource | Location |
|---|---|
| **Install logs** | /var/log/install-*.log |
| **Config backup** | /etc/install-config.yaml |
| **Hyprland configs** | ~/.config/hypr/ |
| **greetd config** | /etc/greetd/config.toml |
| **Original configs** | /etc/*.orig.* (backups) |
| **User documentation** | /etc/install-readme.txt |
| **AUR helper** | yay (or paru if selected) |
| **Arch Wiki** | https://wiki.archlinux.org |
| **Hyprland Wiki** | https://wiki.hyprland.org |

---

## Revision History

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-10-31 | Initial complete specification |

---

*End of Specification*