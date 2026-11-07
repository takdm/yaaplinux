# AGENTS.md — YaapLinux

YaapLinux is a Bash-based archiso project: a resumable, checkpointed Arch Linux
installer (`install.sh` + `lib/` + `stages/`) that produces a Hyprland/Wayland
desktop, plus an `iso/` archiso profile that ships the installer. All logic is
Bash with `set -uo pipefail`; there is no build system, no package manifest, no CI.

## Layout

- `install.sh` — orchestrator; sources `lib/*.sh`, then sources each
  `stages/NN-name.sh` and calls its `run_stage` function.
- `lib/` — log.sh, ui.sh (gum prompts), config.sh (cfg_get/cfg_set dotted
  YAML paths), checkpoint.sh (`.done` files in /var/lib/yaaplinux/checkpoints),
  detect.sh, pkg.sh, chroot.sh, dotfiles.sh, yaap (post-install CLI).
- `stages/00`–`90` — destructive stages are 10-partition and 20-format
  (listed in `STAGE_DESTRUCTIVE` in install.sh).
- `assets/install-config.yaml` — committed config template; every `cfg_get`
  dotted path used in code MUST exist at the same nesting in this file.
- `iso/` — archiso profile (profiledef.sh, packages.x86_64, airootfs/).
- `iso/airootfs/etc/yaaplinux/` — a COPY of the installer tree embedded in the
  ISO. The built ISO ships this copy, not the source tree.
- `docs/` — architecture, stages, configuration, security; kept in sync with code.

## Verify / test (exact commands)

No test runner, no CI. After editing shell code:

- `bash -n install.sh lib/*.sh stages/*.sh` — the only lint gate.
- `./test-dotfiles.sh "$(mktemp -d)"` — unit harness for config.sh/dotfiles.sh
  with a mocked arch-chroot; exits non-zero on failure, log in `<tmp>/run.log`.
- Keep the ISO copy in sync after every edit, then verify:
  `cp -a install.sh lib stages assets iso/airootfs/etc/yaaplinux/` and
  `diff -rq lib iso/airootfs/etc/yaaplinux/lib` (no output = in sync).
- Boot-test a built ISO: `./test-vm.sh --iso <path> [--bios]` (QEMU/KVM;
  needs `sudo apt install qemu-system-x86 qemu-utils ovmf` by the user).
- ISO build (Arch-only; on this Kubuntu host it runs inside a QEMU guest):
  `mkarchiso -v -w ./work -o ./out iso` (see docs/iso-and-usage.md).

## Conventions (observed)

- CLIs are `while [ $# -gt 0 ]` shift-loops accepting BOTH `--opt=val` and
  `--opt val`; usage text must match what the parser accepts.
- Runtime config/overrides via `YAAP_*` env vars (e.g. `YAAP_TARGET_ROOT`,
  `YAAP_DRYRUN`); log to `$YAAP_LOG_DIR` via `log_info/log_warn/die`.
- Stages define `run_stage` and nothing else at top level; the orchestrator
  owns checkpointing (`stage_begin`/`stage_complete`) and dry-run gating.
- Commit messages observed: short lowercase conventional-ish prefixes
  (`fix:`, `feat:`, `docs:`).

## Pitfalls

- A source-only fix never ships: the ISO embeds `iso/airootfs/etc/yaaplinux/`
  — forget the sync and the release silently carries old code.
- `set -u`: an unbound variable aborts the whole installer. After renames,
  grep for stale `$OLD_NAME` uses in lib/ and stages/.
- Hand-rolled config parser: `cfg_set` on a path whose parent key is missing
  from `assets/install-config.yaml` is a silent no-op. Audit cfg_get/cfg_set
  dotted paths against the template's actual nesting.
- gum draws prompts on stderr and reads /dev/tty — never redirect its stderr
  to /dev/null (invisible prompt that still blocks).
- `--dry-run` is enforced in the orchestrator loop in install.sh; stages 10/20/30
  are skipped and the run stops before 50. New mutating stages must fit this gate.
- `iso/packages.x86_64` must include `mkinitcpio-archiso` (pacman package, not
  the `archiso` name) or the ISO builds fine but never boots; and must NOT list
  `yay` (AUR package — aborts the build with "target not found").
- QEMU `-append archisosearchuuid=` for a boot test must equal the BUILT ISO's
  UUID (`blkid -p <iso>`), not a previous release's — a stale UUID boots to the
  archiso shell.
- Never `pkill qemu` while a guest build controller runs; it kills the build
  with no artifact.
