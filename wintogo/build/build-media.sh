
#!/usr/bin/env bash
#
# build-media.sh - build a ShimUEFI portable Windows installation medium.
#
# Takes a Windows installation ISO that you obtained yourself and produces:
#
#   out/shimuefi-installer.img       a bootable UEFI disk image (dd to USB)
#   out/shimuefi-installer-bios.img  a BIOS/MBR disk image for legacy firmware
#                                    such as a Chromebook running RW_LEGACY
#   out/shimuefi-installer.iso       an ISO 9660 + El Torito UEFI image (optional)
#   out/manifest.txt                 checksums and contents
#
# No Microsoft files are stored in this repository. Everything is copied out of
# the ISO you supply, at build time, on your machine.
#
# Requires (Debian/Ubuntu):
#   xorriso wimtools mtools dosfstools gdisk coreutils
#   ms-sys sfdisk               (only for --boot-mode bios)
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
runtime_dir="$repo_root/wintogo/runtime"
engine_dir="$repo_root/wintogo/engine"

iso_path=""
out_dir="$repo_root/out"
work_dir=""
volume_name="WTGINSTALL"
make_iso=0
split_threshold_mb=3800
esp_size_mb=0
unattended_disk=""
unattended_serial=""
unattended_index=""
driver_dir=""
allow_sd_card=0
allow_internal_override=0
single_usb=0
disk_size=""
min_windows_size="25G"
min_device_size="32G"
boot_mode="uefi"
keep_work=0

info()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;32m>> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m!  %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-media.sh --iso <windows.iso> [options]

Required:
  --iso PATH               Windows installation ISO (WIM/ESD based)

Output:
  --out DIR                Output directory (default: <repo>/out)
  --volume-name NAME       FAT label for the medium (default: WTGINSTALL)
  --iso-image              Also build an ISO image (UEFI only)
  --esp-size-mb N          Force the FAT32 image size in MiB (default: computed)
  --boot-mode MODE         uefi (default, GPT + bootmgfw.efi) or bios (MBR with
                           \bootmgr on the active partition, for legacy firmware)

Media contents:
  --no-split               Do not split install.wim (only if it fits in 4 GiB)
  --driver-dir DIR         Copy extra storage drivers into the medium and inject
                           them into the offline image at install time
  --allow-sd-card          Let the installer offer SD cards as targets
  --allow-internal-bus-override
                           Let the installer offer internal-bus disks (NVMe/SATA
                           enclosures) after the operator confirms the serial

Single device:
  --single-usb             Build one image that is both the installer and the
                           Windows target, so a single USB drive is enough
  --disk-size SIZE         Size of that device, in bytes or with a K/M/G suffix.
                           Must match the device exactly; the installer checks it
  --min-device-size SIZE   Smallest device a medium may be built for, matching
                           the installer's own target policy (default: 32G)
  --min-windows-size SIZE  How much space the Windows partition must be left
                           with after the EFI partition and MSR (default: 25G).
                           A --disk-size that leaves less is refused

Unattended (still requires the serial number):
  --unattended-disk N      Default target disk number
  --unattended-serial S    Serial number of the target disk
  --unattended-index N     Default Windows edition index

Other:
