# WinToGo.Layout.psm1
#
# Partition layout arithmetic for the installation target.
#
# UEFI-only, GPT, three partitions: ESP, MSR, Windows. No MBR path is offered:
# an MBR install cannot be booted by firmware in UEFI mode, and Windows To Go
# media is UEFI in this project.
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
        Computes the GPT partition layout for a target disk.

    .PARAMETER DiskSize
        Capacity of the target disk in bytes.

    .PARAMETER WithRecovery
        Adds a WinRE partition at the end. It is empty until the installed copy of
        Windows enables recovery; see docs/ARCHITECTURE.md.

    .OUTPUTS
        Partitions[]  Name, Type, StartBytes, SizeBytes, SizeMB
        Valid, Errors, TotalBytes, UnallocatedBytes
    #>
    param(
        [Parameter(Mandatory = $true)][long]$DiskSize,
        [int]$EspSizeMB = 512,
        [int]$MsrSizeMB = 16,
        [int]$RecoverySizeMB = 1024,
        [switch]$WithRecovery,
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
    $recoveryBytes = 0L
    if ($WithRecovery) { $recoveryBytes = [long]$RecoverySizeMB * $script:MiB }

    $windowsBytes = $usable - $espBytes - $msrBytes - $recoveryBytes

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

    if ($WithRecovery) {
        $partitions.Add([pscustomobject]@{ Name = 'Recovery'; Type = 'recovery'; StartBytes = $cursor; SizeBytes = $recoveryBytes; SizeMB = $RecoverySizeMB })
        $cursor = $cursor + $recoveryBytes
    }

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

function Format-WtgLayout {
    <#
    .SYNOPSIS
        Renders a layout plan as a table for the confirmation screen.
    #>
    param([Parameter(Mandatory = $true)]$Plan)

    if (-not $Plan.Valid) { return ($Plan.Errors -join [Environment]::NewLine) }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($partition in $Plan.Partitions) {
        $lines.Add(('  {0,-9} {1,10:N1} GB   starts at {2,10:N0} MiB' -f `
            $partition.Name, ($partition.SizeBytes / 1GB), ($partition.StartBytes / 1MB)))
    }
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function @('New-WtgLayoutPlan', 'Format-WtgLayout')
