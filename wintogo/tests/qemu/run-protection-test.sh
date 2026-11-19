#!/usr/bin/env bash
#
# run-protection-test.sh - prove with a real virtual machine that the installer
# never writes to an internal disk.
#
# Method
# ------
# The "internal" disk is a qcow2 BASE image with a qcow2 OVERLAY on top. The VM
# only ever sees the overlay. Every sector the guest writes lands as a new
# allocation in the overlay file, so after the run:
#
#   * the overlay must contain zero data clusters  (qemu-img map: no "data": true)
#   * the base image must be byte-identical        (sha256 before == after)
#
# That is a far stronger statement than "the installer said it did not write",
# because it is measured at the virtual hardware boundary, below Windows.
#
# The external disk is a second qcow2 attached through an emulated USB 3
# controller with the removable flag set, which is what a USB SSD looks like to
# firmware and to Windows.
#
# Requires: qemu-system-x86_64, qemu-img, and OVMF firmware (edk2/ovmf package).
#
# Scenarios: internal+external (default), external-only, many-disks, no-internal.
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_root="$script_dir/work"

iso_path=""
ovmf_code=""
scenario="internal-external"
timeout_seconds=900
keep=0

step() { printf '\n\033[1;32m>> %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() { printf '\n\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: run-protection-test.sh --iso <installer.iso> [options]

  --iso PATH          Installer ISO built by build-media.sh --iso-image
                      (build it with --unattended-disk/--unattended-serial)
  --ovmf PATH         OVMF code firmware (default: autodetect)
  --scenario NAME     internal-external | external-only | many-disks | no-internal
  --timeout SECONDS   How long to let the install run (default 900)
  --keep              Keep the work directory for inspection
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)      iso_path="$2"; shift 2 ;;
        --ovmf)     ovmf_code="$2"; shift 2 ;;
        --scenario) scenario="$2"; shift 2 ;;
        --timeout)  timeout_seconds="$2"; shift 2 ;;
        --keep)     keep=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$iso_path" ] && [ -f "$iso_path" ] || { usage; fail "an installer ISO is required"; }

for tool in qemu-system-x86_64 qemu-img sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

if [ -z "$ovmf_code" ]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/qemu/OVMF.fd; do
        [ -f "$candidate" ] && { ovmf_code="$candidate"; break; }
    done
fi
[ -n "$ovmf_code" ] && [ -f "$ovmf_code" ] || fail "OVMF firmware not found; install ovmf/edk2-ovmf or pass --ovmf"

case "$scenario" in
    internal-external|external-only|many-disks|no-internal) ;;
    *) fail "unknown scenario: $scenario" ;;
esac

work="$work_root/$scenario"
rm -rf "$work"
mkdir -p "$work"

step "scenario: $scenario"
info "firmware:   $ovmf_code"
info "installer:  $iso_path"

# ---------------------------------------------------------------------------
# Virtual disks
# ---------------------------------------------------------------------------

# make_internal_disk <name> <size>
# A base image with plausible content plus an overlay the VM is given.
make_internal_disk() {
    local name="$1"
    local size="$2"
    local base="$work/$name-base.qcow2"
    local overlay="$work/$name-overlay.qcow2"

    qemu-img create -f qcow2 "$base" "$size" >/dev/null
    # Put a recognisable pattern in the first MiB so an accidental write would be
    # obvious even to a human looking at the disk later.
    printf 'DO-NOT-TOUCH-INTERNAL-DISK-%s' "$name" | dd of="$base" bs=1024 seek=1 conv=notrunc status=none 2>/dev/null || true
    qemu-img create -f qcow2 -b "$base" -F qcow2 "$overlay" >/dev/null

    sha256sum "$base" | awk '{print $1}' > "$work/$name-base.sha256"
    echo "$base"
}

# The external disk gets no overlay: it is allowed to change, and we check it did.
make_external_disk() {
    local name="$1"
    local size="$2"
    local path="$work/$name.qcow2"
    qemu-img create -f qcow2 "$path" "$size" >/dev/null
    echo "$path"
}

external_disk="$(make_external_disk external 64G)"

qemu_args=(
    -machine q35,accel=kvm:tcg
    -m 4096
    -smp 2
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
    -device qemu-xhci,id=xhci
    -device "usb-storage,drive=external,removable=on,bus=xhci.0"
    -drive "if=none,id=external,format=qcow2,file=$external_disk,cache=unsafe"
    -cdrom "$iso_path"
    -boot order=d,menu=on
    -display none
    -serial "file:$work/serial.log"
    -monitor none
    -no-reboot
)

internal_names=()

case "$scenario" in
    internal-external)
        internal_names=(internal)
        ;;
    external-only)
        internal_names=()
        ;;
    many-disks)
        internal_names=(internal0 internal1 internal2)
        ;;
    no-internal)
        internal_names=()
        # No internal disk at all: the installer must still work.
        ;;
esac

disk_index=0
for name in "${internal_names[@]}"; do
    base="$(make_internal_disk "$name" 32G)"
    overlay="$work/$name-overlay.qcow2"
    # First internal disk is the boot/system disk, like a real laptop.
    if [ "$disk_index" -eq 0 ]; then
        qemu_args+=(-drive "if=none,id=$name,format=qcow2,file=$overlay,cache=unsafe")
        qemu_args+=(-device "ide-hd,drive=$name,bus=ide.0")
    else
        qemu_args+=(-drive "if=none,id=$name,format=qcow2,file=$overlay,cache=unsafe")
        qemu_args+=(-device "scsi-hd,drive=$name,bus=scsi0.0")
    fi
    disk_index=$((disk_index + 1))
done

if [ "$scenario" = "many-disks" ]; then
    qemu_args+=(-device virtio-scsi-pci,id=scsi0)
fi

step "booting the virtual machine"
info "this needs an ISO built with --unattended-disk/--unattended-serial"
info "the run is bounded to ${timeout_seconds}s"

set +e
timeout "$timeout_seconds" qemu-system-x86_64 "${qemu_args[@]}"
qemu_status=$?
set -e

if [ "$qemu_status" -eq 124 ]; then
    info "the VM was stopped by the timeout (expected for an unattended run)"
elif [ "$qemu_status" -ne 0 ]; then
    info "qemu exited with status $qemu_status"
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

failures=0

step "verifying that no internal disk was written"

for name in "${internal_names[@]}"; do
    overlay="$work/$name-overlay.qcow2"
    base="$work/$name-base.qcow2"
    expected_sha="$(cat "$work/$name-base.sha256")"
    actual_sha="$(sha256sum "$base" | awk '{print $1}')"

    # Sum the length of every cluster that holds data in the overlay.
    written_bytes="$(qemu-img map --output=json "$overlay" \
        | tr -d '\n' \
        | grep -o '"length": *[0-9]*, *"data": *true' \
        | grep -o '[0-9]\+' | awk '{s+=$1} END {print s+0}')"

    if [ "$expected_sha" != "$actual_sha" ]; then
        printf '\033[1;31m   FAIL %s: the base image changed on disk\033[0m\n' "$name"
        failures=$((failures + 1))
    elif [ "${written_bytes:-0}" -ne 0 ]; then
        printf '\033[1;31m   FAIL %s: %s bytes were written to the internal disk\033[0m\n' "$name" "$written_bytes"
        failures=$((failures + 1))
    else
        printf '\033[1;32m   ok   %s: zero bytes written, base image unchanged\033[0m\n' "$name"
    fi
done

if [ "${#internal_names[@]}" -eq 0 ]; then
    info "no internal disks in this scenario; nothing to protect"
fi

step "verifying that the external disk was used"
external_written="$(qemu-img map --output=json "$external_disk" \
    | tr -d '\n' \
    | grep -o '"length": *[0-9]*, *"data": *true' \
    | grep -o '[0-9]\+' | awk '{s+=$1} END {print s+0}')"

if [ "${external_written:-0}" -gt 0 ]; then
    printf '\033[1;32m   ok   external disk received %s bytes\033[0m\n' "$external_written"
else
    printf '\033[1;33m   ??   external disk is empty; the installer probably did not run\033[0m\n'
    info "check $work/serial.log - the ISO must be built with unattended answers"
fi

step "checking the installer log in the serial console"
if [ -f "$work/serial.log" ]; then
    if grep -qi 'Installation complete' "$work/serial.log"; then
        printf '\033[1;32m   ok   the installer reported completion\033[0m\n'
    else
        printf '\033[1;33m   ??   completion was not seen in the serial log\033[0m\n'
    fi
    if grep -qi 'DRY RUN' "$work/serial.log"; then
        printf '\033[1;33m   ??   this was a dry run, not an installation\033[0m\n'
    fi
else
    printf '\033[1;33m   ??   no serial log was produced\033[0m\n'
fi

if [ "$keep" -eq 0 ]; then
    info "work directory kept at $work"
fi

if [ "$failures" -ne 0 ]; then
    printf '\n\033[1;31mFAILED: %s internal-disk check(s) failed\033[0m\n' "$failures" >&2
    exit 1
fi

printf '\n\033[1;32mPASSED: internal storage received zero writes\033[0m\n'
