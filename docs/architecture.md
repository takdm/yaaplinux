# Architecture

This document describes how the installer is put together: the directory and
module layout, the stage pipeline driven by `install.sh`, the checkpoint/resume
model, and the config read/write contract. Every claim here is grounded in the
code under `install.sh`, `lib/`, and `stages/`.

## Directory & module layout

```
yaaplinux/
├── install.sh          orchestrator / entry point (argv, lib loading, stage loop)
├── lib/                sourced helper libraries
├── stages/             one file per pipeline stage (NN-name.sh)
├── assets/             seeded config + desktop assets shipped in the airootfs
└── iso/                archiso profile that builds the bootable installer
```

| Path | Role |
| --- | --- |
| `install.sh` | Parses argv, sources the libraries, seeds the config from the template, computes the resume point, and drives the ordered stage loop. |
| `lib/` | Helper libraries sourced at startup, in a fixed order (see [Library modules](#library-modules)). |
| `stages/` | Ten `NN-name.sh` files. Each defines a `STAGE_ID` and a `run_stage` function; `install.sh` sources the file and calls `run_stage`. |
| `assets/` | `install-config.yaml` (seed template), `hyprland.lua` (0.56.x Lua compositor config), `hypr-theme.sh` + `base16/` (cross-layer theming), `greetd-config.toml` (login manager), `snapper-root.conf` (snapshot reference), and `hooks/` (pacman hooks: snapper pre/post, gutenprint). These are copied into the airootfs at `/etc/yaaplinux/`. |
| `iso/` | The archiso profile (`airootfs/`, `packages.x86_64`, `pacman.conf`, `profiledef.sh`, plus build dirs `work/` and `out/`). The installer tree is staged with `cp -a . iso/airootfs/etc/yaaplinux/`; `iso/work` and `iso/out` are build artifacts. |

## Library modules

Sourced by `install.sh` in this order: `log.sh`, `config.sh`, `checkpoint.sh`,
`ui.sh`, `detect.sh`, `pkg.sh`, `chroot.sh`.

| Module | Provides |
| --- | --- |
| `lib/log.sh` | `log_init`, `log_info`/`log_warn`/`log_err`/`log_debug`, and `die` — a timestamped transcript plus fatal-error context (stage, failing command, last 20 lines of a context file). |
| `lib/ui.sh` | `ui_confirm`/`ui_confirm_true`, `ui_choose`, `ui_input`, `ui_notify` — a prompt abstraction that prefers `gum` and falls back to plain `read`; in `--unattended` mode every prompt returns its default immediately. Results are returned in `REPLY`. |
| `lib/config.sh` | `cfg_path`, `cfg_get`, `cfg_set`, `cfg_has`, `cfg_array`, `cfg_map` — minimal nested-YAML access (see [Config contract](#config-readwrite-contract)). |
| `lib/checkpoint.sh` | `stage_is_done`, `stage_complete`, `stage_begin`, `ck_config_hash` — the resumable stage cursor (see [Checkpoint & resume model](#checkpoint--resume-model)). |
| `lib/detect.sh` | `detect_firmware`, `detect_secure_boot_state`, `detect_cpu_vendor`, `detect_gpu`, `detect_storage`, `detect_peripherals`, `detect_all` — hardware probing that writes results into the config. Every detector is idempotent. |
| `lib/pkg.sh` | `pkg_install` (pacman `-S --needed`, chroot-aware, 3-retry), `pkg_install_aur` (non-fatal, via helper), `pkg_conflict_guard` (mutual-exclusion abort), `repo_enable_multilib` (the single sanctioned `-Syu` full-sync). All installs use `-S` never `-Sy`. |
| `lib/chroot.sh` | `chroot_run`, `chroot_run_bash`, `chroot_enable` — thin `arch-chroot` helpers that require a bootable `TARGET_ROOT`. |

## Stage pipeline

`install.sh` defines the pipeline explicitly and drives it in a loop:

```
STAGE_ORDER=(00-preflight 10-partition 20-format 30-mount 40-pacstrap
             50-base-config 60-drivers-media 70-desktop 80-bootloader
             90-postinstall)
STAGE_DESTRUCTIVE=( [10-partition]=1 [20-format]=1 )
```

1. **Resume point** — before the loop, `install.sh` walks `STAGE_ORDER` and finds
   the first stage for which `stage_is_done` is false.
2. **Per iteration** — for each stage:
   - If `stage_is_done "$s"` → log `skip … (complete; config unchanged)` and continue.
   - Drift guard — if a *later* stage is already marked done while this one is
     not, log a `config hash drift?` warning.
   - **Destructive re-confirmation** — if the stage is destructive
     (`10-partition`, `20-format`) and `--force` was not given, prompt
     (`ui_confirm_true`); declining aborts the run. This happens on *every* run,
     including resume.
   - Source the stage file, then `stage_begin` → `run_stage` → `stage_complete`.
3. **Finish** — after the loop, `write_report` (an orchestrator-owned function so
   it also runs when the final stage is skipped on resume) emits the post-install
   report, then `ui_notify` announces completion.

Each stage ends by setting `meta.stage` to a human-readable label of the *next*
phase (e.g. `00-preflight` sets `meta.stage=partitioning`, …, `90-postinstall`
sets `meta.stage=done`). This is a human/audit cursor, distinct from the
machine-checked `.done` checkpoint files.

## Checkpoint & resume model

Checkpoints live in `YAAP_CK_DIR` (default `/var/lib/yaaplinux/checkpoints`).
Each completed stage writes a file `<stage>.done` containing exactly two lines:

```
<ISO-8601 timestamp>
<sha256 of the config consumed>
```

| Function | Behaviour |
| --- | --- |
| `stage_complete <name>` | `mkdir -p` the checkpoint dir, then write the current timestamp (line 1) and `ck_config_hash` (line 2) to `<name>.done`. |
| `stage_is_done <name>` | True only if `<name>.done` exists **and** its stored line-2 hash equals the current `ck_config_hash`. |
| `ck_config_hash` | `sha256sum` of the whole config file (`YAAP_CONFIG`), or `none` if the file is missing. |
| `stage_begin <name>` | Exports `YAAP_STAGE=<name>` for log context. |

**Config-hash invalidation.** A stage is skipped only while the config file's
current sha256 matches the hash it recorded at its own completion. Because the
hash is computed over the *whole file*, and stages mutate the file during a run
(`detect_all` rewrites `hardware.*`; later stages write `storage.*`,
`disk.luks.*`, UUIDs, `desktop.env.*`, etc.), each `.done` stamp reflects the
file state at that stage's end. Editing `install-config.yaml` changes the hash,
so every stage whose recorded hash no longer matches is re-executed — this is how
"a stage whose consumed config hash changed is re-run" works. Once the re-run
reconciles the file, the stamps match again and subsequent runs skip those
stages. A stage that is skipped re-records nothing, so its stamp is preserved.

**Destructive re-confirmation.** `10-partition` and `20-format` are the only
stages flagged destructive in `STAGE_DESTRUCTIVE`. They prompt for confirmation
on every execution (resume included) unless `--force` is passed — independent of
the checkpoint hash, so even a hash-valid resume re-asks.

## Config read/write contract

`lib/config.sh` is a minimal, `awk`-based nested-YAML accessor. It assumes
2-space indentation, scalar leaves on the paths it touches, no inline comments on
read paths, and treats arrays as raw block text. The active config path is
`YAAP_CONFIG` (default `/etc/yaaplinux/install-config.yaml`).

| Function | Signature | Contract |
| --- | --- | --- |
| `cfg_path` | — | Echoes the current config path. |
| `cfg_get` | `cfg_get <dotted.path>` | Prints the scalar value to stdout; empty if the key is absent. Builds the dotted path from indentation depth (e.g. `hardware.cpu.vendor`). |
| `cfg_has` | `cfg_has <dotted.path>` | Exit `0` if the key exists (even when empty), else `1`. Used by `install.sh` to decide whether to seed from the template (`cfg_has version`). |
| `cfg_set` | `cfg_set <dotted.path> <value>` | **Atomic** (temp file + `mv`). If the key exists, rewrites just that scalar, preserving indentation; if absent, appends the leaf under its parent, converting an empty flow collection (e.g. `env: {}`) into block form so children can be added. Quotes the value when it needs it. **Never mutates arrays.** |
| `cfg_array` | `cfg_array <dotted.path>` | Read-only. Emits the raw block body of a YAML sequence, one item per line with the leading `- ` and surrounding quotes stripped. Used for `disk.subvolumes` and `user.groups_extra`. |
| `cfg_map` | `cfg_map <dotted.path>` | Read-only. Emits `KEY=VALUE` lines for a mapping subtree, stripping quotes and inline comments. Used for `desktop.env` when generating the session environment. |

Detection and stages write back into the config through `cfg_set`, so the config
file is both the user's input and the installer's working state.

## Environment variables

The runtime is configured through `YAAP_*` variables (defaults shown).
`install.sh` exports `TARGET_ROOT` derived from `YAAP_TARGET_ROOT`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `YAAP_CONFIG` | `/etc/yaaplinux/install-config.yaml` | Active config file. |
| `YAAP_CONFIG_TEMPLATE` | `$SCRIPT_DIR/assets/install-config.yaml` | Seed template copied when the config lacks a `version` key. |
| `YAAP_LOG_DIR` | `/var/log/yaaplinux` | Log directory. |
| `YAAP_LOG` | `install-<timestamp>.log` | Active transcript (set at runtime). |
| `YAAP_CK_DIR` | `/var/lib/yaaplinux/checkpoints` | Checkpoint directory. |
| `YAAP_TARGET_ROOT` → `TARGET_ROOT` | `/mnt` | Target mount point / root. |
| `YAAP_TARGET_DISK` | auto-detect | Target disk, from `--target`. |
| `YAAP_LUKS_PASSPHRASE_FILE` | `/var/lib/yaaplinux/luks-passphrase` | Staged unattended LUKS passphrase (stage 10 → stage 30). |
| `YAAP_VERSION` | `2.0` | Installer version. |
| `YAAP_STAGE` | `pre` | Current stage label (set by `stage_begin`). |
| `YAAP_UNATTENDED` / `YAAP_DEBUG` / `YAAP_DRYRUN` / `YAAP_FORCE` | `0` | Run-mode flags (`--unattended` / `--debug` / `--dry-run` / `--force`). |
| `YAAP_INSTALL_SET` | — | Pending package set string inspected by `pkg_conflict_guard` (runtime). |
| `YAAP_AUR_HELPER` | `yay` | AUR helper used by `pkg_install_aur`. |
| `YAAP_FAIL_CMD` / `YAAP_FAIL_CTX` | — | Failing command and context file recorded by `die` (runtime). |
