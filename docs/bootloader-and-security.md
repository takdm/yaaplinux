# Bootloader, Storage Security & Login

This document covers the encrypted-storage, snapshot, bootloader, Unified
Kernel Image, Secure Boot, and login-manager subsystems. It is grounded in
`stages/10-partition.sh`, `stages/20-format.sh`, `stages/30-mount.sh`,
`stages/50-base-config.sh`, `stages/80-bootloader.sh`, `stages/90-postinstall.sh`,
and the referenced asset files.

> Stage 80 is annotated in-code as *"the most fragile stage; do after the rest
> works. Secure Boot enrolment failure must leave a bootable unsigned system"*
> (spec §10.3).

---

## 1. Encrypted root: LUKS2 + btrfs

### 1.1 LUKS2 container (`stages/10-partition.sh`)

Partition layout (GPT, always):

| Partition | Type | Size | Notes |
|---|---|---|---|
| 1 | `ef00` EFI System | `esp_size_for()` | 1024 MiB if UKIs on, else 512 MiB |
| 2 | `ef02` BIOS boot | 1 MiB | **BIOS firmware only** |
| root | `8300` Linux filesystem | remainder | partition 3 on BIOS, 2 on UEFI |

When `disk.luks.enabled == true`, the root partition is opened as a LUKS2
container before formatting:

```
cryptsetup luksFormat --type luks2 \
  --cipher <disk.luks.cipher, default aes-xts-plain64> \
  --key-size   <disk.luks.key_size, default 512> \
  --pbkdf argon2id
```

- Mapper name from `disk.luks.mapper_name` (default `cryptroot`).
- **Interactive:** prompts for the passphrase (`ui_input`).
- **Unattended:** generates a random passphrase
  (`head -c 64 /dev/urandom | base64 | head -c 44`), persists it to
  `$YAAP_LUKS_PASSPHRASE_FILE` (`/var/lib/yaaplinux/luks-passphrase`), and later
  publishes it as an ESP keyfile (see §1.4). The passphrase is **never**
  discarded here — doing so would brick the post-reboot LUKS prompt.
- **Optional TPM2 auto-unlock** (gated by `hardware.secure_boot.tpm2_auto_unlock`
  + a confirmation): `systemd-cryptenroll --tpm2-device=auto --wipe-slot=password`
  — warns and keeps passphrase-only if enrolment fails. The code notes this
  *weakens physical-attack protection unless a PIN is added*.

### 1.2 btrfs subvolumes (`stages/20-format.sh`, `stages/30-mount.sh`)

btrfs is created on the (LUKS-mapped, if enabled) root device and mounted on a
temp dir to materialise subvolumes read from `disk.subvolumes`
(default `@ @home @swap @snapshots`):

```
@          /
@home      /home
@swap      /swap
@snapshots /.snapshots
```

Mount options (`_mount_opts`): `noatime,compress=zstd:3,space_cache=v2`.

`/etc/fstab` (written in stage 30, regenerated via `genfstab` in stage 40):

```
UUID=<root>  /          btrfs  noatime,compress=zstd:3,space_cache=v2            0 1
UUID=<root>  /home      btrfs  …,subvol=@home                                   0 1
UUID=<root>  /swap      btrfs  …,subvol=@swap                                   0 1
UUID=<root>  /.snapshots btrfs …,subvol=@snapshots                              0 1
UUID=<esp>   /boot/efi  vfat   umask=0077                                       0 1
```

### 1.3 Swap: zram + btrfs swapfile, hibernation & resume_offset

The swap **style** is config-declared (`disk.swap.style`, default
`zram_plus_file`; alternatives `partition`, `none`), with `disk.swap.zram_percent`
(default 50) for the runtime zram component and `disk.swap.file_size_gb`
(default 8) for the file.

The installer's concrete work happens **only when `disk.swap.hibernation ==
true`** (stage 20 `create_swapfile`):

1. Creates the swapfile inside the `@swap` subvolume with **CoW disabled**
   (`chattr +C`) — mandatory for a btrfs swapfile — via
   `btrfs filesystem mkswapfile --size <N>GiB` (falls back to `fallocate`+`mkswap`).
2. Computes a stable physical offset:
   `btrfs inspect-internal map-swapfile -r <file>` → stored as
   `disk.swap.resume_offset` (warns if it cannot be computed).
3. Stage 30/40 append `/swap/swap none swap defaults 0 0` to `/etc/fstab`
   (only for `zram_plus_file` + hibernation).
4. Stage 50 writes `/etc/initramfs.conf.d/resume.conf`:
   `RESUME=UUID=<luks_or_root_uuid>` and `RESUME_OFFSET=<off>`, and adds the
   `resume` hook to mkinitcpio.
5. Stage 80 folds `resume=UUID=<ruuid> resume_offset=<off>` into the UKI
   cmdline.

> **zram itself is not provisioned by an installer stage** — no `zramctl` /
> `systemd-zram-setup` call exists in the stages. `zram_plus_file` names zram as
> the runtime-swap component and the btrfs swapfile as the hibernation
> component; the swapfile + resume wiring above is what the installer actually
> implements.

### 1.4 Unattended LUKS keyfile (stage 30)

When `disk.luks.unattended == true`, stage 30 copies the staged passphrase to
the **unencrypted ESP** at `/boot/efi/keys/<mapper>.key` (mode 600). This makes
the system unlockable after reboot, at the documented cost of weakening
physical-attack protection. The post-install report flags it as a manual
follow-up (move/delete after first boot).

---

## 2. Snapshots: snapper (`stages/90-postinstall.sh`, `assets/`)

Gated by `disk.snapshots.enabled == true`; tool from `disk.snapshots.tool`
(default `snapper`, alt `timeshift`).

**snapper path:**

```
pkg_install snapper
snapper -c root createconfig -r /          # writes /etc/snapper/configs/root
systemctl enable snapper-timeline.timer snapper-cleanup.timer
```

The reference config (`assets/snapper-root.conf`, installed to
`/etc/snapper/configs/root`) key values:

| Key | Value |
|---|---|
| `CREATE_NUMBER` / `CREATE_PERIOD` | `10` / `1h` |
| `NUMBER_LIMIT` | `50` |
| `TIMELINE_LIMIT_HOURLY` / `DAILY` | `10` / `10` |
| `CLEANUP` | `number` |
| `EMPTYSNAPSHOTS` / `TIMELINE_CREATE` | `true` |

**Pacman hooks** (installed to `/etc/pacman.d/hooks/` in stage 50):

| Hook | Trigger | Action |
|---|---|---|
| `50-snapper-pre.hook` | Install/Upgrade, package | `snapper -c root create --description "pre …" --cleanup-action delete` (before the transaction) |
| `50-snapper-post.hook` | Install/Upgrade, package | `snapper -c root create --description "post …"` + `snapper -c root cleanup` (after the transaction) |

These give a pre/post snapshot pair around every package transaction for clean
rollbacks. `disk.snapshots.boot_integration: true` in the config declares the
intent of bootable snapshots (see [Troubleshooting](troubleshooting.md) for the
rollback method).

> **timeshift path:** `pkg_install timeshift` and a note that interactive setup
> is recommended post-boot.

---

## 3. Bootloader: systemd-boot vs GRUB (`stages/80-bootloader.sh`)

Firmware branch resolved in preflight. On **BIOS** the stage first requires an
acknowledgement that Secure Boot is unavailable
(`bootloader.bios_warning_acknowledged` — hard-fails in unattended mode if not
set).

### 3.1 UEFI path — always systemd-boot

```
pkg_install systemd efibootmgr
bootctl install
```

- Writes `/boot/efi/loader/loader.conf`:
  ```
  default arch-linux-zen.conf
  timeout 5
  editor off
  ```
- Creates an NVRAM entry via `efibootmgr --create-only … --label "YaapLinux"
  --loader '\EFI\boot\bootx64.efi'` (falls back to a warning if it fails).
- **Note on `bootloader.uefi`:** even when the config value is `grub`, the UEFI
  path installs **systemd-boot** (the code comment: *"UKIs pair with
  systemd-boot"*). systemd-boot is the effective UEFI bootloader in all cases.

### 3.2 BIOS path — GRUB

```
pkg_install grub
grub-install --target=i386-pc --recheck <bios_grub partition, e.g. /dev/nvme0n1p2>
grub-mkconfig -o /boot/grub/grub.cfg
```

### 3.3 Kernel command line (`build_uki_cmdline`)

```
root=UUID=<root-uuid> rw quiet splash
```

With hibernation, appended: `resume=UUID=<ruuid> resume_offset=<off>`. The
`root=` uses the **btrfs root UUID** (LUKS is unlocked by the initramfs
`sd-encrypt` hook before root mounts).

---

## 4. Unified Kernel Images (UKIs)

Gated by `bootloader.unified_kernel_images == true` (default). ESP is sized to
1 GiB when UKIs are on (§1.1).

`build_uki` uses `ukify` (warns + falls back to split `/boot` if `ukify` is
absent or the build fails):

| UKI component | Source |
|---|---|
| output | `/boot/efi/EFI/Linux/arch-linux-zen.efi` |
| `--linux` | `boot/vmlinuz-linux-zen` + `boot/initramfs-linux-zen.img` |
| `--microcode` | `boot/intel-ucode.img` or `boot/amd-ucode.img` (CPU-dependent) |
| `--os-release` | `/usr/lib/os-release` |
| `--cmdline` | the assembled `bootloader.cmdline` |

When UKIs are disabled, the loader relies on a split `/boot` kernel + initrd.
Both `linux-zen` (primary) and `linux` (fallback/recovery) kernels are
pacstrapped in stage 40 and get initrds from `mkinitcpio -P` in stage 50.

### 4.1 initramfs hooks (`stages/50-base-config.sh`)

```
HOOKS=(base systemd autodetect modconf block keymap consolefont keyboard btrfs [resume] [sd-encrypt])
COMPRESSION="zstd"
```

- `resume` added when hibernation is on.
- `sd-encrypt` added when LUKS is on (provides the LUKS passphrase prompt in the
  initramfs; a bare `encrypt` hook is deliberately *not* used next to
  `systemd`).

---

## 5. Secure Boot (sbctl) — graceful abort (`stages/80-bootloader.sh`)

Driven by `hardware.secure_boot.strategy` (`sbctl` \| `systemd` \| `none`) and
the detected state from `detect_secure_boot_state`.

| Strategy | Behaviour |
|---|---|
| `none` | Logs "Secure Boot: strategy=none"; returns, leaves UKI unsigned |
| `sbctl` | If state is `setup_mode` **or** `enabled` → `sign_sbctl`; else warns "not in setup mode; leaving UKI unsigned" |
| `systemd` | Logs a placeholder notice — real ukify signing is deferred; leaves unsigned |

`sign_sbctl`:

1. Guards on `sbctl` availability (live `command -v sbctl` **or**
   `$TARGET_ROOT/usr/bin/sbctl`). `sbctl` ships in the live ISO package set
   (`iso/packages.x86_64`).
2. Runs `arch-chroot "$TARGET_ROOT" sbctl enroll -v`.
3. On success: sets `hardware.secure_boot.enrolled true`.
4. **On failure → `graceful_sb_abort`** (spec §10.3):
   - sets `hardware.secure_boot.enrolled false`,
   - logs that Secure Boot is left **DISABLED** and the **UKI remains bootable
     unsigned**,
   - points to `/root/install-report.txt` for manual follow-up
     (`sbctl enroll -v`),
   - does **not** touch the UKI further — the system is never bricked or left in
     a half-enrolled state.

The post-install report lists "Secure Boot not enrolled; enroll manually"
whenever `secure_boot.enrolled != true`.

---

## 6. Login manager (`stages/80-bootloader.sh`)

Chosen by `login.manager`:

| Value | Behaviour |
|---|---|
| `greetd` (default) | `pkg_install greetd tuigreet`; copies `assets/greetd-config.toml` → `/etc/greetd/config.toml`; enables `greetd.service` |
| `tty_autologin` | writes a `getty@tty1.service.d/autologin.conf` override: `ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM` |

The bundled greetd config (`assets/greetd-config.toml`) launches Hyprland:

```toml
[service]
type = "cmd"
default_value = "tuigreet --time --time-format '%H:%M' --gemini --remember \
  --remember-user-session --users-background /usr/share/wallpapers/default.jpg \
  --cmd Hyprland"
```

`login.greeter` in config records `tuigreet`.
