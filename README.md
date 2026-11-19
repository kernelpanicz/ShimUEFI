# ShimUEFI — Portable Windows

Boot and run a **genuine Windows installation from an external disk** (USB flash
drive, external SSD/HDD or SD card) on ordinary x86-64 UEFI computers, **without
ever writing to the computer's internal storage**.

The internal disk is not repartitioned, not formatted, not mounted and not
touched. You unplug the external drive and the computer is exactly as it was.
This is not a Linux environment dressed up as Windows: the result boots the real
Windows kernel, `winload.efi` and `bootmgfw.efi` from Microsoft.

> This repository began as [Shimboot](https://github.com/ading2210/shimboot), a
> ChromeOS RMA-shim bootloader for Debian. That code is still here and still
> builds (see [Legacy Shimboot](#legacy-shimboot)); the portable Windows system is
> a new, separate subsystem under `wintogo/`. Nothing about the Windows path
> reuses the ChromeOS shim.

---

## Contents

- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [Internal storage protection](#internal-storage-protection)
- [Requirements](#requirements)
- [Build the installation medium](#build-the-installation-medium)
- [Write the medium to a USB drive](#write-the-medium-to-a-usb-drive)
- [One USB drive is enough](#one-usb-drive-is-enough)
- [Install Windows onto an external disk](#install-windows-onto-an-external-disk)
- [Portability across computers](#portability-across-computers)
- [Supported and unsupported hardware](#supported-and-unsupported-hardware)
- [Testing](#testing)
- [Verification status](#verification-status)
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)
- [Legacy Shimboot](#legacy-shimboot)
- [Licence](#licence)

---

## What it does

Two separate pieces of external storage are involved, and they are not the same
disk:

| | Purpose |
|---|---|
| **Installer medium** | A small (≥2 GB) USB stick booted in UEFI mode. Runs WinPE plus the ShimUEFI installer. |
| **Target disk** | A second external disk (≥32 GB) that Windows is installed onto and then boots from. |

If you only have one USB drive, build the **single-USB** medium instead: the same
device is both the installer and the Windows disk. See
[One USB drive is enough](#one-usb-drive-is-enough).

The installer:

1. shows the computer's hardware and every attached disk, classified as
   internal, external or unknown;
2. lists only disks it is confident are external as possible targets;
3. requires you to retype the target's serial number;
4. takes **every other disk offline and read-only**, then verifies the storage
   stack accepted that;
5. partitions the target (GPT: ESP + MSR + Windows), applies the Windows image
   from the medium, writes Windows Boot Manager and BCD to the target's **own**
   ESP, sets the portable-OS registry flags, and verifies the boot files;
6. prints final instructions and optionally reboots.

Everything that ends up on the target — EFI system partition, BCD, boot manager,
Windows itself — lives on the target. The host's EFI partition is never used.

## How it works

```
  UEFI firmware
      │
      ▼
  Installer medium (FAT32 ESP)
   EFI/BOOT/BOOTX64.EFI ── Microsoft bootmgfw.efi
   EFI/Microsoft/Boot/BCD ── ramdisk → \sources\boot.wim
   sources/boot.wim ── WinPE + ShimUEFI payload (patched at build time)
   sources/install.wim | install.esd | install.swm
      │
      ▼
  WinPE (Microsoft) runs X:\wintogo\wintogo.ps1
      │
      ├── classify disks (WinToGo.Storage)
      ├── lock down internals (WinToGo.Guard → Set-Disk offline/read-only)
      ├── partition target (diskpart, generated script for one disk)
      ├── apply image (dism /Apply-Image)
      ├── boot manager (bcdboot → target ESP)
      ├── portable flags (reg load SYSTEM hive)
      └── verify boot files
      │
      ▼
  Target external disk: ESP (FAT32) + MSR + Windows (NTFS)
  Boots on this and other x86-64 UEFI machines via their own boot menu
```

### Why WinPE, and not a custom bootloader

Windows installation is not something that can be reimplemented safely:

- **BCD** is an undocumented Microsoft registry hive format. Tools that pretend to
  generate it produce media that fails on some firmware. `bcdboot` is the only
  reliable writer.
- **WIM/ESD** images need DISM (or `wimlib`, which we use on the build host, but
  which cannot configure a boot entry).
- **Driver injection, offline registry editing, and OOBE** all expect the Windows
  servicing stack.

So the medium boots Microsoft's own WinPE out of `sources/boot.wim` on the
Windows ISO **you already have**, and ShimUEFI contributes what WinPE does not
have: a storage-protection model, a fail-closed device classifier, an
authorization token system, and a scripted installation that never runs Windows
Setup's GUI (which is what would partition the wrong disk).

Because the ISO is yours and nothing is bundled, this project redistributes no
Microsoft code.

## Internal storage protection

This is the most important property of the project and it is enforced in four
independent layers.

### Layer 1 — classification, default deny

`Get-WtgDiskClassify` maps Windows' `STORAGE_BUS_TYPE` to a verdict:

| Bus type | Verdict | Confidence |
|---|---|---|
| `USB` (7) | External | High |
| `SD` (12) | External | Medium — some eMMC bridges report `SD` |
| `SATA` (11), `ATA` (3), `SCSI`/`SAS`, `NVMe` (17) | Internal | High |
| `MMC` (13) (eMMC), `UFS` (19) | Internal | High |
| `RAID`, `Spaces`, `Virtual`, `FileBackedVirtual`, `iSCSI`, `Fibre`, `IEEE1394` | Internal | High |
| anything else | **Unknown** | None — blocked |

Two rules override the bus type:

- A disk that hosts the running OS or is the firmware boot disk is always
  **Internal**, even if it is on USB.
- A disk with no serial number is never eligible: its identity cannot be
  confirmed at the moment of writing.

There is no "assume external" path. Unknown means blocked.

### Layer 2 — explicit authorization with a retyped serial

`New-WtgAuthorization` is the only way to obtain permission to write. It demands
the disk number **and** the serial number typed by the operator, re-runs the full
classification, and stores disk number, serial and capacity in a token.

### Layer 3 — re-validation before every write

`Assert-WtgDiskWritable` runs before each destructive step and compares the token
against the *live* disk: number, serial and capacity must still match and the
disk must still classify as external. A disk swapped mid-install, or a USB hub
that re-enumerated devices, fails the check instead of inheriting permission.

### Layer 4 — enforcement in the storage stack

Before the first write, `Invoke-WtgProtectionPlan` applies this to every attached
disk:

| Disk | Action |
|---|---|
| Authorized target | writable |
| Other external disks (including the installer medium) | read-only |
| Internal or unknown disks | **offline and read-only** |

It then re-reads the disks and **aborts the installation** unless every action
took effect. Those flags are enforced by the Windows storage stack and the port
drivers, not by this script: a bug in the installer cannot write to a disk the
storage stack has marked read-only.

The installer medium is read-only rather than offline so the Windows image stays
readable; internal disks are additionally offlined so they are not even mounted.

### What is *not* done

- The internal disk is never mounted, and never read from.
- Windows Setup (`setup.exe`) is never launched, so its partitioning logic never
  runs.
- No `select disk` command is ever generated for a disk other than the authorized
  one. The generated diskpart script contains exactly one `select disk` line, and
  a unit test asserts that.
- The disk holding the installer medium is removed from the target list, so the
  running installer cannot overwrite itself.

## Requirements

**Build host** — Linux or WSL2 (Debian/Ubuntu):

```bash
sudo apt install xorriso wimtools mtools dosfstools gdisk coreutils
```

**Media you must supply** — a Windows 10/11 x86-64 installation ISO that you
obtained legitimately. It is read at build time only; nothing is redistributed.
Windows 11 images need a TPM 2.0 / Secure Boot / CPU check bypass to install on
unsupported hardware; this project does not add one (see
[limitations](#known-limitations)).

**Targets** — a ≥2 GB USB stick for the installer and a ≥32 GB external disk
(USB flash, USB SSD/HDD, SD card) for Windows. 64 GB or more is strongly
recommended for Windows 11.

## Build the installation medium

```bash
git clone <this repository>
cd ShimUEFI-main

sudo ./wintogo/build/build-media.sh \
    --iso /path/to/Win11_24H2_English_x64.iso \
    --iso-image
```

Outputs:

| File | Use |
|---|---|
| `out/shimuefi-installer.img` | FAT32 image to write to the installer USB stick |
| `out/shimuefi-installer.iso` | Bootable ISO (UEFI El Torito), for VMs or optical/ISO boot |
| `out/manifest.txt` | SHA-256 checksums, source ISO name, contents |

Useful options:

```bash
--volume-name NAME        # FAT32 label (default WTGINSTALL)
--no-split                # keep install.wim whole (fails if > 4 GiB)
--split-size MB           # split size for .swm (default 3800)
--driver-dir DIR          # add storage drivers (e.g. Intel RST/VMD) to the medium
--allow-sd-card           # let the installer offer SD cards as targets
--allow-internal-bus-override   # let it offer NVMe/SATA enclosures (serial still required)
--single-usb --disk-size SIZE   # one image that is both installer and target
--min-windows-size SIZE   # room Windows must be left with in single-USB mode (25G)
--unattended-disk N --unattended-serial S --unattended-index I
--work DIR --keep-work
```

`--driver-dir`, `--allow-sd-card` and `--allow-internal-bus-override` are written
into `X:\wintogo\unattended.json` on the medium, so they take effect when it
boots. The same file carries the unattended disk/serial pair, if you set one.

`install.wim` is split into `.swm` parts automatically when it exceeds FAT32's
4 GiB file limit. An `install.esd` that is too large is first converted to a WIM
with `wimlib-imagex export` and then split.

The build is reproducible in the sense that it depends only on the ISO and the
files in `wintogo/`; there is no network access during the build.

## Write the medium to a USB drive

Linux:

```bash
lsblk                                  # identify the whole device, e.g. /dev/sdb
sudo dd if=out/shimuefi-installer.img of=/dev/sdb bs=4M \
        oflag=direct status=progress conv=fsync
```

Windows: use any raw image writer (Rufus in *DD image* mode, balenaEtcher, or
`Win32DiskImager`) and select the `.img`.

**Write the installer image to the installer stick, not to the disk you want to
install Windows onto.** The two must be different devices — unless you built the
single-USB medium, in which case that one device is both.

## One USB drive is enough

With `--single-usb` the medium is also the installation target, so a single USB
drive is all you need:

```bash
# find the exact capacity of the drive, then build for exactly that size
lsblk -b -d -o NAME,SIZE /dev/sdX

sudo ./wintogo/build/build-media.sh --iso /path/to/windows.iso \
    --single-usb --disk-size 64023257088

sudo dd if=out/shimuefi-single-usb.img of=/dev/sdX bs=4M \
        oflag=direct status=progress conv=fsync
```

The image is a GPT disk with three partitions: a FAT32 EFI partition holding
WinPE and the Windows image, a Microsoft reserved partition, and an empty
Windows partition covering the rest of the device.

When it boots, the installer recognises the layout description on the medium. It
formats only the Windows partition — the partition table and the EFI partition
holding the installation image are preserved, so a failed run can simply be
retried on the same stick. Everything else, including the storage protection, is
identical: the device is still an external disk that must be selected and have
its serial number confirmed.

Before it formats anything, it reads the device's partition table back and
requires the partition it is about to format to be Microsoft basic data, to
carry a plausible size, and to sit on a disk that still has an ESP. A partition
*number* is not evidence of what a partition *is*, and formatting the ESP here
would destroy the image the installer is running from.

Three constraints, all deliberate:

- **The declared size must match the device.** The image's partition table
  describes exactly `--disk-size` bytes; booting it on a smaller or larger disk
  would leave the table wrong, so the installer compares the real capacity and
  refuses with the correct size to rebuild for. Use bytes (or a `K`/`M`/`G`
  suffix); `lsblk -b` prints bytes.
- **The device must have room for Windows.** After the EFI partition, the MSR
  and both partition tables, at least 25 GiB (the same minimum the installer
  enforces) has to be left; a smaller `--disk-size` is refused at build time
  instead of producing a stick that cannot hold Windows. `--min-windows-size`
  overrides that minimum.
- **The installer payload stays on the EFI partition afterwards**, taking a few
  GB. Deleting it would remove the ability to retry the installation.

The two-device flow is still the better one when you have a spare stick: the
installer medium is then independent of the Windows disk.

## Install Windows onto an external disk

1. Plug in the installer stick **and** the empty external disk you want Windows
   on. Nothing on the target is preserved.
2. Boot the computer and open its one-time boot menu (`F12`, `F9`, `F10`, `Esc`
   depending on vendor), then choose the installer stick.
3. The installer starts in WinPE and shows:
   - the hardware it detected;
   - every disk, marked `INTERNAL`, `EXTERNAL` or `UNKNOWN`, with model, capacity,
     connection type and serial number;
   - which disks are selectable.
4. Pick a selectable disk by number. The installer reprints its model, capacity,
   bus type and serial number and asks you to **type the serial number**.
5. Choose the Windows edition from the image.
6. Review the partition layout.
7. The installer applies the storage protection plan and prints the state of every
   disk. It refuses to continue if protection cannot be verified.
8. Type `INSTALL`.
9. Wait. Partitioning, `dism /Apply-Image`, `bcdboot` and the portable registry
   settings are reported as progress and written to a log.
10. It finishes by verifying that `bootmgfw.efi`, `BCD`, `BOOTX64.EFI`,
    `winload.efi` and the SYSTEM hive are on the target, then prints boot
    instructions.

### Booting the result

- Keep the external disk connected and pick it in the computer's boot menu. Most
  firmware will find `\EFI\BOOT\BOOTX64.EFI` on its ESP, which is why the build
  places a copy there as well as under `\EFI\Microsoft\Boot\`.
- First boot finishes Windows setup (region, account, licence) on the target
  machine.
- Moving the disk to another computer: pick it in that computer's boot menu.
  Windows re-enumerates hardware on boot; expect a slow first boot while drivers
  install. Secure Boot must be in the same state (on/off) as when the image was
  installed if the firmware is strict about it.

### Automation

Every answer may come from `X:\wintogo\unattended.json` (written by the build
options above):

```json
{
  "diskNumber": 1,
  "serial": "S6T7TEST0001234",
  "imageIndex": 6,
  "driverDirectory": "X:\\drivers",
  "allowSdCard": true,
  "allowInternalBusOverride": false
}
```

A **disk number alone is refused**: the serial number is mandatory in every path,
because a disk number is not stable across reboots and firmware.

## Portability across computers

What the installation does to make the disk work elsewhere:

- **Generic UEFI**: GPT + a 512 MiB FAT32 ESP, with `EFI/BOOT/BOOTX64.EFI` present
  so firmware fallback paths find the loader without a BCD entry.
- **Boot-critical storage drivers are set boot-start** in the offline hive:
  `USBXHCI`, `USBHUB3`, `USBSTOR`, `UASPStor`, `EhStorClass`, `stornvme`,
  `storahci`, `sdstor`. All are inbox Windows 10/11 drivers; setting them to
  `Start=0` means a machine whose image had them disabled can still bring up the
  controller it booted from. This is what allows the same disk to boot over USB 3,
  NVMe and SATA on different machines.
- **Portable mode**: `PortableOperatingSystem=1` and `HibernateEnabled=0` are set
  in the offline SYSTEM hive. Hibernation cannot be relocated off a removable
  volume, so it is disabled rather than left broken.
- **No machine-specific state is baked in**: the image is applied in its shipped
  OOBE state and specialized on first boot, so hardware detection happens on the
  machine it is first booted on.
- **Optional driver injection** (`--driver-dir`, `dism /Add-Driver /Recurse`) for
  platforms whose disk controller is not inbox, typically Intel RST/VMD.

The partition layout reserves 1 MiB of alignment at every boundary, which works
on both 512-byte and 4K-native disks.

## Supported and unsupported hardware

**Supported (by design)**

- x86-64 computers with UEFI firmware (including UEFI with CSM disabled only; CSM
  / legacy BIOS boot is not supported).
- External USB flash drives, USB SSDs and USB HDDs, USB 3.x; SD cards via a
  UEFI-visible card reader.
- Internal storage of any type on the *host* — it is simply never used.
- 64-bit Windows 10 and 11 images (multi-edition `install.wim`/`install.esd`).

**Not supported, or supported only with manual work**

| Case | Status |
|---|---|
| Legacy BIOS / CSM boot | Not supported. UEFI only. |
| 32-bit UEFI (some tablets, older Atom) | Not supported. x64 only. |
| ARM64 (Snapdragon X, Surface Pro X) | Not supported. |
| Thunderbolt/USB4 NVMe enclosures | Reported as `NVMe`, so blocked by default. Build with `--allow-internal-bus-override` to offer them; the serial number is still required. |
| eSATA / SATA docking stations | Reported as `SATA`, so blocked by default. Same override as above. Enclosures that present as USB are fine. |
| SD cards | Reported as `SD`, which is only Medium confidence, so they are blocked by default. Build with `--allow-sd-card` to offer them. eMMC (bus type `MMC`) is never offered, with or without the flag. |
| SD cards in readers that do not expose the card to UEFI | Cannot be booted by the firmware; the installer will not list them. |
| Machines whose firmware only boots from the internal disk | Some locked-down corporate firmware ignores removable media entirely. |
| Intel RST / VMD-only machines | Windows needs the vendor driver. Use `--driver-dir` with the RST "F6" driver. |
| Windows 11 on unsupported CPU/TPM | Not handled. The image's own checks apply. |
| BitLocker / device encryption | Off by default here. Enabling it on a portable install is unsupported. |
| macOS, ChromeOS firmware | Not supported. |

No universal compatibility is claimed. Portability depends on the machine's
firmware, its USB/NVMe/SATA controller and Secure Boot policy; the project only
guarantees what is described above and what the [testing section](#testing) can
demonstrate.

## Testing

### Unit tests (run anywhere, no hardware needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File wintogo/tests/run-tests.ps1
```

67 tests across four suites, covering device classification (including eMMC, UFS,
NVMe, SATA, SD, unknown bus types and system disks), authorization and the
pre-write re-validation, the protection plan, the command filter, the GPT layout
arithmetic, the single-USB layout check, the diskpart script generators, the DISM
output parser, the offline registry operations, and full pipeline runs with a
recorded command executor that fails if any command names an internal disk.

### Build script self-test

```bash
bash wintogo/tests/build-media-selftest.sh
```

`bash -n` only proves `build-media.sh` parses. This harness puts a **simulated
media toolchain** on `PATH` (`xorriso`, `wimlib-imagex`, `mkfs.vfat`, `mmd`,
`mcopy`, `mdir`, `sgdisk`), points it at a synthetic Windows ISO tree, and runs
the real script end to end. It then checks what the script actually produced:

- the FAT image contains `EFI/Boot/BOOTX64.EFI`, `BCD`, `bootmgfw.efi`, fonts,
  `boot.wim` and the split `install.swm`, and the unsplit image is gone;
- `boot.wim` was patched with `/wintogo/wintogo.ps1`, the engine,
  `winpeshl.ini` and `startnet.cmd`, and the staging copy did not leak in;
- the answer file carries the disk number, serial and driver path;
- the manifest has sha256 checksums; the ISO is produced only with `--iso-image`;
- in single-USB mode the image is exactly the declared size, the FAT filesystem
  lands at the 1 MiB partition offset, the GPT area is untouched, and the
  partition types are EFI/MSR/Windows;
- a single-USB device with no room left for Windows is refused, both by total
  size and when an oversized EFI partition is what consumed the space, and no
  image is written for it;
- malformed inputs (no install image, `--single-usb` without `--disk-size`, an
  unattended disk number without its serial) are refused.

48 checks, and it runs on every push in CI.

### Virtual machine test (needs a built ISO and KVM/TCG)

```bash
./wintogo/build/build-media.sh --iso /path/to/windows.iso --iso-image \
    --unattended-disk 1 --unattended-serial 'YOUR-TARGET-SERIAL'

sudo ./wintogo/tests/qemu/run-protection-test.sh \
    --iso out/shimuefi-installer.iso \
    --scenario internal-external
```

The virtual "internal disk" is a qcow2 base image with an overlay. The VM is
given an emulated USB 3 external disk and the installer runs unattended. After
the run the script asserts, at the virtual hardware boundary:

- the internal disk's overlay contains **zero data clusters**, and
- the base image is byte-identical (SHA-256 before/after).

That is measured below Windows, so it cannot be fooled by the installer's own
reporting. Scenarios: `internal-external`, `external-only`, `many-disks`,
`no-internal`.

## Verification status

Being explicit about what has and has not been run, because a claim of "tested"
matters more here than anywhere else.

**Verified in this repository**

- **`build-media.sh` really runs**: the self-test executes it end to end against a
  simulated toolchain and asserts on the resulting FAT contents, patched WIM,
  split parts, manifest, ISO and single-USB partition layout (48 checks).
- The 67 unit tests pass under Windows PowerShell 5.1 (the PowerShell version
  present in WinPE) on a real Windows host.
- The storage classifier was run against real hardware: on the development
  machine it correctly classifies the internal NVMe system disk as
  `Internal/High` and refuses to build a target list from it.

**Not verified here, and therefore not claimed to work**

- The **real** toolchain. The self-test substitutes `xorriso`, `wimlib-imagex`,
  `mkfs.vfat`, mtools and `sgdisk`, so it proves the script's own logic, not that
  those tools accept these exact command lines. Running it once on Linux with the
  real packages installed is still the last step.
- An actual Windows installation end to end (`diskpart`, `dism`, `bcdboot`,
  offline registry edits) on real or virtual hardware; it needs a Windows ISO and
  QEMU/OVMF.
- The QEMU protection test, which requires the above.
- Boot on more than one physical machine.

Treat the pipeline as implemented-but-unproven on your hardware until you have run
the QEMU test and one real installation. Everything it invokes is a documented
Microsoft procedure; the tests cover the logic that decides *which disk*.

## Known limitations

- **No WinRE.** There is no recovery partition. Nothing in this project wires one
  into `reagentc`, and an unconfigured recovery partition would be decoration that
  looks like a feature, so the layout has no option to create one.
- **Hibernation and fast startup are disabled** — both need a fixed non-removable
  volume.
- **Windows Update may install firmware drivers** that assume the machine it first
  booted on. Moving the disk back and forth between very different machines can
  leave stale drivers; Device Manager may need attention.
- **Performance depends on the bus.** A USB 2.0 stick will be unusably slow; USB
  3.x SSD is the recommended minimum.
- **The internal disk is offlined, not physically removed.** Firmware-level access
  (for example a vendor firmware update utility in the same boot) is outside this
  project's control.
- **SD card targets are off by default** and need `--allow-sd-card` at build
  time, because some eMMC bridges report themselves as `SD`. eMMC proper is
  `MMC` and is always treated as internal.
- **The image must be WIM/ESD based.** A Windows 7-era ISO or a WIM with unusual
  compression may be rejected by `wimlib`; the build says so instead of producing
  a broken medium.

## Repository layout

```
wintogo/
  engine/
    WinToGo.Storage.psm1    disk enumeration, classification, eligibility
    WinToGo.Guard.psm1      authorization tokens, protection plan, journal
    WinToGo.Layout.psm1     GPT layout arithmetic
    WinToGo.Install.psm1    diskpart / dism / bcdboot / reg orchestration
  runtime/
    wintogo.ps1             console installer (runs in WinPE)
    winpeshl.ini            WinPE launch definition
    startnet.cmd            fallback launch path
  build/
    build-media.sh          builds the USB image / ISO from your Windows ISO
  tests/
    run-tests.ps1           test runner
    *.Tests.ps1             unit suites
    build-media-selftest.sh runs build-media.sh against a simulated toolchain
    lib/media-stubs.sh      the simulated xorriso/wimlib/mtools/sgdisk
    qemu/                   zero-write verification with OVMF
docs/
  ARCHITECTURE.md           design decisions, threat model, trade-offs
  LEGACY-SHIMBOOT.md        the original Shimboot documentation
```

The original Shimboot scripts (`build.sh`, `build_complete.sh`, `build_rootfs.sh`,
`patch_rootfs.sh`, `build_squashfs.sh`, `shim_utils.sh`, `image_utils.sh`,
`common.sh`, `bootloader/`, `rootfs/`, `squashfs/`) are untouched and still build
a ChromeOS-shim Debian image.

## Legacy Shimboot

The ChromeOS RMA-shim bootloader still works exactly as before:

```bash
sudo ./build_complete.sh <board_name>      # e.g. dedede
```

Its documentation — device compatibility tables, distro/desktop options, LUKS,
FAQ — is preserved in [docs/LEGACY-SHIMBOOT.md](docs/LEGACY-SHIMBOOT.md). The two
subsystems share only the build-host assumptions and the licence; booting a
Chromebook from a signed RMA shim has nothing to do with booting Windows from an
external disk.

## Licence

GNU GPL v3. See [LICENSE](LICENSE).

```
ShimUEFI portable Windows: boot Windows from an external disk without touching
internal storage.
Copyright (C) 2026 ShimUEFI contributors

Based on ading2210/shimboot:
Copyright (C) 2025 ading2210

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program.  If not, see <https://www.gnu.org/licenses/>.
```

Windows, WinPE, DISM and BCD are Microsoft trademarks and are not distributed by
this project. You supply your own Windows installation media.
