# Architecture

Why the portable Windows subsystem is built the way it is, what it protects
against, and where it is weak.

## 1. Goal and threat model

**Goal.** Boot a genuine Windows installation from external storage on ordinary
x86-64 UEFI computers, and modify nothing on the internal disk.

**Assets, in priority order**

1. The internal disk of every computer the external disk is plugged into.
2. The external target disk's existing contents (destroyed by design, but only
   the selected one).
3. The integrity of the resulting Windows installation.

**Adversaries and failure modes** — these are what the design actually defends
against:

| Failure mode | Defence |
|---|---|
| Operator picks the wrong disk from a list | Serial number must be retyped; no default selection |
| Disk numbering changes between reboot and install (`disk 1` becomes `disk 0`) | Authorization is bound to serial + capacity, re-checked before every write |
| A cheap USB hub re-enumerates devices mid-install | Same re-check; the token no longer matches and the install aborts |
| A bug in the installer writes to the wrong device | All non-target disks are read-only/offline in the storage stack before the first write |
| A future code path forgets a check | Every destructive function requires a token parameter; there is no way to call it without one |
| The plugin's own medium gets overwritten | The disk holding the Windows image is removed from the target list |
| eMMC/UFS reported as something removable | Bus type is the gate, and eMMC is `MMC`, UFS is `UFS`, both internal |
| The firmware's own driver touches internal storage | Out of scope; the OS cannot prevent firmware writes |

**Explicitly out of scope:** malicious firmware, a compromised WinPE image, and
physical attacks. The project also cannot stop a *user* from running `diskpart`
manually in the WinPE shell.

## 2. Why WinPE instead of a custom bootloader

The project's own value is the storage-protection model, not a reimplementation of
Windows deployment. Reimplementing any of the following would be unsafe and
unverifiable:

- **BCD** is a registry-hive file with an undocumented schema and vendor
  extensions. `bcdboot` is the only writer that is correct across firmware
  variants. A hand-generated BCD is a "looks right, fails on some machines"
  artifact, which is exactly the sort of thing this project refuses to ship.
- **WinPE** already contains DISM, diskpart, bcdboot, the storage stack and the
  driver model. Writing our own is not feasible.
- **Offline registry editing** of `SYSTEM` and driver start types is documented
  Microsoft procedure; reimplementing hive parsing is unnecessary risk.

So the medium boots `sources/boot.wim` from the user's own Windows ISO — patched
at build time with our payload — and our code supplies the policy and the
orchestration. The Windows ISO is read on the build host and never redistributed.

### Alternatives that were rejected

| Alternative | Why not |
|---|---|
| A Linux live environment that applies the WIM with `wimlib` and generates BCD | No reliable BCD writer exists on Linux. `ms-sys` writes boot sectors, not BCD. This path produces media that boot-loops. |
| Booting `setup.exe` and answering its prompts | Setup owns the partitioning UI. Its "select a partition" flow is exactly the failure mode we must prevent. |
| A custom UEFI application that partitions and then chainloads `bootmgfw.efi` | Genuinely lower-level, and attractive for that reason, but it cannot apply a WIM or write BCD, needs `gnu-efi`/EDK2 and a cross toolchain to build, and its storage classification would be a second, divergent implementation of the same policy. Rejected on duplicated-logic grounds: two classifiers means two chances to be wrong. |
| Windows To Go official tooling (`wtga`/`Windows To Go` workspace) | Removed from Windows 10 2004 onward, and it did not protect internal disks from Setup. |
| Relying on the `removable` media bit alone | Many USB SSDs report `removable = 0`; many eMMC devices report it as removable. The bus type plus serial is stronger. |

## 3. Protection layers, in order

### 3.1 Classification (`WinToGo.Storage.psm1`)

Pure function over a disk record. Verdict and confidence are always accompanied by
machine-readable reasons, so the UI and the journal can explain *why*.

The gate is `STORAGE_BUS_TYPE`, not "does it look removable". `MMC` is eMMC and
internal; `SD` is a card slot and external but with reduced confidence because
some eMMC bridges lie. `Unknown` is blocked, never treated as external.

### 3.2 Authorization (`WinToGo.Guard.psm1`)

A token is a record of one disk: number, serial, capacity, bus, model, operator,
timestamp. It can only be issued by `New-WtgAuthorization`, which requires the
serial number typed by the operator.

`Assert-WtgDiskWritable` re-checks the live disk against the token before every
destructive step. This closes the time-of-check/time-of-use gap that disk numbers
alone leave open.

### 3.3 Storage-stack enforcement

`Get-WtgProtectionPlan` describes, and `Invoke-WtgProtectionPlan` applies:

- authorized target: writable;
- other external disks: read-only (the installer medium must stay readable);
- internal/unknown disks: offline **and** read-only.

Then `Test-WtgProtection` re-reads the disks. Any protected disk that is still
writable or online is a hard failure and the installer exits without writing.

These are storage-stack flags (`Set-Disk -IsReadOnly` / `-IsOffline`), enforced
below the filesystem. The installer's own correctness is no longer the only thing
standing between a bug and the internal disk.

### 3.4 Command-level belt and braces

`Assert-WtgNoWriteToProtected` refuses to execute a command line that names a
protected disk (`disk N`, `PhysicalDriveN`). It is a second net, not the primary
defence: a command can address a volume letter instead of a disk.

The generated diskpart script contains exactly one `select disk` statement, and a
unit test asserts that count. The script is generated fresh for each run from the
authorization, never templated with a stale number.

## 4. Layout decisions

The partition style follows the firmware: GPT for UEFI, MBR for BIOS. That is not
a preference — UEFI firmware cannot start an MBR disk on most implementations, and
BIOS firmware cannot start a GPT disk at all. `Get-WtgFirmwareMode` answers once,
the runtime derives both the layout and the installation mode from it, and
`Invoke-WtgInstall` refuses a layout that does not match the firmware it is
given.

### UEFI/GPT layout

| Partition | Size | Type | Filesystem |
|---|---|---|---|
| EFI | 512 MiB | EFI System | FAT32 |
| MSR | 16 MiB | Microsoft Reserved | none |
| Windows | remainder | Basic data | NTFS |

- **512 MiB ESP**, not 100 MiB: FAT32 with a 32 KiB cluster size is required on
  larger volumes, and firmware that writes NVRAM entries (and Windows servicing)
  is happier with headroom.
- **1 MiB alignment** at every boundary: correct on 512-byte and 4K-native disks,
  and what Windows itself uses on GPT.
- **1 MiB reserved at each end** of the disk for the primary and backup GPT.
- **No MBR path in UEFI mode**: an MBR installation cannot boot under UEFI, so the
  two layouts are kept separate rather than merged into one "universal" layout.
- **`EFI/BOOT/BOOTX64.EFI` alongside `EFI/Microsoft/Boot/bootmgfw.efi`**: firmware
  fallback paths vary wildly between vendors; the fallback copy is what makes the
  disk boot on an unfamiliar machine. `Confirm-WtgFallbackLoader` places it when
  `bcdboot` does not.
- **No recovery partition.** It would be unconfigured, because nothing here wires
  `reagentc`, so an option to create one would produce a partition that looks
  functional and is not. The layout has no such option.

### BIOS/MBR layout

Why not the ChromeOS shim chain: the RMA shim boots a signed ChromeOS kernel
through depthcharge, so no EFI runtime exists in which `bootmgfw.efi` could
execute, and the shim kernel has no working `kexec` to hand off with. Windows on a
Chromebook needs firmware that supplies a PC boot environment; the supported route
is the reversible RW_LEGACY payload (SeaBIOS), which keeps ChromeOS bootable.

| Partition | Size | Type | Filesystem | Role |
|---|---|---|---|---|
| Boot | 512 MiB | MBR `0x0c`, active | FAT32 | `\bootmgr`, `\Boot\BCD`, `boot.sdi`, fonts |
| Windows | remainder | MBR `0x07` | NTFS | Windows |

- **Boot files live on the active partition.** The chain is MBR code -> active
  partition -> `\bootmgr` -> `\Boot\BCD` -> `\Windows\System32\winload.exe`.
  `bcdboot /f BIOS` writes them there; `/f UEFI` would write an ESP layout that
  this firmware never reads.
- **`bootsect /nt60 S: /mbr` is part of the installation.** bcdboot only places
  files. The record that loads `\bootmgr`, and the master record that starts the
  active partition, are written afterwards and before verification. Without them
  the disk contains a correct Boot Manager and still does not start.
- **One active partition, no MSR, no ESP.** MSR and the EFI system partition are
  GPT concepts; MBR needs neither, and creating them would only mislead.
- **2 TiB is a hard limit.** MBR cannot describe a partition beyond 32 bits of
  512-byte sectors, so a larger disk is refused instead of partitioned into an
  extent the firmware cannot address.
- **No backup table**, so nothing is reserved at the end of the disk, unlike GPT.
- **Verification differs.** `Test-WtgLegacyInstallation` requires `\bootmgr`,
  `\Boot\BCD`, `winload.exe` and the SYSTEM hive, and deliberately does not
  require `winload.efi`: a BIOS installation does not use it, and demanding it
  would fail a working disk.

The installer stick itself is built the same way: an MBR disk with one active
FAT32 partition holding both `\bootmgr` and `\boot\BCD` (its volume boot record
is the FAT32 PE variant, with the hidden-sector field patched to the real
partition offset) and the UEFI files as well, so one medium can start on either
firmware.

### Single-USB layout

A medium built with `--single-usb` is both installer and target. Its GPT is laid
out at build time as EFI (holding WinPE and the Windows image) + MSR + an empty
Windows partition covering the rest, so the install never repartitions: it formats
one partition. Wiping the table would destroy the very ESP the installation image
is being read from.

The image therefore describes a fixed byte size, and the runtime compares the
real device capacity against the size recorded in `single-usb.json`. A mismatch is
refused with the size to rebuild for, rather than "repaired" by guessing: a GPT
that claims space the device does not have is the failure mode that produces an
unbootable stick.

Two checks are added on top of that:

- **The build refuses a device the installer would reject.** Two floors apply,
  both mirroring the runtime: `--min-device-size` (32 GiB,
  `New-WtgStoragePolicy -MinimumTargetBytes`, below which no disk is even
  eligible) and `--min-windows-size` (25 GiB left after subtracting the 1 MiB
  front reserve, the 1 MiB backup GPT, the real EFI partition and the 16 MiB
  MSR). The Windows-room check runs twice: at argument validation against the
  smallest possible ESP, and again once the real ESP size is known. Producing a
  stick that is refused only after it has been flashed and booted is the outcome
  this prevents.
- **The partition is verified before it is formatted.** In single-USB mode a
  partition number carries no meaning on its own, and partition 1 here is the ESP
  that holds the image this code was loaded from. `Invoke-WtgPartition` therefore
  reads the live table first and `Assert-WtgSingleUsbWindowsPartition` requires
  the target to be Microsoft basic data (not ESP, MSR or recovery), to report a
  size at or above the Windows minimum, and to be on a disk that still carries an
  ESP. Nothing is written unless all of that holds.

This costs no RAM. The obvious alternative — staging a 5 GB image in the WinPE
ramdisk — does not fit in a default WinPE X: volume, so it was rejected.

## 5. Portability decisions

The applied image stays in its shipped OOBE state. Specialization happens on the
first machine it boots on, which is the mechanism that makes the install portable
in the first place.

Additionally, in the offline `SYSTEM` hive:

| Setting | Reason |
|---|---|
| `PortableOperatingSystem = 1` | Documented Windows To Go marker; portable behaviour for the volume |
| `HibernateEnabled = 0` | Hibernation cannot be relocated off a removable volume |
| `USBXHCI`, `USBHUB3`, `USBSTOR`, `UASPStor`, `EhStorClass`, `stornvme`, `storahci`, `sdstor` `Start = 0` | Boot-start, so a machine whose controller driver was demoted can still bring up the bus it booted from |

Only inbox driver names are touched, so `reg add` patches an existing key instead
of creating an invalid service entry that would fail at boot.

Driver injection (`dism /Add-Driver /Recurse`) is offered for platforms whose
storage controller is not inbox (Intel RST/VMD being the common case).

What this does **not** do: generalize an image with `sysprep`. That requires
booting Windows and was deliberately avoided — the shipped OOBE state already
gives first-boot specialization.

## 6. Build system decisions

- **Linux/WSL2 and bash**, matching the repository's existing build conventions.
- **No mounting, no loop devices, no root**: the ESP is built as a file with
  `mkfs.vfat` and populated with `mtools`, and the ISO is assembled with
  `xorriso`. This makes the build work in containers and CI without privileges.
- **`wimlib` rather than DISM-on-Windows** for patching `boot.wim`: it works
  without a Windows host, does not need the image mounted, and can mark the image
  bootable.
- **`.swm` splitting** because FAT32 cannot hold a >4 GiB `install.wim`. This is
  Microsoft's own mechanism; WinPE's DISM applies it with `/SWMFile:`.
- **The payload is plain text** (PowerShell), so the medium contains nothing that
  must be compiled and the engine that runs is byte-identical to the engine under
  test.

## 7. Testing strategy

| Layer | How it is tested | Status |
|---|---|---|
| `build-media.sh` | Self-test runs the real script end to end with a simulated 7z/xorriso/wimlib/mtools/sgdisk/ms-sys/sfdisk on PATH and asserts on the produced FAT contents, patched WIM, split parts, manifest, ISO, single-USB layout, BIOS/MBR structures, firmware-specific ISO inspection and the refusal cases | Passing (106 checks) |
| Classification, authorization, protection plan, layouts | 75 unit tests with synthetic disk records, including eMMC/UFS/NVMe/SATA/SD/system-disk cases and the GPT and MBR layouts | Passing |
| A real BIOS boot on hardware | `ms-sys`, `bootsect.exe` and SeaBIOS loading `\bootmgr` | **Not run** — no Chromebook or legacy firmware here |
| Pipeline command generation | Unit test records every executor call during a full install with an internal disk attached and fails if any command names it | Passing |
| Real storage stack | QEMU/OVMF: internal disk as a qcow2 base + overlay; assert zero data clusters written and base hash unchanged | Not run here (needs ISO) |
| Real installation | End-to-end on hardware | Not run here |

The QEMU test measures at the virtual block layer, below Windows, so the
installer's own reporting cannot mask a write.

## 8. Known gaps

- No WinRE configuration, and no recovery partition: an unconfigured one would
  only be decoration.
- The build self-test proves the script's logic, not that the real tools accept
  these exact command lines; one run on Linux with the real packages is still owed.
- The protection plan cannot offline a disk the firmware has marked as the boot
  disk; those are always classified internal anyway, and `Set-Disk` may fail on
  them. In that case the read-only flag still applies and the run aborts only if
  neither flag could be verified.
- Two classifiers would have been the alternative to rejecting the custom-UEFI-app
  design; we chose one classifier, in PowerShell, running inside the environment
  that performs the writes.
- Windows 11 hardware checks are the image's own; no bypass is included.
