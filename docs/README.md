# YaapLinux Installer Documentation

**Yaap** = *Yet Another Archinstall Profile*. YaapLinux is a modular, resumable
Bash installer that produces a Wayland-native Arch Linux desktop built on
**Hyprland 0.56.x** (Lua compositor config). Launched from the Arch ISO as root,
it probes live hardware, seeds a YAML config, then walks a fixed pipeline of
checkpointed stages — preflight, partition, format, mount, pacstrap, base
config, drivers/media, desktop, bootloader, post-install — that can be re-run to
resume from the first incomplete step. Hardware sections of the config are
populated by detection on every run, while destructive stages re-ask for
confirmation even on resume. The installer implements specification revision 2.0.

## Documentation index

| Document | What it covers |
| --- | --- |
| [Architecture](architecture.md) | Directory/module layout, the stage pipeline, the checkpoint & resume model, and the config read/write contract. |
| [Stages](stages.md) | What each stage `00-preflight` … `90-postinstall` actually does, in execution order. |
| [Configuration](configuration.md) | Reference table for every key in `install-config.yaml`, grouped by section, with allowed values, defaults, and whether each is detected or user-set. |

## Repository entry points

- Top-level README: [`../README.md`](../README.md)
- Installer entry point: [`../install.sh`](../install.sh)
- Library code: [`../lib/`](../lib/)
- Stage code: [`../stages/`](../stages/)
- Default config template: [`../assets/install-config.yaml`](../assets/install-config.yaml)
