# WinToGo.Layout.psm1
#
# Partition layout for the installation target.
#
# Three layouts exist:
#
#   Fresh      the target is a whole empty disk: GPT with ESP + MSR + Windows.
#   SingleUsb  the target is the installer medium itself, so its GPT already
#              carries ESP + MSR + an empty Windows partition from the build and
#              only the Windows partition is formatted.
#   Legacy     the target is a whole empty disk on BIOS firmware: MBR with one
#              active FAT32 boot partition and one NTFS Windows partition.
#
# The style is not a preference: UEFI firmware cannot boot an MBR disk on most
# implementations, and BIOS firmware cannot boot a GPT ESP at all. The installer
# refuses a layout that does not match the firmware it is running on.
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

Set-StrictMode -Version 2.0

$script:MiB = 1MB
$script:GiB = 1GB

# GPT primary header plus the alignment gap at the start of the disk.
$script:FrontReserveBytes = 1MB
# Room for the backup GPT header/table at the end of the disk.
$script:BackReserveBytes = 1MB

function New-WtgLayoutPlan {
    <#
    .SYNOPSIS
        Computes the GPT partition layout for a whole empty target disk.

    .DESCRIPTION
        Three partitions, no recovery partition. Windows Recovery Environment is
        not configured by this project: nothing here wires a recovery partition
        into reagentc, and shipping an empty one would only produce a partition
        that looks useful and is not.

    .PARAMETER DiskSize
        Capacity of the target disk in bytes.

    .OUTPUTS
        Partitions[]  Name, Type, StartBytes, SizeBytes, SizeMB
        Valid, Errors, UnallocatedBytes
    #>
    param(
        [Parameter(Mandatory = $true)][long]$DiskSize,
        [int]$EspSizeMB = 512,
        [int]$MsrSizeMB = 16,
        [long]$MinimumWindowsBytes = 25GB,
        [int]$AlignmentBytes = 1MB
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'

    if ($EspSizeMB -lt 260) { $errors.Add('the EFI system partition must be at least 260 MB') }
    if ($MsrSizeMB -lt 16)   { $errors.Add('the Microsoft reserved partition must be at least 16 MB') }
    if ($AlignmentBytes -lt 4096) { $errors.Add('alignment must be at least 4 KiB') }

    $front = [long]$script:FrontReserveBytes
    $back  = [long]$script:BackReserveBytes
    $usable = [long]$DiskSize - $front - $back

    $espBytes = [long]$EspSizeMB * $script:MiB
    $msrBytes = [long]$MsrSizeMB * $script:MiB

    $windowsBytes = $usable - $espBytes - $msrBytes

    if ($windowsBytes -lt $MinimumWindowsBytes) {
        $errors.Add(('a {0:N1} GB disk leaves only {1:N1} GB for Windows, which is below the {2:N0} GB minimum' -f `
            ($DiskSize / $script:GiB), ($windowsBytes / $script:GiB), ($MinimumWindowsBytes / $script:GiB)))
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid            = $false
            Errors           = $errors.ToArray()
            Partitions       = @()
            DiskSize         = $DiskSize
            UnallocatedBytes = 0
        }
    }

    # Every partition start is rounded up to the alignment so 4Kn disks and
    # firmware that rejects unaligned extents are both happy.
    $align = {
        param([long]$value, [int]$alignment)
        $remainder = $value % $alignment
        if ($remainder -eq 0) { return $value }
        return $value + ($alignment - $remainder)
    }

    $partitions = New-Object 'System.Collections.Generic.List[object]'
    $cursor = & $align $front $AlignmentBytes

    $partitions.Add([pscustomobject]@{ Name = 'EFI';     Type = 'efi';     StartBytes = $cursor; SizeBytes = $espBytes;      SizeMB = $EspSizeMB })
    $cursor = & $align ($cursor + $espBytes) $AlignmentBytes

    $partitions.Add([pscustomobject]@{ Name = 'MSR';     Type = 'msr';     StartBytes = $cursor; SizeBytes = $msrBytes;      SizeMB = $MsrSizeMB })
    $cursor = & $align ($cursor + $msrBytes) $AlignmentBytes

    $partitions.Add([pscustomobject]@{ Name = 'Windows'; Type = 'primary'; StartBytes = $cursor; SizeBytes = $windowsBytes;  SizeMB = [int][math]::Floor($windowsBytes / $script:MiB) })
    $cursor = & $align ($cursor + $windowsBytes) $AlignmentBytes

    $unallocated = [long]$DiskSize - $cursor

    return [pscustomobject]@{
        Valid            = $true
        Errors           = @()
        Partitions       = $partitions.ToArray()
        DiskSize         = $DiskSize
        UnallocatedBytes = $unallocated
        WindowsBytes     = $windowsBytes
    }
}

function Test-WtgSingleUsbTarget {
    <#
    .SYNOPSIS
        Checks that a device really is the one a single-USB medium was built for.

    .DESCRIPTION
        A single-USB medium carries a GPT that only covers the device it was built
        for, and a Windows partition sized to that device. Booting it on a larger
        or smaller disk would leave the partition table describing space that does
        not exist, so the declared size is compared against the real capacity and
        any mismatch is refused rather than "repaired" by guessing.

    .PARAMETER LayoutInfo
        Contents of single-usb.json from the medium.

    .OUTPUTS
        Valid, Errors
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        $LayoutInfo,
        [long]$ToleranceBytes = 1MB
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'

    if ($null -eq $LayoutInfo) {
        $errors.Add('this medium carries no single-USB layout description')
        return [pscustomobject]@{ Valid = $false; Errors = $errors.ToArray() }
    }

    $declaredProperty = $LayoutInfo.PSObject.Properties['diskSizeBytes']
    $declared = 0L
    if ($null -ne $declaredProperty -and $null -ne $declaredProperty.Value) {
        $declared = [long]$declaredProperty.Value
    }

    if ($declared -le 0) {
        $errors.Add('the layout description on this medium declares no device size')
        return [pscustomobject]@{ Valid = $false; Errors = $errors.ToArray() }
    }

    $sizeProperty = $Disk.PSObject.Properties['Size']
    $actual = 0L
    if ($null -ne $sizeProperty -and $null -ne $sizeProperty.Value) { $actual = [long]$sizeProperty.Value }

    if ($actual -le 0) {
        $errors.Add('the device reports no capacity')
    }
    else {
        $difference = [math]::Abs($actual - $declared)
        if ($difference -gt $ToleranceBytes) {
            $errors.Add(('this device is {0} bytes but the medium was built for {1} bytes; rebuild it with --disk-size {0}' -f $actual, $declared))
        }
    }

    $windowsProperty = $LayoutInfo.PSObject.Properties['windowsPartition']
    $windowsPartition = 3
    if ($null -ne $windowsProperty -and $null -ne $windowsProperty.Value) { $windowsPartition = [int]$windowsProperty.Value }
    if ($windowsPartition -lt 1) {
        $errors.Add('the layout description names no Windows partition')
    }

    return [pscustomobject]@{
        Valid            = ($errors.Count -eq 0)
        Errors           = $errors.ToArray()
        DiskSize         = $declared
        WindowsPartition = $windowsPartition
    }
}

function New-WtgLegacyLayoutPlan {
    <#
    .SYNOPSIS
        Computes the MBR partition layout for a whole empty target disk on BIOS
        firmware.

    .DESCRIPTION
        The BIOS boot chain is MBR -> active partition -> \bootmgr -> \Boot\BCD ->
        \Windows\System32\winload.exe. The boot files must live on the active
        partition, so this layout reserves one for them and gives the rest to
        Windows.

        MBR cannot address a partition beyond 2 TiB, so a disk at or above that
        boundary is refused instead of being partitioned into an extent the
        firmware cannot reach.

    .PARAMETER DiskSize
        Capacity of the target disk in bytes.

    .OUTPUTS
        Partitions[]  Name, Type, StartBytes, SizeBytes, SizeMB
        Valid, Errors, UnallocatedBytes, Style
    #>
    param(
        [Parameter(Mandatory = $true)][long]$DiskSize,
        [int]$BootSizeMB = 512,
        [long]$MinimumWindowsBytes = 25GB,
        [int]$AlignmentBytes = 1MB
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'

    if ($BootSizeMB -lt 260) { $errors.Add('the BIOS boot partition must be at least 260 MB') }
    if ($AlignmentBytes -lt 4096) { $errors.Add('alignment must be at least 4 KiB') }

    # 2 TiB, not 2 TB: the limit is 32 addressable bits of 512-byte sectors.
    $mbrLimitBytes = [long]2TB
    if ($DiskSize -ge $mbrLimitBytes) {
        $errors.Add(('a {0:N1} GB disk is at or beyond the 2 TiB limit of an MBR partition table, so BIOS firmware cannot address it' -f ($DiskSize / $script:GiB)))
    }

    $front = [long]$script:FrontReserveBytes
    $usable = [long]$DiskSize - $front
    $bootBytes = [long]$BootSizeMB * $script:MiB
    $windowsBytes = $usable - $bootBytes

    if ($windowsBytes -lt $MinimumWindowsBytes) {
        $errors.Add(('a {0:N1} GB disk leaves only {1:N1} GB for Windows after the boot partition, which is below the {2:N0} GB minimum' -f `
            ($DiskSize / $script:GiB), ($windowsBytes / $script:GiB), ($MinimumWindowsBytes / $script:GiB)))
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Valid            = $false
            Errors           = $errors.ToArray()
            Partitions       = @()
            DiskSize         = $DiskSize
            UnallocatedBytes = 0
            Style            = 'Mbr'
        }
    }

    $align = {
        param([long]$value, [int]$alignment)
        $remainder = $value % $alignment
        if ($remainder -eq 0) { return $value }
        return $value + ($alignment - $remainder)
    }

    $partitions = New-Object 'System.Collections.Generic.List[object]'
    $cursor = & $align $front $AlignmentBytes

    $partitions.Add([pscustomobject]@{ Name = 'Boot';    Type = 'boot';    StartBytes = $cursor; SizeBytes = $bootBytes;    SizeMB = $BootSizeMB })
    $cursor = & $align ($cursor + $bootBytes) $AlignmentBytes

    $partitions.Add([pscustomobject]@{ Name = 'Windows'; Type = 'primary'; StartBytes = $cursor; SizeBytes = $windowsBytes; SizeMB = [int][math]::Floor($windowsBytes / $script:MiB) })
    $cursor = & $align ($cursor + $windowsBytes) $AlignmentBytes

    # No backup table exists in MBR, so nothing is held back at the end.
    $unallocated = if ($cursor -lt $DiskSize) { [long]$DiskSize - $cursor } else { 0L }

    return [pscustomobject]@{
        Valid            = $true
        Errors           = @()
        Partitions       = $partitions.ToArray()
        DiskSize         = $DiskSize
        UnallocatedBytes = $unallocated
        WindowsBytes     = $windowsBytes
        Style            = 'Mbr'
    }
}

function Format-WtgLayout {
    <#
    .SYNOPSIS
        Renders a layout plan as a table for the confirmation screen.
    #>
    param($Plan = $null)

    if ($null -eq $Plan) { return '  (single-USB device: existing partitions are reused)' }
    if (-not $Plan.Valid) { return ($Plan.Errors -join [Environment]::NewLine) }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($partition in $Plan.Partitions) {
        $lines.Add(('  {0,-9} {1,10:N1} GB   starts at {2,10:N0} MiB' -f `
            $partition.Name, ($partition.SizeBytes / 1GB), ($partition.StartBytes / 1MB)))
    }
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'New-WtgLayoutPlan',
    'New-WtgLegacyLayoutPlan',
    'Test-WtgSingleUsbTarget',
    'Format-WtgLayout'
)
