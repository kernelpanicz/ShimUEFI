#!/usr/bin/env bash
#
# build-media-selftest.sh - actually executes build-media.sh end to end.
#
# `bash -n` only proves the script parses. This harness puts a simulated media
# toolchain (xorriso, wimlib-imagex, mkfs.vfat, mmd, mcopy, mdir, sgdisk) on PATH,
# points it at a fake Windows ISO tree, runs the real script, and then inspects
# what the script produced: the FAT contents, the WIM payload, the split parts,
# the manifest, the ISO, and the single-USB partition layout.
#
# Any step of build-media.sh that breaks - a bad path, a quoting error, a
# swallowed exit status, a wrong partition offset - fails this test.
#
#   ./wintogo/tests/build-media-selftest.sh
#
# Exit code 0 means every scenario behaved as expected.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
build_script="$repo_root/wintogo/build/build-media.sh"
stub_lib="$script_dir/lib/media-stubs.sh"

if [ ! -f "$build_script" ]; then
    echo "cannot find build-media.sh at $build_script" >&2
    exit 1
fi

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/wintogo-selftest.XXXXXX")"
cleanup() {
    [ "${KEEP_SELFTEST:-0}" = "1" ] && { echo "kept: $temp_root"; return; }
    rm -rf "$temp_root"
}
trap cleanup EXIT

stub_dir="$temp_root/bin"
state_dir="$temp_root/state"
fake_iso="$temp_root/fake-iso"
mkdir -p "$stub_dir" "$state_dir" "$fake_iso"

failures=0
checks=0

pass() { checks=$((checks + 1)); printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; }

assert_file() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}

assert_contains() {
    if [ -f "$1" ] && grep -q -- "$2" "$1"; then pass "$3"; else fail "$3 (no '$2' in $1)"; fi
}

assert_not_contains() {
    if [ -f "$1" ] && grep -q -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

assert_absent() {
    if [ -e "$1" ]; then fail "$2 (still present: $1)"; else pass "$2"; fi
}

# ---------------------------------------------------------------------------
# The simulated toolchain
# ---------------------------------------------------------------------------

chmod +x "$stub_lib"
for tool in xorriso wimlib-imagex mkfs.vfat mmd mcopy mdir sgdisk; do
    cat > "$stub_dir/$tool" <<EOF
#!/usr/bin/env bash
exec "$stub_lib" "$tool" "\$@"
EOF
    chmod +x "$stub_dir/$tool"
done

export STUB_STATE="$state_dir"
export FAKE_ISO="$fake_iso"
export PATH="$stub_dir:$PATH"

# Prove the stubs are what will be found, not something real on this machine.
for tool in xorriso wimlib-imagex mkfs.vfat mmd mcopy mdir sgdisk; do
    resolved="$(command -v "$tool")"
    if [ "$resolved" != "$stub_dir/$tool" ]; then
        echo "PATH shadowing failed for $tool (found $resolved)" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# A fake Windows ISO
# ---------------------------------------------------------------------------

mkdir -p "$fake_iso/sources" "$fake_iso/EFI/Microsoft/Boot/fonts" "$fake_iso/EFI/Boot"

# 3 MiB so the split path is exercised with --split-size 1.
dd if=/dev/zero of="$fake_iso/sources/install.wim" bs=1M count=3 status=none
dd if=/dev/zero of="$fake_iso/sources/boot.wim" bs=1k count=64 status=none
printf 'stub-bcd' > "$fake_iso/EFI/Microsoft/Boot/BCD"
printf 'stub-bootmgfw' > "$fake_iso/EFI/Microsoft/Boot/bootmgfw.efi"
printf 'stub-font' > "$fake_iso/EFI/Microsoft/Boot/fonts/chs_boot.ttf"

mkdir -p "$temp_root/drivers"
printf '[Version]\nSignature="$WINDOWS NT$"\n' > "$temp_root/drivers/stub.inf"

run_build() {
    local out_dir="$1"
    shift
    # Each run starts from a clean simulated device state.
    rm -rf "$state_dir/fat" "$state_dir/wim" "$state_dir/sgdisk"
    bash "$build_script" --iso "$fake_iso/win.iso-ignored" --out "$out_dir" "$@" > "$temp_root/last-run.log" 2>&1
    return $?
}

# The fake ISO has to look like a file to the script's `-f` check.
touch "$fake_iso/win.iso-ignored"

# ---------------------------------------------------------------------------
printf '\n== scenario 1: two-device medium, split image, ISO, answer file\n'
# ---------------------------------------------------------------------------

out1="$temp_root/out1"
work1="$temp_root/work1"

if run_build "$out1" --work "$work1" --iso-image --split-size 1 --esp-size-mb 64 \
        --unattended-disk 1 --unattended-serial 'SER-TEST-01' \
        --driver-dir "$temp_root/drivers" --keep-work; then
    pass 'build-media.sh exited 0'
else
    fail 'build-media.sh exited non-zero'
    sed 's/^/       /' "$temp_root/last-run.log" | tail -20
fi

assert_file "$out1/shimuefi-installer.img" 'the USB image was produced'
assert_file "$out1/shimuefi-installer.iso" 'the ISO was produced'
assert_file "$out1/manifest.txt" 'the manifest was produced'

# The FAT image is built as shimuefi-esp.img and only then moved into out/.
fat1="$state_dir/fat/shimuefi-esp.img.d"
assert_file "$fat1/EFI/Boot/BOOTX64.EFI" 'fallback loader is on the FAT image'
assert_file "$fat1/EFI/Microsoft/Boot/BCD" 'BCD is on the FAT image'
assert_file "$fat1/EFI/Microsoft/Boot/bootmgfw.efi" 'bootmgfw.efi is on the FAT image'
assert_file "$fat1/EFI/Microsoft/Boot/fonts/chs_boot.ttf" 'fonts were copied'
assert_file "$fat1/sources/boot.wim" 'boot.wim is on the FAT image'
assert_file "$fat1/sources/install.swm" 'install.wim was split to install.swm'
assert_absent "$fat1/sources/install.wim" 'the unsplit install.wim was not left behind'
assert_file "$work1/stage/drivers/stub.inf" 'extra drivers were staged at /drivers'

wim_entries="$state_dir/wim/boot.wim.entries"
assert_contains "$wim_entries" '/wintogo/wintogo.ps1' 'the installer script is patched into boot.wim'
assert_contains "$wim_entries" '/wintogo/engine/WinToGo.Guard.psm1' 'the engine is patched into boot.wim'
assert_contains "$wim_entries" '/Windows/System32/winpeshl.ini' 'winpeshl.ini is installed into the image'
assert_contains "$wim_entries" '/Windows/System32/startnet.cmd' 'startnet.cmd is installed into the image'
assert_not_contains "$wim_entries" 'winpeshl.ini.generated' 'the staging copy of winpeshl.ini does not ship in the payload'

assert_contains "$work1/payload/wintogo/unattended.json" '"diskNumber": 1' 'the answer file carries the disk number'
assert_contains "$work1/payload/wintogo/unattended.json" 'SER-TEST-01' 'the answer file carries the serial number'
assert_contains "$work1/payload/wintogo/unattended.json" 'X:\\\\drivers' 'the answer file points at the drivers'
assert_contains "$out1/manifest.txt" 'sha256' 'the manifest records checksums'
assert_contains "$temp_root/last-run.log" 'done' 'the build reported completion'

# ---------------------------------------------------------------------------
printf '\n== scenario 2: --no-split keeps install.wim whole\n'
# ---------------------------------------------------------------------------

out2="$temp_root/out2"
if run_build "$out2" --work "$temp_root/work2" --no-split --esp-size-mb 64; then
    pass 'build-media.sh exited 0 without splitting'
else
    fail 'build-media.sh failed with --no-split'
    tail -20 "$temp_root/last-run.log" | sed 's/^/       /'
fi

fat2="$state_dir/fat/shimuefi-esp.img.d"
assert_file "$fat2/sources/install.wim" 'install.wim stays whole under --no-split'
assert_absent "$fat2/sources/install.swm" 'no split parts are produced under --no-split'
assert_absent "$out2/shimuefi-installer.iso" 'no ISO is produced without --iso-image'

# ---------------------------------------------------------------------------
printf '\n== scenario 3: single-USB image (installer and target on one device)\n'
# ---------------------------------------------------------------------------

out3="$temp_root/out3"
disk_bytes=$((256 * 1024 * 1024))

if run_build "$out3" --work "$temp_root/work3" --single-usb \
        --disk-size "$disk_bytes" --esp-size-mb 128 --split-size 1 \
        --min-windows-size 64M; then
    pass 'build-media.sh exited 0 in single-USB mode'
else
    fail 'build-media.sh failed in single-USB mode'
    tail -20 "$temp_root/last-run.log" | sed 's/^/       /'
fi

single_image="$out3/shimuefi-single-usb.img"
assert_file "$single_image" 'the single-USB image was produced'
assert_absent "$out3/shimuefi-installer.img" 'the two-device image is not produced in single-USB mode'

if [ -f "$single_image" ]; then
    actual_size="$(stat -c %s "$single_image")"
    if [ "$actual_size" = "$disk_bytes" ]; then
        pass "the image covers the whole declared device ($actual_size bytes)"
    else
        fail "image size $actual_size does not match the declared $disk_bytes bytes"
    fi

    # The FAT filesystem must sit exactly at the first partition's 1 MiB offset.
    printf 'FATSTUB' > "$temp_root/fat-signature"
    if dd if="$single_image" bs=1 skip=$((1024 * 1024)) count=7 status=none 2>/dev/null \
            | cmp -s - "$temp_root/fat-signature"; then
        pass 'the FAT filesystem is embedded at the 1 MiB partition offset'
    else
        fail 'the FAT filesystem is not at the 1 MiB partition offset'
    fi

    # And nothing may be written before it, where the primary GPT lives.
    if dd if="$single_image" bs=1 skip=0 count=7 status=none 2>/dev/null \
            | cmp -s - "$temp_root/fat-signature"; then
        fail 'the FAT image was written at offset 0 and destroyed the GPT'
    else
        pass 'the primary GPT area was not overwritten by the FAT image'
    fi
fi

sgdisk_args="$state_dir/sgdisk/shimuefi-single-usb.img.args"
assert_file "$sgdisk_args" 'sgdisk was invoked for the single-USB layout'
assert_contains "$sgdisk_args" 'EF00' 'the layout declares an EFI system partition'
assert_contains "$sgdisk_args" '0C01' 'the layout declares a Microsoft reserved partition'
assert_contains "$sgdisk_args" '0700' 'the layout declares the Windows data partition'

assert_file "$state_dir/wim/boot.wim.entries" 'boot.wim was patched in single-USB mode'
assert_contains "$state_dir/wim/boot.wim.entries" '/wintogo/single-usb.json' 'the layout description ships with the payload'

# ---------------------------------------------------------------------------
printf '\n== scenario 4: refusal cases\n'
# ---------------------------------------------------------------------------

mkdir -p "$temp_root/bad-iso/sources" "$temp_root/bad-iso/EFI/Microsoft/Boot"
dd if=/dev/zero of="$temp_root/bad-iso/sources/boot.wim" bs=1k count=8 status=none
printf 'x' > "$temp_root/bad-iso/EFI/Microsoft/Boot/BCD"
printf 'x' > "$temp_root/bad-iso/EFI/Microsoft/Boot/bootmgfw.efi"
# The ISO must exist as a file, or the script stops at the earlier check.
printf 'stub' > "$temp_root/bad-iso/win.iso"

if STUB_STATE="$state_dir" FAKE_ISO="$temp_root/bad-iso" bash "$build_script" \
        --iso "$temp_root/bad-iso/win.iso" --out "$temp_root/out4" \
        > "$temp_root/bad.log" 2>&1; then
    fail 'a medium with no install image was accepted'
else
    pass 'a medium with no install image is refused'
fi
assert_contains "$temp_root/bad.log" 'install.wim' 'the refusal names the missing image'

if bash "$build_script" --iso "$fake_iso/win.iso-ignored" --out "$temp_root/out5" \
        --single-usb > "$temp_root/bad2.log" 2>&1; then
    fail 'single-USB mode was accepted without --disk-size'
else
    pass 'single-USB mode requires an explicit device size'
fi

if bash "$build_script" --iso "$fake_iso/win.iso-ignored" --out "$temp_root/out6" \
        --unattended-disk 1 > "$temp_root/bad3.log" 2>&1; then
    fail 'an unattended disk number without a serial was accepted'
else
    pass 'an unattended disk number without a serial is refused'
fi

# A single-USB device still has to hold Windows itself. 20 GB cannot: after the
# EFI partition, the MSR and both GPT copies nothing usable is left.
if bash "$build_script" --iso "$fake_iso/win.iso-ignored" --out "$temp_root/out7" \
        --single-usb --disk-size 20G > "$temp_root/bad4.log" 2>&1; then
    fail 'a 20 GB single-USB device was accepted'
else
    pass 'a single-USB device with no room for Windows is refused'
fi
assert_contains "$temp_root/bad4.log" 'for Windows' 'the refusal explains that Windows would not fit'
assert_contains "$temp_root/bad4.log" 'at least 25600 MiB' 'the refusal states how much room is required'
assert_absent "$temp_root/out7/shimuefi-single-usb.img" 'no image is produced for a device that cannot hold Windows'

# The check accounts for the real EFI partition, not just the device size.
if bash "$build_script" --iso "$fake_iso/win.iso-ignored" --out "$temp_root/out8" \
        --single-usb --disk-size 30G --esp-size-mb 8192 > "$temp_root/bad5.log" 2>&1; then
    fail 'a single-USB device whose EFI partition eats the space for Windows was accepted'
else
    pass 'an oversized EFI partition that leaves no room for Windows is refused'
fi
assert_absent "$temp_root/out8/shimuefi-single-usb.img" 'no image is produced for the oversized-ESP case'

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
if [ "$failures" -ne 0 ]; then
    printf '\033[1;31m%d of %d checks failed\033[0m\n' "$failures" "$checks"
    exit 1
fi
printf '\033[1;32mall %d checks passed\033[0m\n' "$checks"
exit 0
