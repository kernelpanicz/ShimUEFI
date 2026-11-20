# WinToGo.Storage.psm1
#
# Disk enumeration and classification.
#
# Everything in this module is a *pure function* over plain disk records so it can
# be unit tested without touching real hardware. WinToGo.Guard.psm1 uses it to
# decide what may be written to; nothing here performs a write.
#
# A "disk record" is any object exposing these properties (Get-WtgDisk produces
# them from Get-Disk, tests build them by hand):
#
#   Number         int      Windows disk number
#   FriendlyName   string
#   SerialNumber   string
#   BusType        int|string  (0-19 per STORAGE_BUS_TYPE, or the name)
#   Size           long     bytes
#   IsBoot         bool
#   IsSystem       bool
#   IsReadOnly     bool
#   IsOffline      bool
#   PartitionStyle string
#
# Copyright (C) 2025 ading2210 (original Shimboot project)
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

Set-StrictMode -Version 2.0

# STORAGE_BUS_TYPE, as reported by Windows. eMMC presents as MMC (13) while
# SD cards present as SD (12); this is the single most important distinction in
# the whole project, because a misread would let the installer touch eMMC.
$script:BusTypeNames = @{
    0  = 'Unknown'
    1  = 'SCSI'
    2  = 'ATAPI'
    3  = 'ATA'
    4  = 'IEEE1394'
    5  = 'SSA'
    6  = 'Fibre'
    7  = 'USB'
    8  = 'RAID'
    9  = 'iSCSI'
    10 = 'SAS'
    11 = 'SATA'
    12 = 'SD'
    13 = 'MMC'
    14 = 'Virtual'
    15 = 'FileBackedVirtual'
    16 = 'Spaces'
    17 = 'NVMe'
    18 = 'SCM'
    19 = 'UFS'
}

# Buses that are, by construction, behind a removable connector.
$script:ExternalBusTypes = @('USB', 'SD')

# Everything else is treated as internal/untrusted. Anything absent from both
# lists is treated as UNKNOWN and blocked; the default is deny.
$script:InternalBusTypes = @(
    'SATA', 'ATA', 'ATAPI', 'NVMe', 'MMC', 'UFS', 'SCSI', 'SAS', 'RAID', 'iSCSI',
    'IEEE1394', 'SSA', 'Fibre', 'Spaces', 'SCM', 'Virtual', 'FileBackedVirtual'
)

# Buses where an *external* enclosure is technically possible (USB4/Thunderbolt
# NVMe, eSATA and SATA docks). These can never be auto-allowed, but an operator
# may explicitly override them after confirming the serial number.
$script:OverridableBusTypes = @('NVMe', 'SATA', 'SCSI', 'SAS')

function Get-WtgProp {
    <#
    .SYNOPSIS
        Null-safe property read, so a missing property is a default instead of an
        exception. Deliberately used for every value that comes from the OS.
    #>
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-WtgBusTypeName {
    <#
    .SYNOPSIS
        Normalises a BusType value (numeric enum, numeric string, or name) to a
        canonical name.
    #>
    param($BusType)

    if ($null -eq $BusType) { return 'Unknown' }

    $text = [string]$BusType
    if ($text -match '^\s*\d+\s*$') {
        $number = [int]$text.Trim()
        if ($script:BusTypeNames.ContainsKey($number)) { return $script:BusTypeNames[$number] }
        return ('Unknown(' + $number + ')')
    }

    foreach ($name in $script:BusTypeNames.Values) {
        if ($name -eq $text.Trim()) { return $name }
    }
    return $text.Trim()
}

function New-WtgStoragePolicy {
    <#
    .SYNOPSIS
        The storage policy. These are the only tunables in the protection system.
    #>
    param(
        [long]$MinimumTargetBytes = 32GB,
        [long]$RecommendedTargetBytes = 64GB,
        [switch]$AllowSdCards,
        [switch]$AllowInternalBusOverride
    )

    [pscustomobject]@{
        MinimumTargetBytes      = $MinimumTargetBytes
        RecommendedTargetBytes  = $RecommendedTargetBytes
        AllowSdCards            = [bool]$AllowSdCards
        AllowInternalBusOverride = [bool]$AllowInternalBusOverride
        RequireSerialNumber     = $true
        MaximumTargets          = 1
        ExternalBusTypes        = $script:ExternalBusTypes
        InternalBusTypes        = $script:InternalBusTypes
        OverridableBusTypes     = $script:OverridableBusTypes
    }
}

function Get-WtgDisk {
    <#
    .SYNOPSIS
        Enumerates physical disks and returns canonical disk records.

    .DESCRIPTION
        Read-only. Uses Get-Disk, which is present in WinPE and on Windows 8+.
        Volumes and partitions are deliberately not enumerated: the installer has
        no business looking at other people's partitions.
    #>
    param()

    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        throw 'WTG-STORAGE: Get-Disk is unavailable. The Storage module is required (Windows 8+ / WinPE with the Storage provider).'
    }

    $disks = @(Get-Disk | Sort-Object Number)
    foreach ($disk in $disks) {
        [pscustomobject]@{
            Number         = [int]$disk.Number
            FriendlyName   = [string]$disk.FriendlyName
            SerialNumber   = ([string]$disk.SerialNumber).Trim()
            BusType        = (ConvertTo-WtgBusTypeName $disk.BusType)
            Size           = [long]$disk.Size
            IsBoot         = [bool]$disk.IsBoot
            IsSystem       = [bool]$disk.IsSystem
            IsReadOnly     = [bool]$disk.IsReadOnly
            IsOffline      = [bool]$disk.IsOffline
            PartitionStyle = [string]$disk.PartitionStyle
            Path           = [string]$disk.Path
            Location       = [string]$disk.Location
        }
    }
}

function Get-WtgDiskClassify {
    <#
    .SYNOPSIS
        Classifies one disk as External, Internal or Unknown.

    .OUTPUTS
        Class       External | Internal | Unknown
        Confidence  High | Medium | None
        Reasons     string[]   human readable justification, always populated
        External    bool       true only for Class = External

    .NOTES
        Rule order matters and is intentional:
          1. The disk hosting the running OS, or the firmware boot disk, is always
             internal regardless of what the bus says.
          2. A bus known to be external (USB, SD) is external.
          3. A bus known to be internal (SATA, NVMe, MMC/eMMC, UFS, ...) is internal.
          4. Anything else is Unknown.
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Policy
    )

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $number  = Get-WtgProp $Disk 'Number' -1
    $busType = ConvertTo-WtgBusTypeName (Get-WtgProp $Disk 'BusType')
    $isSystem = [bool](Get-WtgProp $Disk 'IsSystem' $false)
    $isBoot   = [bool](Get-WtgProp $Disk 'IsBoot' $false)
    $serial   = [string](Get-WtgProp $Disk 'SerialNumber' '')
    $size     = [long](Get-WtgProp $Disk 'Size' 0)

    if ($isSystem) { $reasons.Add('disk-hosts-the-running-operating-system') }
    if ($isBoot)   { $reasons.Add('disk-is-the-firmware-boot-disk') }

    if ($isSystem -or $isBoot) {
        return [pscustomobject]@{
            DiskNumber = $number
            BusType    = $busType
            Class      = 'Internal'
            Confidence = 'High'
            Reasons    = $reasons.ToArray()
            External   = $false
        }
    }

    if ($script:ExternalBusTypes -contains $busType) {
        if ($busType -eq 'SD') {
            # SD is normally a real card slot, but a handful of eMMC/SDIO bridges
            # in cheap tablets report themselves as SD. Never auto-allow it.
            $reasons.Add('sd-bus-can-be-reported-by-emmc-bridges-too')
            $confidence = 'Medium'
        }
        else {
            $reasons.Add('removable-connector-bus:' + $busType)
            $confidence = 'High'
        }

        if (-not $serial) { $reasons.Add('no-serial-number-reported') }
        if ($size -le 0)   { $reasons.Add('reports-zero-capacity') }

        return [pscustomobject]@{
            DiskNumber = $number
            BusType    = $busType
            Class      = 'External'
            Confidence = $confidence
            Reasons    = $reasons.ToArray()
            External   = $true
        }
    }

    if ($script:InternalBusTypes -contains $busType) {
        $reasons.Add('internal-or-untrusted-bus:' + $busType)
        return [pscustomobject]@{
            DiskNumber = $number
            BusType    = $busType
            Class      = 'Internal'
            Confidence = 'High'
            Reasons    = $reasons.ToArray()
            External   = $false
        }
    }

    $reasons.Add('unrecognised-bus-type:' + $busType)
    return [pscustomobject]@{
        DiskNumber = $number
        BusType    = $busType
        Class      = 'Unknown'
        Confidence = 'None'
        Reasons    = $reasons.ToArray()
        External   = $false
    }
}

function Test-WtgSerialMatch {
    <#
    .SYNOPSIS
        Compares two serial numbers the way a human would: case-insensitive,
        ignoring spaces, dashes and underscores.
    #>
    param(
        [string]$Actual,
        [string]$Expected
    )

    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $false }

    $normalise = {
        param([string]$value)
        return ($value -replace '[\s\-_]', '').ToUpperInvariant()
    }

    return ((& $normalise $Actual) -eq (& $normalise $Expected))
}

function Test-WtgTargetEligible {
    <#
    .SYNOPSIS
        Full eligibility check for an installation target. Fail-closed: any doubt
        produces an error and Eligible = $false.

    .OUTPUTS
        Eligible        bool
        Errors          string[]  every reason it was refused
        Warnings        string[]  accepted but worth printing
        Classification  from Get-WtgDiskClassify
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Policy,
        [switch]$AllowSdCard,
        [switch]$AllowInternalBusOverride
    )

    $errors   = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    $classification = Get-WtgDiskClassify -Disk $Disk -Policy $Policy
    $busType = $classification.BusType
    $serial  = [string](Get-WtgProp $Disk 'SerialNumber' '')
    $size    = [long](Get-WtgProp $Disk 'Size' 0)

    switch ($classification.Class) {
        'External' {
            if ($classification.Confidence -eq 'Medium') {
                if ($busType -eq 'SD' -and -not $AllowSdCard) {
                    $errors.Add("bus type SD cannot be distinguished reliably from internal eMMC; pass -AllowSdCard to confirm an SD card is intended")
                }
                else {
                    $warnings.Add("bus type $busType is accepted only because it was explicitly confirmed")
                }
            }
        }
        'Internal' {
            if ($busType -in $script:OverridableBusTypes) {
                if ($AllowInternalBusOverride) {
                    $warnings.Add("internal bus $busType accepted through an explicit operator override; only correct for a known USB/Thunderbolt enclosure")
                }
                else {
                    $errors.Add("bus type $busType is an internal bus by default; an external enclosure on this bus requires the explicit override")
                }
            }
            else {
                $errors.Add("bus type $busType is internal storage and can never be a target")
            }
        }
        default {
            $errors.Add("disk bus type could not be classified ($busType); refusing to guess")
        }
    }

    if ([bool](Get-WtgProp $Disk 'IsBoot' $false))   { $errors.Add('disk is the firmware boot disk') }
    if ([bool](Get-WtgProp $Disk 'IsSystem' $false)) { $errors.Add('disk hosts the running operating system') }

    if ($Policy.RequireSerialNumber -and -not $serial) {
        $errors.Add('disk reports no serial number, so its identity cannot be confirmed')
    }

    if ($size -lt [long]$Policy.MinimumTargetBytes) {
        $errors.Add(("capacity {0:N1} GB is below the {1:N0} GB minimum for a Windows installation" -f ($size / 1GB), ($Policy.MinimumTargetBytes / 1GB)))
    }

    if ([bool](Get-WtgProp $Disk 'IsReadOnly' $false)) { $errors.Add('disk is currently read-only') }
    if ([bool](Get-WtgProp $Disk 'IsOffline' $false))  { $errors.Add('disk is currently offline') }

    return [pscustomobject]@{
        Eligible       = ($errors.Count -eq 0)
        Errors         = $errors.ToArray()
        Warnings       = $warnings.ToArray()
        Classification = $classification
    }
}

function Get-WtgFirmwareMode {
    <#
    .SYNOPSIS
        Reports the firmware the installer is running on: Uefi, Bios or Unknown.

    .DESCRIPTION
        Read-only, and deliberately fail-closed: an unknown firmware is not
        treated as either. The partition style that can boot this machine depends
        on the answer, so a guess would produce a disk that does not start.

        Win32_ComputerSystem.FirmwareType is the documented source (1 = BIOS,
        2 = UEFI). WinPE also exports firmware_type in the environment, which is
        used as a fallback for builds where the CIM property is absent.
    #>
    param()

    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $property = $system.PSObject.Properties['FirmwareType']
        if ($null -ne $property -and $null -ne $property.Value) {
            switch ([int]$property.Value) {
                1 { return 'Bios' }
                2 { return 'Uefi' }
            }
        }
    }
    catch { }

    switch ([string]$env:firmware_type) {
        'BIOS' { return 'Bios' }
        'UEFI' { return 'Uefi' }
    }

    return 'Unknown'
}

function Get-WtgHardwareReport {
    <#
    .SYNOPSIS
        Hardware summary for the installer's information panel. Read-only.
    #>
    param()

    $report = [ordered]@{
        ComputerModel = 'unknown'
        Manufacturer  = 'unknown'
        Firmware      = 'unknown'
        SecureBoot    = 'unknown'
        Processor     = 'unknown'
        LogicalCpus   = 0
        MemoryGB      = 0
        Architecture  = $env:PROCESSOR_ARCHITECTURE
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $report.Manufacturer  = [string]$cs.Manufacturer
        $report.ComputerModel = [string]($cs.Manufacturer + ' ' + $cs.Model).Trim()
        $report.MemoryGB      = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
    }
    catch { }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $report.Processor   = ([string]$cpu.Name).Trim()
        $report.LogicalCpus = [int]$cpu.NumberOfLogicalProcessors
    }
    catch { }

    try {
        $report.Firmware = (Get-WtgFirmwareMode)
        if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
            $report.SecureBoot = [string](Confirm-SecureBootUEFI)
        }
    }
    catch { $report.SecureBoot = 'unavailable' }

    return [pscustomobject]$report
}

function Format-WtgDiskSummary {
    <#
    .SYNOPSIS
        One-line human readable identification of a disk, used everywhere a disk is
        shown or confirmed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        $Classification
    )

    $busType = ConvertTo-WtgBusTypeName (Get-WtgProp $Disk 'BusType')
    $sizeGb  = [math]::Round(([long](Get-WtgProp $Disk 'Size' 0)) / 1GB, 1)
    $serial  = [string](Get-WtgProp $Disk 'SerialNumber' '')
    if (-not $serial) { $serial = '<none>' }

    $classText = ''
    if ($null -ne $Classification) {
        $classText = (' [{0}/{1}]' -f $Classification.Class, $Classification.Confidence)
    }

    return ('disk {0}: {1} | {2} GB | {3} | serial {4}{5}' -f `
        (Get-WtgProp $Disk 'Number' '?'), `
        (Get-WtgProp $Disk 'FriendlyName' 'unknown device'), `
        $sizeGb, $busType, $serial, $classText)
}

Export-ModuleMember -Function @(
    'Get-WtgProp',
    'ConvertTo-WtgBusTypeName',
    'New-WtgStoragePolicy',
    'Get-WtgDisk',
    'Get-WtgDiskClassify',
    'Test-WtgSerialMatch',
    'Test-WtgTargetEligible',
    'Get-WtgFirmwareMode',
    'Get-WtgHardwareReport',
    'Format-WtgDiskSummary'
)
