#!/usr/bin/env bash
# iso/profiledef.sh — archiso profile definition (spec §11.2).
iso_name="yaaplinux"
iso_label="YAAPLINUX_$(date +%Y%m)"
iso_publisher="YaapLinux Flavour <https://example.invalid>"
iso_application="YaapLinux Install Medium"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot' 'bios.syslinux')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/passwd"]="0:0:644"
  ["/etc/sudoers.d"]="0:0:755"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/yaap-install"]="0:0:755"
  ["/etc/yaaplinux"]="0:0:755"
  ["/etc/yaaplinux/install.sh"]="0:0:755"
  ["/etc/yaaplinux/install-config.yaml"]="0:0:644"
)
