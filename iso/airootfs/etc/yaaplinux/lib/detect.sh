#!/usr/bin/env bash
# lib/detect.sh — hardware probing. Writes results into install-config.yaml.
# Every detector is idempotent and safe to re-run; values are detected, not
# guessed (design principle 8). User-confirmable values (firmware, disk) are
# detected then offered for confirmation unless unattended.
#
# Provides:
#   detect_firmware                 -> uefi|bios           (writes hardware.firmware)
#   detect_secure_boot_state        -> setup_mode|enabled|disabled|n/a
#   detect_cpu_vendor               -> intel|amd
#   detect_gpu                      -> amd|intel|nvidia|unknown
#   detect_storage                  -> sets storage.* (device is confirmable)
#   detect_peripherals              -> sets peripherals.* and battery
#   detect_all                      -> runs the full sweep

detect_firmware() {
    local fw
    if [ -d /sys/firmware/efi ]; then fw=uefi; else fw=bios; fi
    cfg_set hardware.firmware "$fw"
    log_info "firmware: $fw"
    echo "$fw"
}

detect_secure_boot_state() {
    local state="n/a"
    if [ -d /sys/firmware/efi ] && [ -r /sys/firmware/efi/systab ]; then
        if grep -q '^SecureBoot=1' /sys/firmware/efi/systab 2>/dev/null; then
            state="enabled"
        else
            state="disabled"
        fi
        if grep -q '^SetupMode=1' /sys/firmware/efi/systab 2>/dev/null; then
            state="setup_mode"
        fi
    fi
    case "$state" in
        setup_mode)
            cfg_set hardware.secure_boot.setup_mode true
            cfg_set hardware.secure_boot.enrolled false ;;
        enabled)
            cfg_set hardware.secure_boot.setup_mode false
            cfg_set hardware.secure_boot.enrolled true ;;
        *)
            cfg_set hardware.secure_boot.setup_mode false
            cfg_set hardware.secure_boot.enrolled false ;;
    esac
    log_info "secure boot state: $state"
    echo "$state"
}

detect_cpu_vendor() {
    local v
    v="$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $NF}')"
    case "$v" in
        GenuineIntel) cfg_set hardware.cpu.vendor intel; cfg_set hardware.cpu.microcode intel-ucode ;;
        AuthenticAMD) cfg_set hardware.cpu.vendor amd;   cfg_set hardware.cpu.microcode amd-ucode ;;
        *)
            log_warn "unknown CPU vendor '$v'; defaulting to amd"
            cfg_set hardware.cpu.vendor amd; cfg_set hardware.cpu.microcode amd-ucode ;;
    esac
    log_info "cpu vendor: $(cfg_get hardware.cpu.vendor) (microcode $(cfg_get hardware.cpu.microcode))"
}

# Rough Intel generation classification from the lspci device string.
detect_gpu() {
    local pci gpu intel_gen vaapi needfw
    # -mm = monster mode WITH device names. (-nm would numeric-ize the vendor,
    # making the vendor greps below always miss and report "unknown".)
    pci="$(lspci -mm 2>/dev/null)"
    gpu="unknown"; intel_gen="null"; vaapi="libva-mesa-driver"; needfw="false"

    local line
    line="$(printf '%s\n' "$pci" | grep -iE 'VGA compatible|3D controller' | head -n1)"
    if [ -n "$line" ]; then
        if printf '%s' "$line" | grep -qiE 'Advanced Micro Devices|AMD/ATI'; then
            gpu="amd"; vaapi="libva-mesa-driver"
        elif printf '%s' "$line" | grep -qi 'NVIDIA'; then
            gpu="nvidia"; vaapi="libva-nvidia-driver"
        elif printf '%s' "$line" | grep -qi 'Intel'; then
            gpu="intel"
            if printf '%s' "$line" | grep -qiE 'Iris|UHD Graphics|Arc|Haswell|Broadwell|Skylake|Kaby Lake|Coffee Lake|Alder|Raptor|Meteor'; then
                intel_gen="broadwell_plus"; vaapi="intel-media-driver"
                [ "$intel_gen" = broadwell_plus ] && needfw="true"
            else
                intel_gen="legacy"; vaapi="libva-intel-driver"
            fi
        else
            gpu="unknown"
        fi
    fi

    cfg_set hardware.gpu.primary "$gpu"
    cfg_set hardware.gpu.intel_gen "$intel_gen"
    cfg_set hardware.gpu.vaapi_driver "$vaapi"
    cfg_set hardware.gpu.needs_linux_firmware_intel "$needfw"
    log_info "gpu: $gpu (intel_gen=$intel_gen, vaapi=$vaapi, fw_intel=$needfw)"
    echo "$gpu"
}

# Probe a block device: type, rotational, size (GiB). Echoes size or 0.
_probe_dev() {
    local dev="$1" base
    base="$(basename "$dev")"
    local typ="sata"
    case "$base" in
        nvme*) typ="nvme" ;;
        mmcblk*) typ="mmc" ;;
        sd*) typ="sata" ;;
    esac
    local rota=0
    [ -r "/sys/block/$base/queue/rotational" ] && rota="$(cat "/sys/block/$base/queue/rotational" 2>/dev/null)"
    local size_b=0 sectors=0
    [ -r "/sys/block/$base/size" ] && sectors="$(cat "/sys/block/$base/size" 2>/dev/null)"
    size_b=$(( sectors * 512 ))
    printf '%s %s %s' "$typ" "${rota:-0}" "$(( size_b / 1024 / 1024 / 1024 ))"
}

detect_storage() {
    local dev="${YAAP_TARGET_DISK:-}"
    if [ -z "$dev" ]; then
        # Auto: first non-removable, non-live disk.
        dev="$( (command -v lsblk >/dev/null && lsblk -rnbo NAME,TYPE,HOTPLUG 2>/dev/null | awk '$2=="disk" && $3=="0"{print $1; exit}') )"
    fi
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        log_warn "no target block device detected/auto-resolved"
        return 1
    fi
    # Refuse the live medium.
    local live
    live="$(readlink -f "/sys/block/$(basename "$dev")/device" 2>/dev/null)"
    case "$live" in
        *sr0*|*sr1*|*sg[0-9]*|*sd?_cd*)
            log_err "refusing target $dev: appears to be the live medium"
            return 1 ;;
    esac

    local info typ rota gib
    info="$(_probe_dev "$dev")"
    typ="$(printf '%s' "$info" | awk '{print $1}')"
    rota="$(printf '%s' "$info" | awk '{print $2}')"
    gib="$(printf '%s' "$info" | awk '{print $3}')"

    cfg_set storage.device "$dev"
    cfg_set storage.type "$typ"
    cfg_set storage.rotational "$([ "${rota:-0}" = 1 ] && echo true || echo false)"
    log_info "storage: $dev type=$typ rotational=$([ "${rota:-0}" = 1 ] && echo yes || echo no) size~${gib}GiB"
    echo "$dev"
}

detect_peripherals() {
    local pci usb
    pci="$(lspci 2>/dev/null)"
    usb="$(lsusb 2>/dev/null)"

    # Bluetooth
    if printf '%s\n%s' "$pci" "$usb" | grep -qiE 'Bluetooth|Broadcom Corp' ; then
        cfg_set peripherals.bluetooth true
    else
        cfg_set peripherals.bluetooth false
    fi
    # Touchpad
    if [ -r /proc/bus/input/devices ] && grep -qi 'Touchpad\|Touchscreen' /proc/bus/input/devices 2>/dev/null; then
        cfg_set peripherals.touchpad true
    elif printf '%s' "$pci" | grep -qi 'Transceiver\|Input device'; then
        cfg_set peripherals.touchpad true
    else
        cfg_set peripherals.touchpad false
    fi
    # Webcam
    if [ -e /dev/video0 ] || printf '%s' "$usb" | grep -qi 'Camera'; then
        cfg_set peripherals.webcam true
    else
        cfg_set peripherals.webcam false
    fi
    # Fingerprint
    if printf '%s' "$usb" | grep -qi 'Biometric'; then
        cfg_set peripherals.fingerprint true
    else
        cfg_set peripherals.fingerprint false
    fi
    # Tablet
    if [ -r /proc/bus/input/devices ] && grep -qi 'Tablet\|Pen' /proc/bus/input/devices 2>/dev/null; then
        cfg_set peripherals.tablet true
    else
        cfg_set peripherals.tablet false
    fi
    # Printer / scanner stay 'unknown' unless clearly present.
    if printf '%s' "$usb" "$pci" | grep -qiE 'Printer|EPSON|Hewlett-Packard|Canon|Brother'; then
        cfg_set peripherals.printer yes
    fi
    # Battery / laptop.
    if ls /sys/class/power_supply/AC* /sys/class/power_supply/ADP* >/dev/null 2>&1 && \
       ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
        cfg_set battery true
    else
        cfg_set battery false
    fi
    log_info "peripherals: bt=$(cfg_get peripherals.bluetooth) touch=$(cfg_get peripherals.touchpad) cam=$(cfg_get peripherals.webcam) bat=$(cfg_get battery)"
}

detect_all() {
    detect_firmware >/dev/null
    detect_secure_boot_state >/dev/null
    detect_cpu_vendor
    detect_gpu >/dev/null
    detect_storage || true
    detect_peripherals
}
