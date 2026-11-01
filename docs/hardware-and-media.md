# Hardware Detection & Media Stack

This document describes everything the installer does to **discover the machine**
and to **provision the multimedia / peripheral stack**. It is grounded in
`lib/detect.sh`, `lib/pkg.sh`, and `stages/60-drivers-media.sh`.

The guiding design principle (from `lib/detect.sh` header) is: *"values are
detected, not guessed."* Every detector is idempotent and safe to re-run.
User-confirmable values (firmware, disk) are detected, then offered for
confirmation unless the run is `--unattended`.

---

## 1. Hardware detection (`lib/detect.sh`)

`detect_all()` runs the full sweep. Each detector writes results into
`install-config.yaml` under the `hardware.*` and `peripherals.*` / `battery`
keys via `cfg_set` (see `lib/config.sh`).

| Function | Returns | Config keys written |
|---|---|---|
| `detect_firmware` | `uefi` \| `bios` | `hardware.firmware` |
| `detect_secure_boot_state` | `setup_mode` \| `enabled` \| `disabled` \| `n/a` | `hardware.secure_boot.setup_mode`, `hardware.secure_boot.enrolled` |
| `detect_cpu_vendor` | `intel` \| `amd` | `hardware.cpu.vendor`, `hardware.cpu.microcode` |
| `detect_gpu` | `amd` \| `intel` \| `nvidia` \| `unknown` | `hardware.gpu.primary`, `hardware.gpu.intel_gen`, `hardware.gpu.vaapi_driver`, `hardware.gpu.needs_linux_firmware_intel` |
| `detect_storage` | target block device (or fails) | `storage.device`, `storage.type`, `storage.rotational` |
| `detect_peripherals` | sets peripheral flags + `battery` | `peripherals.*`, `battery` |

### 1.1 Firmware — `detect_firmware`

```bash
if [ -d /sys/firmware/efi ]; then fw=uefi; else fw=bios; fi
```

Writes `hardware.firmware`. UEFI is confirmed again in preflight; BIOS selects
the GRUB path (Secure Boot is unavailable on BIOS).

### 1.2 Secure Boot state — `detect_secure_boot_state`

Reads `/sys/firmware/efi/systab`:

- `SecureBoot=1` → `enabled`
- `SetupMode=1` → `setup_mode` (takes precedence)
- otherwise → `disabled` / `n/a`

Mapping into config:

| State | `setup_mode` | `enrolled` |
|---|---|---|
| `setup_mode` | `true` | `false` |
| `enabled` | `false` | `true` |
| `disabled` / `n/a` | `false` | `false` |

This drives the Secure Boot signing decision in stage 80 (only `setup_mode` or
`enabled` attempt `sbctl enroll`).

### 1.3 CPU vendor & microcode — `detect_cpu_vendor`

Greps `vendor_id` from `/proc/cpuinfo`:

| `vendor_id` | `hardware.cpu.vendor` | `hardware.cpu.microcode` |
|---|---|---|
| `GenuineIntel` | `intel` | `intel-ucode` |
| `AuthenticAMD` | `amd` | `amd-ucode` |
| *(anything else)* | `amd` (default) | `amd-ucode` |

The microcode package is installed in stage 50 and folded into the UKI in
stage 80.

### 1.4 GPU — `detect_gpu`

Uses `lspci -mm` (monster mode, with vendor names — numeric mode would make the
vendor greps always miss and report `unknown`). It greps the first
`VGA compatible` / `3D controller` line:

| Match | `gpu.primary` | `intel_gen` | `vaapi_driver` | `needs_linux_firmware_intel` |
|---|---|---|---|---|
| `Advanced Micro Devices` / `AMD/ATI` | `amd` | `null` | `libva-mesa-driver` | `false` |
| `NVIDIA` | `nvidia` | `null` | `libva-nvidia-driver` | `false` |
| `Intel` **and** one of `Iris`/`UHD Graphics`/`Arc`/`Haswell`/`Broadwell`/`Skylake`/`Kaby Lake`/`Coffee Lake`/`Alder`/`Raptor`/`Meteor` | `intel` | `broadwell_plus` | `intel-media-driver` | `true` |
| `Intel` (older, none of the above) | `intel` | `legacy` | `libva-intel-driver` | `false` |
| *(no recognised vendor)* | `unknown` | `null` | `libva-mesa-driver` (default seed) | `false` |

`broadwell_plus` Intel GPUs additionally require the `linux-firmware-intel`
subpackage at runtime; stage 60 asserts it is present and warns if not.

### 1.5 Storage — `detect_storage`

- Target comes from `YAAP_TARGET_DISK` (set by `--target`) or is auto-resolved
  via `lsblk -rnbo NAME,TYPE,HOTPLUG` → first `disk` with `HOTPLUG=0`.
- `_probe_dev()` classifies the device: `nvme*`→`nvme`, `mmcblk*`→`mmc`,
  `sd*`→`sata`; reads `queue/rotational` and `size` (GiB).
- **Refuses the live medium**: if the resolved device resolves through
  `sr0`/`sr1`/`sg[0-9]`/`sd?_cd`, it errors out (`refusing target … appears to
  be the live medium`).
- Writes `storage.device`, `storage.type`, `storage.rotational`. Fails
  gracefully (`return 1`) if no block device is found — preflight turns this
  into a hard failure in unattended mode.

### 1.6 Peripherals — `detect_peripherals`

Probes `lspci` + `lsusb` (and `/proc/bus/input/devices`, `/dev/video0`,
`/sys/class/power_supply`).

| Peripheral | Detection heuristic | Key written |
|---|---|---|
| Bluetooth | `lspci`/`lsusb` matches `Bluetooth` or `Broadcom Corp` | `peripherals.bluetooth` (`true`/`false`) |
| Touchpad | `Touchpad`/`Touchscreen` in input devices, or `Transceiver`/`Input device` in `lspci` | `peripherals.touchpad` |
| Webcam | `/dev/video0` exists or `lsusb` matches `Camera` | `peripherals.webcam` |
| Fingerprint | `lsusb` matches `Biometric` | `peripherals.fingerprint` |
| Tablet | `Tablet`/`Pen` in input devices | `peripherals.tablet` |
| Printer | `lspci`/`lsusb` matches `Printer`/`EPSON`/`Hewlett-Packard`/`Canon`/`Brother` | `peripherals.printer` → `yes` (else stays at seeded `unknown`) |
| Battery | both an `AC`/`ADP` adapter **and** a `BAT*` supply exist | `battery` |

> **Note — scanner is not auto-detected.** `detect_peripherals` explicitly
> leaves printer/scanner at `unknown` unless a printer is clearly present. There
> is **no** scanner probe, so `peripherals.scanner` keeps its seeded value
> (`unknown`) unless you set it by hand. This only affects the supplementary
> group added to the user in stage 50 (`scanner` group); the scanning *package
> stack* is gated independently by `media.scanning` (see §3.6).

---

## 2. Package install model (`lib/pkg.sh`)

Stage 60 builds one declarative **install set** and runs it through these
wrappers:

- `pkg_install <pkgs…>` — `pacman -S --needed` (never `-Sy`), chroot-aware,
  **retried 3×** with a 3 s backoff, then `die`. All output is appended to
  `$YAAP_LOG`.
- `pkg_install_aur <pkgs…>` — via `$YAAP_AUR_HELPER` (default `yay`);
  **non-fatal**: if the helper is absent it warns and skips.
- `pkg_conflict_guard <a> <b>` — aborts if both packages are in the pending
  `YAAP_INSTALL_SET` (spec §8.5).
- `repo_enable_multilib` — the **only** sanctioned full-sync (`-Syu`) exception
  (spec §8.4); see §3.5.

`YAAP_INSTALL_SET` is seeded in `build_install_set()` as
`base base-devel linux linux-firmware` (plus `video-render-utils` when the GPU
is not `unknown`) so conflict guards have something to inspect.

---

## 3. Stage 60 — drivers & media

`run_stage()` order: `build_install_set` → `apply_multilib_if_requested` →
`install_universal_drivers` → `install_codecs` → `install_vaapi_drivers` →
`install_gstreamer_tuning` → `install_printing` → `install_scanning` →
`run_diagnostics`.

### 3.1 Universal drivers (always installed)

Independent of hardware, unless a gate below says otherwise:

| Category | Packages | Gate |
|---|---|---|
| Audio | `pipewire`, `pipewire-pulse`, `pipewire-alsa`, `pipewire-jack`, `wireplumber`, `alsa-utils`, `alsa-ucm-conf`, `sof-firmware` | always |
| Filesystems | `exfatprogs`, `dosfstools`, `ntfs-3g` | always |
| Sensors | `lm_sensors` | always |
| Storage health | `smartmontools` (+ `nvme-cli` if `storage.type == nvme`) | `nvme` conditional |
| Bluetooth | `bluez`, `bluez-utils` | `peripherals.bluetooth == true` |
| Touchpad | `libinput` | `peripherals.touchpad == true` |
| Webcam | `v4l-utils` | `peripherals.webcam == true` |
| Tablet | `libwacom` | `peripherals.tablet == true` |
| Fingerprint | `fprintd` | `peripherals.fingerprint == true` |
| Modem | `modemmanager` | `peripherals.modem == true` |
| Power daemon | `tlp` **XOR** `power-profiles-daemon` (or nothing) | `battery == true`, chosen by `power.daemon` |

The power daemon is **mutually exclusive** by config: `power.daemon` is
`power-profiles-daemon` (default), `tlp`, or `none`.

### 3.2 Codecs — gated by `media.codecs`

If `media.codecs != true`, the stage logs "codecs disabled by config" and
returns. Otherwise:

```
ffmpeg
gstreamer  gst-plugins-base  gst-plugins-good  gst-plugins-bad
gst-plugins-ugly        # only if media.gstreamer_ugly != false (opt-out)
gst-libav
```

When `media.diagnostics == true`, the diagnostics tools `libva-utils` and
`vdpauinfo` are also installed here.

> The codec stack ships **no `freeworld`/`libdvdcss` variants** — Arch already
> compiles patent codecs into `ffmpeg`/`mesa` (README, spec §8).

### 3.3 VA-API driver matrix — `install_vaapi_drivers`

Selected from the detected `hardware.gpu.primary` / `intel_gen`:

| GPU | Packages installed | `LIBVA_DRIVER_NAME` env |
|---|---|---|
| `amd` | `mesa`, `libva-mesa-driver` | *(not set)* |
| `intel` `broadwell_plus` | `mesa`, `libva-mesa-driver`, `intel-media-driver` | `iHD` |
| `intel` `legacy` | `mesa`, `libva-mesa-driver`, `libva-intel-driver` | *(not set)* |
| `nvidia` | `mesa`, `nvidia-utils`, `libva-nvidia-driver` | `nvidia` |
| `unknown` | *(none — warns "GPU undetected")* | *(not set)* |

Details:

- For `intel` `broadwell_plus`, stage 60 asserts `linux-firmware-intel` is
  installed in the target (`pacman -Q`) and **warns** if it is missing — Intel
  VA-API on Skylake+ may fail silently without it.
- `write_env_hint` writes `/etc/profile.d/yaap-vaapi.sh` (`export
  LIBVA_DRIVER_NAME=…`) **and** records the value in `desktop.env.LIBVA_DRIVER_NAME`
  so it is re-emitted into the Wayland session env in stage 70.
- `assert_video_group` adds the daily-use user to the `video` group if missing
  (required for hardware acceleration).

### 3.4 GStreamer tuning & diagnostics — gated by `media.diagnostics`

`install_gstreamer_tuning` only runs when `media.diagnostics == true`:

- For **NVIDIA**, it sets `desktop.env.GST_PLUGIN_FEATURE_RANK` to rank the
  NVIDIA hardware decoders at `MAX`:
  ```
  nvmpegvideodec:MAX,nvmpeg2videodec:MAX,nvmpeg4videodec:MAX,nvh264sldec:MAX,
  nvh264dec:MAX,nvjpegdec:MAX,nvh265sldec:MAX,nvh265dec:MAX,nvvp9dec:MAX
  ```
- For all other GPUs the rank is empty (no override).

`run_diagnostics` (also gated by `media.diagnostics`):

1. Creates `$TARGET_ROOT/var/log/yaaplinux/`.
2. Runs `vainfo` in the target, capturing to `var/log/yaaplinux/vainfo.log`
   (failure is non-fatal — the driver may not be loaded until first boot).
3. Writes a `.enc` summary of `VAEntrypointEncSlice*` capabilities.
4. **AV1 auto-demotion**: if `VAProfileAV1` is not present in the log, the AV1
   GStreamer decoders are demoted to `NONE` by appending
   `avdec_av1:NONE,av1dec:NONE` to `GST_PLUGIN_FEATURE_RANK`.

### 3.5 Multilib — gated by `media.multilib` (the full-sync exception)

`apply_multilib_if_requested` calls `repo_enable_multilib` only when
`media.multilib == true`. Per `lib/pkg.sh` (spec §8.4) this is the **single
documented full-sync** path and is not reachable from any other code path:

1. Idempotently uncomments (or appends) `[multilib]` + its `Include` line in the
   **target** `/etc/pacman.conf`.
2. Runs `pacman -Syu` (a **full upgrade**, never `-Sy`) — live or chroot.
3. On failure it **reverts** the `pacman.conf` edit and returns non-zero (the
   caller logs a non-fatal warning).
4. Verifies the repo is populated (`pacman -Sl multilib`) and sets
   `media.multilib true`.

All other installs use `-S --needed`, so no partial upgrade can occur except
inside this function.

### 3.6 Printing — gated by `media.printing`

`install_printing` runs only when `media.printing == true`:

```
cups  system-config-printer  avahi  ghostscript  gsfonts  gutenprint
```

- If `media.printing_hp == true`, `hplip` is additionally installed and added to
  `YAAP_INSTALL_SET`.
- `pkg_conflict_guard hplip foo2zjs-nightly` guards the known
  foo2zjs/hplip PPD conflict (FS#58815, spec §8.5). `foo2zjs-nightly` is
  AUR-only and opt-in; the guard is in place for when it is wired in.
- Enables `cups.service` and `avahi-daemon.service`.

The **gutenprint maintenance hook** (`assets/hooks/99-gutenprint.hook`,
installed to `/etc/pacman.d/hooks/` in stage 50) runs on every
`gutenprint` / `foomatic-db-gutenprint-ppds` upgrade:

```
cups-genppdupdate && systemctl restart cups.service
```

This automates the PPD regeneration that would otherwise silently break
printers after a gutenprint update.

### 3.7 Scanning — gated by `media.scanning`

`install_scanning` runs only when `media.scanning == true`:

```
sane  sane-airscan  ipp-usb  simple-scan
```

- Enables `ipp-usb.service` (required for USB IPP driverless scanners).
- As noted in §1.6, whether the `scanner` group is added to the user depends on
  `peripherals.scanner == yes`, which is **not** set by detection — set it by
  hand if you want it.

---

## 4. Config gates at a glance (stage 60)

| Gate key | Default | Effect |
|---|---|---|
| `media.codecs` | `true` | Installs `ffmpeg` + GStreamer plugin set |
| `media.gstreamer_ugly` | `true` | Include `gst-plugins-ugly` (opt-out with `false`) |
| `media.diagnostics` | `true` | Installs `libva-utils`/`vdpauinfo`, runs `vainfo`, GStreamer decoder ranking + AV1 demotion |
| `media.multilib` | `false` | Enables `[multilib]` and runs a full `-Syu` sync |
| `media.printing` | `false` | Installs CUPS/gutenprint stack, enables cups+avahi |
| `media.printing_hp` | `false` | Additionally installs `hplip` |
| `media.scanning` | `false` | Installs SANE/sane-airscan/ipp-usb, enables ipp-usb |
| `media.steam` | `false` | (stage 70) installs `steam-devices` |
| `power.daemon` | `power-profiles-daemon` | `tlp` \| `power-profiles-daemon` \| `none` (laptop only) |
