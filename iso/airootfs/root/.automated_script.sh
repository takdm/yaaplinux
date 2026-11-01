#!/usr/bin/env bash
# iso/airootfs/root/.automated_script.sh — optional unattended entry point.
# Reads a config from the ISO label or a second USB partition, then invokes the
# installer in --unattended mode. Never auto-selects a disk: --target is required.
#
# Place the installer tree at /etc/yaaplinux/ in the airootfs (the ISO build
# copies the repo there).

scriptname="${0##*/}"
AUTOMATED_CONFIG=""

# Look for a config on the ISO label filesystem or a second partition.
for cand in /run/archiso/yaap/install-config.yaml /mnt/yaap/install-config.yaml \
            /etc/yaaplinux/automated/install-config.yaml; do
    [ -f "$cand" ] && { AUTOMATED_CONFIG="$cand"; break; }
done

if [ -z "$AUTOMATED_CONFIG" ]; then
    echo "no automated config found; starting interactive installer"
    exec /etc/yaaplinux/install.sh
fi

echo "unattended install with config: $AUTOMATED_CONFIG"
exec /etc/yaaplinux/install.sh --unattended --config "$AUTOMATED_CONFIG"
