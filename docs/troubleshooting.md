# Troubleshooting

This document covers the preflight checks, the failure classes and their
behaviour, where logs and reports live, and recovery via snapshot rollback. It
is grounded in `stages/00-preflight.sh`, `lib/log.sh`, `lib/checkpoint.sh`,
`lib/pkg.sh`, `install.sh`, and `stages/90-postinstall.sh`.

---

## 1. Preflight checks (`stages/00-preflight.sh`)

Preflight runs **before any disk mutation**. Each check either sets a hard-fail
flag (aborts at the end with `die "preflight: one or more hard checks failed"`)
or `die`s immediately.

| Check | What it does | Severity |
|---|---|---|
| `check_root` | `id -u` must be 0 | **hard** (immediate `die`) |
| `check_arch_live` | warns if `/etc/arch-release` / `/run/archos` absent; in interactive mode asks to continue | warn / confirm |
| `check_internet` | ping `1.1.1.1`/`8.8.8.8`/`archlinux.org`, else HTTPS to archlinux.org | **hard** |
| `check_clock` | requires `timedatectl NTPsynchronized=yes`; tries `set-ntp true` then re-checks | **hard** |
| `resolve_target_disk` | uses `--target`/prior detect; interactive prompts if unset; unattended with no disk → error | **hard** (unattended) |
| `check_disk_size` | target must be **≥ 32 GiB** | **hard** |
| `check_firmware_branch` | confirms UEFI/BIOS; interactive confirms the detected firmware | confirm |
| `check_secure_boot_preflight` | logs `secure_boot.setup_mode` | info |
| `check_battery` | logs laptop/desktop (power management) | info |
| `check_ram` | **< 768 MiB → hard fail**; `< 2048 MiB → warn** (pacstrap may be slow) | **hard** / warn |
| `check_mirrorlist` | refreshes via `reflector` if present (non-fatal on failure) | warn |

If you hit a preflight failure, the specific reason is logged just before the
aggregate `die` message.

---

## 2. Failure classes & their behaviour

The installer distinguishes **hard aborts** from **non-fatal warnings** on
purpose ("fail loudly, recover gracefully").

### 2.1 Hard abort — `die()` (`lib/log.sh`)

`die <msg>` records, then `exit 1`:

- `FATAL [<YAAP_STAGE>]: <msg>`
- the failing command, if `YAAP_FAIL_CMD` is set (pacman/pacstrap/etc. set it)
- the last 20 lines of the file named by `YAAP_FAIL_CTX`, if set

Destructive stages (`10-partition`, `20-format`) additionally re-confirm before
running even on resume, unless `--force`. Declining aborts at that stage.

### 2.2 Network / clock / RAM / disk — preflight hard fails

See §1. These abort **before** touching a disk.

### 2.3 Package install failure — 3 retries, then `die`

`pkg_install` retries `pacman -S --needed` up to **3 times** (3 s backoff),
logging each attempt, then `die`s. `pacstrap` failure in stage 40 also `die`s
with a pointer to `$YAAP_LOG`.

### 2.4 AUR install — non-fatal

`pkg_install_aur` warns and **skips** if the helper (`yay`) is missing, and
treats a failed AUR build as non-fatal (`log_warn … return 1`). So a missing
`librewolf`/`steam-devices` never aborts the run.

### 2.5 Multilib full-sync — revert & warn (non-fatal)

If `pacman -Syu` fails inside `repo_enable_multilib`, it **reverts** the
`pacman.conf` `[multilib]` edit and returns non-zero; the stage 60 caller logs a
non-fatal warning. The system is left with multilib disabled and otherwise
untouched.

### 2.6 Secure Boot enrolment — graceful abort (non-fatal)

If `sbctl enroll -v` fails, `graceful_sb_abort` sets `secure_boot.enrolled
false`, leaves the **UKI bootable unsigned**, and records a manual follow-up in
the report. The install continues; the system boots. (See
[Bootloader & Security](bootloader-and-security.md#5-secure-boot-sbctl--graceful-abort).)

### 2.7 Non-fatal warnings (install continues)

The following are logged as warnings and do **not** abort:

- TPM2 auto-unlock enrolment failure (keeps passphrase-only)
- `efibootmgr` entry creation failure (bootctl may have configured it)
- `ukify` missing or UKI build failure (falls back to split `/boot`)
- `sbctl` unavailable (skips enrolment)
- `genfstab` failure (uses the earlier fstab)
- `snapper createconfig` failure (may already exist)
- `visudo -cf` sudoers validation failure
- `librewolf` / `steam-devices` AUR unavailability
- `reflector` failure (uses existing mirrorlist)
- `vainfo` failure (driver may not be loaded until first boot)
- `resume_offset` not computable (hibernation may not resume)

---

## 3. Logs, transcripts & reports

| Artifact | Path | Written by |
|---|---|---|
| Install transcript | `/var/log/yaaplinux/install-<YYYYmmdd-HHMMSS>.log` | `lib/log.sh` (`YAAP_LOG_DIR`/`YAAP_LOG`) — every `log_*` line, plus all pacman/pacstrap output |
| VA-API diagnostics | `<target>/var/log/yaaplinux/vainfo.log` (+ `.enc` summary) | stage 60 `run_diagnostics` |
| Post-install report (target) | `<target>/root/install-report.txt` | `install.sh` `write_report` |
| Post-install report (live) | `/root/install-report.txt` | `install.sh` (copied from the target report) |
| Stage checkpoints | `/var/lib/yaaplinux/checkpoints/<stage>.done` | `lib/checkpoint.sh` |
| Unattended LUKS passphrase | `/var/lib/yaaplinux/luks-passphrase` (staged), then `<target>/boot/efi/keys/<mapper>.key` (ESP) | stages 10 / 30 |

The report lists completed vs pending stages, detected hardware, the resolved
configuration, and **manual follow-up items** (Secure Boot not enrolled, multilib
disabled, unattended-LUKS keyfile on the ESP, "verify VA-API after first boot:
`vainfo`", "reboot, then log in at the greetd prompt").

Run with `--debug` for `DEBUG`-level lines, or `--dry-run` to log intended
mutations and perform none.

---

## 4. Resume model (`lib/checkpoint.sh`)

Re-running `install.sh` continues from the **first incomplete stage**:

- Each completed stage writes `<stage>.done`:
  - line 1: ISO timestamp
  - line 2: `sha256` of the config consumed
- A stage is "done" only if the file exists **and** the stored hash equals the
  current `ck_config_hash()` (sha256 of the config file). **Changing the config
  forces the affected stage (and every later one) to re-run.**
- Destructive stages re-confirm on resume unless `--force`.
- The orchestrator warns if a *later* stage is done while an *earlier* one is
  not ("config hash drift?").

Typical recovery:

```bash
./install.sh --target /dev/nvme0n1            # resumes from first incomplete stage
./install.sh --target /dev/nvme0n1 --force    # also skip the destructive re-confirm
./install.sh --target /dev/nvme0n1 --dry-run  # preview what would happen
```

---

## 5. Recovery: snapshot rollback

Snapshots (when `disk.snapshots.enabled`) live on the btrfs `@` subvolume under
`/.snapshots`, managed by snapper with pre/post package-transaction pairs (§ see
[Bootloader & Security](bootloader-and-security.md#2-snapshots-snapper-stages90-postinstallsh-assets)).

After a bad package transaction or config change:

```bash
# on the installed system, chrooted if the root is LUKS/unmounted
snapper -c root list                 # find the pre/post snapshot numbers
snapper -c root undochange 42..43    # revert the filesystem to snapshot 42
```

For a boot-time rollback (the `boot_integration: true` intent in the config):
select a read-only **snapshot boot entry** from the systemd-boot menu (each
snapshot is a btrfs subvolume at `/.snapshots/<number>`), boot it, and repair or
`undochange` from there. Because `/` is btrfs with `@` as the root subvolume, a
previous snapshot is a self-contained, bootable tree.

If snapshots were disabled, fall back to the install transcript
(`/var/log/yaaplinux/`) to identify the failing command, fix it, and re-run the
installer — it will resume from the first incomplete stage without redoing the
completed ones.
