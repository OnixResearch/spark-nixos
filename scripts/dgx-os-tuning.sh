#!/usr/bin/env bash
# Prints the GB10 tuning a DGX OS box carries, to compare with nix/modules/hardware. It only
# reads, and needs no root:
#
#   ssh <box> bash -s < scripts/dgx-os-tuning.sh
#
# Each NVIDIA tuning package installs one fragment; the packages section names them, so a new
# one in a DGX OS update shows up there first.
set -u

section() { printf '\n== %s\n' "$*"; }
# Each file's settings, without comments, and without lines matching $SKIP.
fragments() {
  for f in "$@"; do
    [ -f "$f" ] || continue
    lines=$(grep -vE '^\s*(#|;|$)' "$f" | grep -vE "${SKIP:-^$}")
    [ -n "$lines" ] && printf -- '-- %s\n%s\n' "$f" "$lines"
  done
}

section release
grep -E '^DGX_(SWBUILD|OTA)_VERSION' /etc/dgx-release 2>/dev/null
uname -r
section 'kernel command line'
tr ' ' '\n' < /proc/cmdline | grep -vE '^(BOOT_IMAGE|root|ro|quiet|splash|vt\.handoff)='
section 'tuning packages'
dpkg-query -W -f '${Status} ${Package}\n' 2>/dev/null \
  | awk '$1 == "install" && $3 == "installed" { print $4 }' \
  | grep -E '^(nv-|nvidia-spark-|nvidia-[a-z0-9-]*-options|nvidia-kernel-defaults|nvidia-no-|nvidia-mstflint|dgx-spark-)' \
  | tr '\n' ' '
echo
section 'modprobe options'
# Ubuntu's own sound, framebuffer and rare-protocol fragments are left out.
SKIP='^(blacklist |alias net-pf|install (sound-slot|snd|saa7134|ib_qib)|options (snd|bt87x|cx88|saa7134)|remove iwlwifi|\(/sbin/lsmod|&& /sbin/modprobe)' \
  fragments /etc/modprobe.d/*.conf
section 'modules loaded at boot'
fragments /etc/modules-load.d/*.conf
section sysctl
fragments /etc/sysctl.d/*.conf
section limits
fragments /etc/security/limits.d/*.conf
section sleep
fragments /etc/systemd/sleep.conf.d/*.conf
section 'NVIDIA units'
for unit in nvidia-persistenced nvidia-nvme-interrupt-coalescing nv-cpu-governor cfg-iommu; do
  printf '%s: %s\n' "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null)"
done
section 'RDMA devices'
rdma link 2>/dev/null | awk '{ print $2, $NF }'
lsmod | awk 'NR > 1 { print $1 }' | grep -E '^(ib_|rdma_|mlx5_ib)' | sort | tr '\n' ' '
echo
