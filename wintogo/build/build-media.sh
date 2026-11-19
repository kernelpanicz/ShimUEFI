#!/usr/bin/env bash
#
# build-media.sh - build a ShimUEFI portable Windows installation medium.
#
# Takes a Windows installation ISO that you obtained yourself and produces:
#
#   out/shimuefi-installer.img   a bootable UEFI disk image (write to USB with dd)
#   out/shimuefi-installer.iso   an ISO 9660 + El Torito UEFI image (optional)
#   out/manifest.txt             checksums and contents
#
# No Microsoft files are stored in this repository. Everything is copied out of
# the ISO you supply, at build time, on your machine.
#
# Requires (Debian/Ubuntu):
#   xorriso wimtools mtools dosfstools gdisk coreutils
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
  --iso-image              Also build an ISO image
  --esp-size-mb N          Force the FAT32 image size in MiB (default: computed)

Media contents:
  --no-split               Do not split install.wim (only if it fits in 4 GiB)
  --driver-dir DIR         Copy extra storage drivers into the medium and inject
                           them into the offline image at install time
  --allow-sd-card          Let the installer offer SD cards as targets
  --allow-internal-bus-override
                           Let the installer offer internal-bus disks (NVMe/SATA
                           enclosures) after the operator confirms the serial

Unattended (still requires the serial number):
  --unattended-disk N      Default target disk number
  --unattended-serial S    Serial number of the target disk
  --unattended-index N     Default Windows edition index

Other:
  --work DIR               Build directory (default: <repo>/build/work)
  --keep-work              Keep intermediate files after a successful build
  -h, --help               Show this help

The medium never contains a Windows image until you run this script against an
ISO you already own. Build output is deliberately excluded from version control.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)              iso_path="$2"; shift 2 ;;
        --out)              out_dir="$2"; shift 2 ;;
        --work)             work_dir="$2"; shift 2 ;;
        --volume-name)      volume_name="$2"; shift 2 ;;
        --iso-image)        make_iso=1; shift ;;
        --no-split)         split_threshold_mb=999999; shift ;;
        --split-size)       split_threshold_mb="$2"; shift 2 ;;
        --esp-size-mb)      esp_size_mb="$2"; shift 2 ;;
        --driver-dir)       driver_dir="$2"; shift 2 ;;
        --allow-sd-card)    allow_sd_card=1; shift ;;
        --allow-internal-bus-override) allow_internal_override=1; shift ;;
        --unattended-disk)  unattended_disk="$2"; shift 2 ;;
        --unattended-serial) unattended_serial="$2"; shift 2 ;;
        --unattended-index) unattended_index="$2"; shift 2 ;;
        --keep-work)        keep_work=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$iso_path" ] || { usage; die "an ISO is required"; }
[ -f "$iso_path" ] || die "ISO not found: $iso_path"
iso_path="$(cd "$(dirname "$iso_path")" && pwd)/$(basename "$iso_path")"

if [ -z "$work_dir" ]; then
    work_dir="$repo_root/build/work"
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"

if [ -n "$unattended_serial" ] && [ -z "$unattended_disk" ]; then
    die "--unattended-serial needs --unattended-disk"
fi
if [ -n "$unattended_disk" ] && [ -z "$unattended_serial" ]; then
    die "--unattended-disk needs --unattended-serial (the installer refuses a disk number alone)"
fi

need_tools="xorriso wimlib-imagex mkfs.vfat mmd mcopy mdir truncate dd sha256sum du awk"
missing=""
for tool in $need_tools; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    die "missing build tools:$missing
On Debian/Ubuntu: sudo apt install xorriso wimtools mtools dosfstools coreutils"
fi

# ---------------------------------------------------------------------------
# ISO access helpers
# ---------------------------------------------------------------------------

# iso_find <name> -> prints the first matching absolute path inside the ISO, or nothing.
iso_find() {
    local name="$1"
    xorriso -indev "$iso_path" -find / -name "$name" -exec echo 2>/dev/null \
        | sed '/^xorriso :/d' | sed '/^$/d' | head -n1
}

# iso_extract <path-in-iso> <destination>
iso_extract() {
    local path="$1"
    local destination="$2"
    mkdir -p "$(dirname "$destination")"
    rm -rf "$destination"
    xorriso -osirrox on -indev "$iso_path" -extract "$path" "$destination" 2>/dev/null
    [ -e "$destination" ] || die "failed to extract $path from the ISO"
}

step "inspecting $iso_path"

boot_wim_path="$(iso_find boot.wim)"
[ -n "$boot_wim_path" ] || die "this ISO has no sources/boot.wim; it is not a Windows installation ISO"

install_image_path="$(iso_find install.wim)"
if [ -z "$install_image_path" ]; then
    install_image_path="$(iso_find install.esd)"
fi
[ -n "$install_image_path" ] || die "this ISO has no sources/install.wim or install.esd"

bcd_path="$(iso_find BCD)"
bootmgfw_path="$(iso_find bootmgfw.efi)"
[ -n "$bcd_path" ] || die "this ISO has no EFI boot configuration (BCD)"
[ -n "$bootmgfw_path" ] || die "this ISO has no bootmgfw.efi; it is not UEFI bootable"

info "boot image:      $boot_wim_path"
info "install image:   $install_image_path"
info "boot manager:    $bootmgfw_path"

# ---------------------------------------------------------------------------
# Stage the medium tree
# ---------------------------------------------------------------------------

step "staging medium contents"
rm -rf "$work_dir/stage" "$work_dir/payload"
mkdir -p "$work_dir/stage/EFI/Boot" "$work_dir/stage/EFI/Microsoft/Boot" "$work_dir/stage/sources" "$work_dir/payload/wintogo"

iso_extract "$bootmgfw_path" "$work_dir/stage/EFI/Microsoft/Boot/bootmgfw.efi"
cp "$work_dir/stage/EFI/Microsoft/Boot/bootmgfw.efi" "$work_dir/stage/EFI/Boot/BOOTX64.EFI"
iso_extract "$bcd_path" "$work_dir/stage/EFI/Microsoft/Boot/BCD"

fonts_path="$(iso_find fonts)"
if [ -n "$fonts_path" ]; then
    iso_extract "$fonts_path" "$work_dir/stage/EFI/Microsoft/Boot/fonts"
fi

iso_extract "$boot_wim_path" "$work_dir/stage/sources/boot.wim"

install_image_name="$(basename "$install_image_path" | tr 'A-Z' 'a-z')"
iso_extract "$install_image_path" "$work_dir/stage/sources/$install_image_name"

step "installing the installer payload"
cp "$runtime_dir/wintogo.ps1" "$work_dir/payload/wintogo/wintogo.ps1"
mkdir -p "$work_dir/payload/wintogo/engine"
cp "$engine_dir"/*.psm1 "$work_dir/payload/wintogo/engine/"
# winpeshl.ini lives outside /wintogo so the payload directory stays clean.
cp "$runtime_dir/winpeshl.ini" "$work_dir/payload/winpeshl.ini"

if [ -n "$driver_dir" ]; then
    [ -d "$driver_dir" ] || die "driver directory not found: $driver_dir"
    mkdir -p "$work_dir/stage/drivers"
    cp -r "$driver_dir"/. "$work_dir/stage/drivers/"
    info "extra drivers copied to /drivers"
fi

# Any of these options is expressed as an answer file on the medium. The disk
# number is only ever written alongside the serial number it belongs to.
if [ -n "$unattended_disk" ] || [ -n "$driver_dir" ] || [ "$allow_sd_card" -eq 1 ] || [ "$allow_internal_override" -eq 1 ]; then
    json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    {
        echo '{'
        if [ -n "$unattended_disk" ]; then
            echo "  \"diskNumber\": $unattended_disk,"
        fi
        if [ -n "$unattended_serial" ]; then
            echo "  \"serial\": \"$(json_escape "$unattended_serial")\","
        fi
        if [ -n "$unattended_index" ]; then
            echo "  \"imageIndex\": $unattended_index,"
        fi
        if [ -n "$driver_dir" ]; then
            echo '  "driverDirectory": "X:\\drivers",'
        fi
        if [ "$allow_sd_card" -eq 1 ]; then
            echo '  "allowSdCard": true,'
        fi
        if [ "$allow_internal_override" -eq 1 ]; then
            echo '  "allowInternalBusOverride": true,'
        fi
        echo '  "generatedBy": "build-media.sh"'
        echo '}'
    } > "$work_dir/payload/wintogo/unattended.json"
    info 'answer file written to X:\wintogo\unattended.json'
fi

# ---------------------------------------------------------------------------
# Patch boot.wim
# ---------------------------------------------------------------------------

step "patching the boot image with the installer"
wim_index="$(wimlib-imagex info "$work_dir/stage/sources/boot.wim" 1 2>/dev/null | awk -F': *' '/Architecture/{print $2; exit}')"
info "boot.wim image 1 architecture: ${wim_index:-unknown}"
case "${wim_index:-}" in
    *x86_64*|*amd64*|*x86*) ;;
    "") warn "could not determine the boot image architecture; continuing" ;;
    *) warn "boot.wim image 1 is $wim_index; this project targets x86-64 UEFI" ;;
esac

wimlib-imagex update "$work_dir/stage/sources/boot.wim" 1 \
    --command="add '$work_dir/payload/wintogo' '/wintogo'" \
    --command="add '$work_dir/payload/winpeshl.ini' '/Windows/System32/winpeshl.ini'" \
    --command="add '$runtime_dir/startnet.cmd' '/Windows/System32/startnet.cmd'" \
    --boot >/dev/null

step "checking the patched boot image"
if wimlib-imagex dir "$work_dir/stage/sources/boot.wim" 1 2>/dev/null | grep -qi 'wintogo.ps1'; then
    info "installer payload is inside boot.wim"
else
    die "the installer payload is missing from boot.wim after patching"
fi

# ---------------------------------------------------------------------------
# Split the install image for FAT32
# ---------------------------------------------------------------------------

step "preparing the Windows image for FAT32"
install_size_mb=$(( $(stat -c %s "$work_dir/stage/sources/$install_image_name") / 1024 / 1024 ))
info "install image size: $install_size_mb MiB"

if [ "$install_image_name" = "install.esd" ] && [ "$install_size_mb" -gt "$split_threshold_mb" ]; then
    info "converting install.esd to a WIM so it can be split"
    wimlib-imagex export "$work_dir/stage/sources/install.esd" all \
        "$work_dir/stage/sources/install.wim" --compress=LZX --solid >/dev/null
    rm -f "$work_dir/stage/sources/install.esd"
    install_image_name="install.wim"
    install_size_mb=$(( $(stat -c %s "$work_dir/stage/sources/$install_image_name") / 1024 / 1024 ))
fi

if [ "$install_size_mb" -gt "$split_threshold_mb" ]; then
    case "$install_image_name" in
        *.swm)
            info "install image is already split"
            ;;
        *)
            info "splitting install image into $split_threshold_mb MiB parts"
            wimlib-imagex split "$work_dir/stage/sources/$install_image_name" \
                "$work_dir/stage/sources/install.swm" "$split_threshold_mb" >/dev/null
            rm -f "$work_dir/stage/sources/$install_image_name"
            install_image_name="install.swm"
            ;;
    esac
else
    info "install image fits on FAT32 without splitting"
fi

# ---------------------------------------------------------------------------
# FAT32 image
# ---------------------------------------------------------------------------

step "building the FAT32 boot image"
tree_size_mb=$(( $(du -sm "$work_dir/stage" | awk '{print $1}') ))
if [ "$esp_size_mb" -eq 0 ]; then
    esp_size_mb=$(( tree_size_mb + 96 ))
    # FAT32 needs a sane minimum and room for the FATs on larger volumes.
    [ "$esp_size_mb" -lt 768 ] && esp_size_mb=768
    esp_size_mb=$(( ((esp_size_mb + esp_size_mb / 50 + 15) / 16) * 16 ))
fi
info "FAT32 volume size: $esp_size_mb MiB for $tree_size_mb MiB of files"

fat_image="$work_dir/shimuefi-esp.img"
rm -f "$fat_image"
truncate -s "${esp_size_mb}M" "$fat_image"
mkfs.vfat -F 32 -n "$volume_name" "$fat_image" >/dev/null

export MTOOLS_SKIP_CHECK=1

# Create every directory first, then copy files (mcopy cannot create intermediate dirs).
( cd "$work_dir/stage" && find . -type d | sed 's|^\./||' | grep -v '^$' | while read -r dir; do
    mmd -i "$fat_image" "::/$dir" 2>/dev/null || true
done )

( cd "$work_dir/stage" && find . -type f | sed 's|^\./||' | while read -r file; do
    mcopy -i "$fat_image" "$file" "::/$file"
done )

step "verifying the FAT32 image"
for required in EFI/Boot/BOOTX64.EFI EFI/Microsoft/Boot/BCD EFI/Microsoft/Boot/bootmgfw.efi sources/boot.wim; do
    if mdir -i "$fat_image" "::/$required" >/dev/null 2>&1; then
        info "present: $required"
    else
        die "missing from the built image: $required"
    fi
done

if ! mdir -i "$fat_image" '::/sources' 2>/dev/null | grep -qi 'install\.'; then
    die "the Windows installation image is missing from /sources"
fi

image_out="$out_dir/shimuefi-installer.img"
mv -f "$fat_image" "$image_out"
info "wrote $image_out"

# ---------------------------------------------------------------------------
# Optional ISO
# ---------------------------------------------------------------------------

iso_out=""
if [ "$make_iso" -eq 1 ]; then
    step "building the ISO image"

    boot_img_for_iso="$work_dir/eltorito-efi.img"
    cp "$image_out" "$boot_img_for_iso"

    iso_out="$out_dir/shimuefi-installer.iso"
    rm -f "$iso_out"

    xorriso -as mkisofs \
        -iso-level 3 \
        -joliet -joliet-long -rational-rock \
        -volid "$volume_name" \
        -eltorito-platform efi \
        -eltorito-boot "eltorito-efi.img" \
        -no-emul-boot \
        -o "$iso_out" \
        -graft-points \
        "/=$work_dir/stage" \
        "/eltorito-efi.img=$boot_img_for_iso" \
        >/dev/null

    [ -f "$iso_out" ] || die "xorriso did not produce an ISO"
    info "wrote $iso_out"
fi

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

step "writing the manifest"
manifest="$out_dir/manifest.txt"
{
    echo "ShimUEFI portable Windows installation medium"
    echo "built:        $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "source iso:   $(basename "$iso_path")"
    echo "boot image:   $boot_wim_path"
    echo "windows image: $install_image_path -> $install_image_name"
    echo "volume label: $volume_name"
    if [ -n "$unattended_disk" ]; then
        echo "unattended:   disk $unattended_disk (serial confirmed at build time)"
    else
        echo "unattended:   no (interactive)"
    fi
    echo
    echo "checksums"
    ( cd "$out_dir" && sha256sum ./*.img ./*.iso 2>/dev/null || true )
    echo
    echo "contents (top level of /sources and /EFI)"
    ( cd "$work_dir/stage" && find . -maxdepth 3 -type f | sort )
} > "$manifest"
info "wrote $manifest"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if [ "$keep_work" -eq 0 ]; then
    rm -rf "$work_dir/stage" "$work_dir/payload" "$work_dir/eltorito-efi.img"
fi

step "done"
cat <<EOF

Write the image to a USB drive (Linux):

  sudo dd if=$image_out of=/dev/sdX bs=4M oflag=direct status=progress conv=fsync

Replace /dev/sdX with the whole device, not a partition. This erases that drive.

The medium installs Windows onto a *second* external disk. Do not write this
image to the disk you intend to install Windows onto.
EOF
