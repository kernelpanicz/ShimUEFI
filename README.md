# ShimUEFI — Portable Windows

Run a **real Windows installation from a USB drive or external SSD** on x86-64
UEFI computers — and, with legacy BIOS firmware, on Chromebooks — **without ever
writing to that computer's internal disk**.

Nothing is repartitioned, formatted or mounted inside the machine. Unplug the
drive and the computer is exactly as it was. This is not a Linux desktop dressed
up as Windows: it boots Microsoft's own `bootmgfw.efi`, `winload.efi` and
Windows kernel from media built out of the Windows ISO **you** supply. No
Microsoft files are stored in this repository.

> Started life as [Shimboot](https://github.com/ading2210/shimboot), a ChromeOS
> RMA-shim bootloader for Debian. That path still works unchanged — see
> [Legacy Shimboot](#legacy-shimboot). The Windows system lives in `wintogo/` and
> shares nothing with it.

## Quick start

**You need**

- A Linux or WSL2 build host with `xorriso`, `wimtools`, `mtools`, `dosfstools`,
  `gdisk`.
- A Windows 10/11 x86-64 installation ISO (WIM or ESD).
- An empty USB stick (≥2 GB) for the installer, and an external disk (≥32 GB,
  64 GB+ recommended) for Windows.
- A computer that boots x86-64 UEFI, or legacy BIOS with `--boot-mode bios`
  (see [Chromebooks](#chromebooks-legacy-bios--rw_legacy)).

```bash
sudo apt install xorriso wimtools mtools dosfstools gdisk

sudo ./wintogo/build/build-media.sh --iso /path/to/windows.iso
```

That writes `out/shimuefi-installer.img`. Put it on the stick — **not** on the
disk Windows will use:

```bash
lsblk                                   # find the whole device, e.g. /dev/sdb
sudo dd if=out/shimuefi-installer.img of=/dev/sdb bs=4M \
        oflag=direct status=progress conv=fsync
```

Then plug in both drives, open the computer's boot menu (`F12`, `F9`, `F10` or
`Esc`), boot the stick, pick the external disk, **retype its serial number**,
choose the edition and type `INSTALL`. The installer does the rest and prints
boot instructions.

## One USB drive is enough

With `--single-usb` the same device is both installer and Windows disk:

```bash
lsblk -b -d -o NAME,SIZE /dev/sdX       # exact capacity, in bytes

sudo ./wintogo/build/build-media.sh --iso /path/to/windows.iso \
    --single-usb --disk-size 64023257088

sudo dd if=out/shimuefi-single-usb.img of=/dev/sdX bs=4M \
        oflag=direct status=progress conv=fsync
```

The image is a whole GPT disk: an EFI partition holding WinPE and the Windows
image, a Microsoft reserved partition, and an empty Windows partition for the
rest. At install time only that last partition is formatted; the partition table
and the EFI partition are preserved, so a failed run can simply be retried.

The build refuses to produce media the installer would reject:

- **`--disk-size` must be at least 32 GiB** — the installer's own minimum target
  — and must have 25 GiB left for Windows after the EFI partition and MSR.
- **The exact capacity must match.** Booting the stick on a different-sized
  device is refused, with the size to rebuild for.

Before formatting anything, the installer reads the partition table back and
requires the target to really be a Windows data partition on a disk that still
has an ESP. A wrong partition number would otherwise destroy the image it is
running from.

## What the installer does

1. Shows the hardware and every attached disk, classified as `INTERNAL`,
   `EXTERNAL` or `UNKNOWN`.
2. Offers only disks it is confident are external.
3. Requires the serial number of the chosen disk to be typed back.
4. Makes every other disk read-only, and internal disks offline as well, then
   verifies the storage stack accepted it.
5. Partitions the target (GPT: ESP + MSR + Windows), applies the Windows image
   with `dism`, writes Windows Boot Manager and BCD to the target's own ESP with
   `bcdboot`, and sets the portable-OS registry flags.
6. Verifies the boot files and prints how to boot it.

Windows Setup (`setup.exe`) is never launched, so its partitioning logic never
runs on your machine.

## Why your internal disk is safe

Four independent layers, all failing closed:

| Layer | What it does |
|---|---|
| **Classification** | Windows' `STORAGE_BUS_TYPE` decides: USB/SD = external, SATA/NVMe/eMMC/UFS/RAID/virtual = internal, anything unrecognised = **Unknown, blocked**. The system disk is always internal, even on USB. Every disk must also report a serial number. |
| **Authorization** | A write token is issued only for a disk whose number *and* retyped serial match, after classification runs again. |
| **Re-validation** | Before every destructive step the token is compared with the live disk: number, serial and capacity. A swapped or re-enumerated disk fails instead of inheriting permission. |
| **Storage stack** | All other disks are set offline + read-only and re-read to confirm. Those flags are enforced by Windows and the port drivers, not by this script. |

Also never done: the internal disk is not mounted or read; the generated
`diskpart` script contains exactly one `select disk` line, for the authorized
disk only; and the installer's own device is removed from the target list.

Details and trade-offs: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build options

| Option | Effect |
|---|---|
| `--iso-image` | Also write `out/shimuefi-installer.iso` (VMs, optical boot) |
| `--driver-dir DIR` | Add storage drivers (e.g. Intel RST/VMD) and inject them offline |
| `--allow-sd-card` | Offer SD cards as targets |
| `--allow-internal-bus-override` | Offer NVMe/SATA enclosures (serial still required) |
| `--single-usb --disk-size SIZE` | One device as installer and target |
| `--min-device-size SIZE` | Smallest device allowed, default `32G` (matches the installer policy) |
| `--boot-mode uefi\|bios` | `uefi` (default): GPT + `bootmgfw.efi`. `bios`: MBR + `\bootmgr` for legacy firmware |
| `--min-windows-size SIZE` | Room Windows must be left with, default `25G` |
| `--unattended-disk N --unattended-serial S` | Pre-fill the target; the serial is still verified |
| `--unattended-index N` | Pre-select a Windows edition |
| `--no-split`, `--split-size MB` | Control `.swm` splitting (default 3800 MB) |
| `--work DIR`, `--keep-work` | Build directory / keep intermediates |

Options that change behaviour at install time are written to
`X:\wintogo\unattended.json` on the medium. Every answer file still requires the
serial number: a bare disk number is refused.

## Supported hardware

Works with x86-64 UEFI firmware, USB sticks/SSDs/HDDs, and SD cards in a reader
the firmware can see. Internal storage of any kind is simply never used.

| Case | Result |
|---|---|
| Legacy BIOS/CSM on a PC, or Chromebook with RW_LEGACY | Supported with `--boot-mode bios`; the disk is MBR |
| ChromeOS firmware with no PC boot payload (the RMA shim) | Cannot run Windows: see [Chromebooks](#chromebooks-legacy-bios--rw_legacy) |
| 32-bit UEFI, ARM64 | Not supported |
| Thunderbolt/USB4 NVMe and SATA docks | Reported as NVMe/SATA, so blocked unless built with `--allow-internal-bus-override` |
| SD cards | Blocked unless built with `--allow-sd-card`; eMMC is always internal |
| Intel RST/VMD-only machines | Needs the vendor driver via `--driver-dir` |
| Windows 11 on unsupported CPU/TPM | The image's own checks apply; no bypass is added |

No universal compatibility is claimed: portability depends on the firmware, the
controller and Secure Boot policy of each machine.

## Chromebooks (legacy BIOS / RW_LEGACY)

Windows cannot start through the ChromeOS RMA shim. The shim boots a signed
ChromeOS kernel through depthcharge, so there is no EFI runtime for
`bootmgfw.efi` to run in, and the shim kernel has no working `kexec`. Windows on
a Chromebook therefore needs firmware that provides a PC boot environment. The
smallest such change is the **reversible RW_LEGACY payload** (SeaBIOS), which
leaves ChromeOS bootable:

1. Install RW_LEGACY firmware for your exact board with the MrChromebox firmware
   utility. This is a firmware change made outside this project; a failed write
   can brick the device.
2. Build the BIOS medium:

   ```bash
   sudo ./wintogo/build/build-media.sh --iso /path/to/windows.iso --boot-mode bios
   ```

3. `dd` `out/shimuefi-installer-bios.img` to the installer stick, boot the
   Chromebook, press **Ctrl+L** at the developer-mode screen to enter SeaBIOS, and
   pick the stick.
4. Install onto a second external disk as usual. The target becomes MBR with
   `\bootmgr` and `\Boot\BCD` on its active partition: the genuine Windows Boot
   Manager in BIOS mode, started by the firmware's own boot code.
5. To start Windows later, Ctrl+L again and pick the disk. Without it, ChromeOS
   starts normally.

`--boot-mode bios` and `--single-usb` are refused together: a single-USB medium
is GPT and BIOS firmware cannot start it. The build stops before writing
anything.

**Expect a rough ride on hardware.** RW_LEGACY is documented as Linux-only by
[chrultrabook](https://docs.chrultrabook.com/docs/faq.html); this project makes
the Windows boot chain correct, but Chromebook audio, touchpad and power
management have no Windows drivers without the full UEFI ROM and per-board
driver work.

## Testing

```powershell
# 75 unit tests; no hardware, no Windows image needed
powershell -NoProfile -ExecutionPolicy Bypass -File wintogo/tests/run-tests.ps1
```

```bash
# runs build-media.sh end to end against a simulated xorriso/wimlib/mtools/sgdisk
bash wintogo/tests/build-media-selftest.sh
```

The unit tests cover disk classification, authorization, the pre-write
re-check, the protection plan, layout arithmetic, the single-USB checks, the
`diskpart` script generators and full pipeline runs that fail if any command
names an internal disk. The self-test asserts on what the build actually
produced: FAT contents, patched `boot.wim`, split parts, manifest, ISO, the
single-USB layout, and the refusal of devices that are too small. Both run in CI
on every push.

Virtual machine test (needs the real toolchain plus QEMU/OVMF):

```bash
sudo ./wintogo/tests/qemu/run-protection-test.sh --iso out/shimuefi-installer.iso
```

It gives the VM an internal disk as a qcow2 base + overlay and an emulated USB
external disk, then asserts at the virtual block layer that the overlay contains
zero data clusters and the base image is byte-identical.

### What has actually been verified

- ✅ `build-media.sh` runs end to end against a simulated toolchain (65 checks),
  including the BIOS/MBR image: 0x55AA signature, active FAT32 partition, the
  volume boot record at the 1 MiB offset, and `\bootmgr` + `\Boot\BCD` staged.
- ✅ 75 unit tests pass on Windows PowerShell 5.1, the version WinPE ships.
- ✅ The classifier was run against real hardware and flagged the internal NVMe
  system disk as internal, refusing to build a target list from it.
- ❌ The real toolchain (`xorriso`, `wimlib`, `mtools`, `sgdisk`) has not been
  exercised here — the self-test substitutes it.
- ❌ No end-to-end Windows installation has been run, and the QEMU protection
  test has not been run, because both need a Windows ISO and QEMU/OVMF.
- ❌ The BIOS path has not been run on hardware: `ms-sys`, `bootsect.exe`, and
  SeaBIOS starting `\bootmgr` from a real disk are all unexercised here. The
  self-test proves the image structure, not that a Chromebook boots it.
- ❌ Not booted on more than one physical machine.

Everything invoked is a documented Microsoft procedure; the tests cover the
logic that decides *which disk*. Treat the pipeline as unproven on your hardware
until you have run the QEMU test and one real installation.

## Limitations

- **BIOS installs are unproven on real hardware** (see above), and RW_LEGACY
  firmware is Linux-only by its own documentation. The boot chain is correct; the
  machine may still lack drivers for sound, touchpad and power.
- **MBR stops at 2 TiB.** A larger disk is refused in BIOS mode rather than
  partitioned into something the firmware cannot address.

- **No WinRE**: no recovery partition is created, because nothing here wires one
  into `reagentc`.
- **Hibernation and fast startup are disabled**; both need a fixed internal disk.
- **Windows Update may install machine-specific firmware drivers**; moving the
  drive between very different machines can leave stale ones.
- **A USB 2.0 stick is unusably slow.** USB 3.x SSD is the realistic minimum.
- **The internal disk is offlined, not removed**: firmware-level access in the
  same boot session is outside this project's control.
- **BitLocker is off** in portable installs and is not supported on them.

## Repository layout

```
wintogo/
  engine/     WinToGo.{Storage,Guard,Layout,Install}.psm1   the logic under test
  runtime/    wintogo.ps1, winpeshl.ini, startnet.cmd       console installer (WinPE)
  build/      build-media.sh                                builds the medium
  tests/      run-tests.ps1, *.Tests.ps1, build-media-selftest.sh, qemu/
docs/
  ARCHITECTURE.md      design decisions, threat model, trade-offs
  LEGACY-SHIMBOOT.md   the original Shimboot documentation
```

The original Shimboot scripts (`build.sh`, `build_complete.sh`, `bootloader/`,
`rootfs/`, …) are untouched.

## Legacy Shimboot

The ChromeOS RMA-shim Debian image still builds as before:

```bash
sudo ./build_complete.sh <board_name>     # e.g. dedede
```

Device tables, distro options, LUKS and the FAQ are preserved in
[docs/LEGACY-SHIMBOOT.md](docs/LEGACY-SHIMBOOT.md).

## Licence

GNU GPL v3 — see [LICENSE](LICENSE).

Based on [ading2210/shimboot](https://github.com/ading2210/shimboot),
Copyright (C) 2025 ading2210. ShimUEFI additions Copyright (C) 2026 ShimUEFI
contributors.

Windows, WinPE, DISM and BCD are Microsoft trademarks. This project distributes
no Microsoft code; you supply your own Windows installation media.
