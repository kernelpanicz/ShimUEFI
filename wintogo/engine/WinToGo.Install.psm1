# WinToGo.Install.psm1
#
# The installation pipeline.
#
# This is a thin, auditable orchestration of Microsoft's own tools:
#   diskpart  partition the target
#   dism      apply the Windows image, add optional drivers
#   bcdboot   write Windows Boot Manager and BCD to the target's own ESP
#   reg       set the offline portable-OS flags
#
# Nothing here implements Windows installation logic itself. That is deliberate:
# BCD and the Windows image format are Microsoft-defined, and a reimplementation
# would be both unsafe and unverifiable.
#
# Every destructive function takes -Authorization and calls Assert-WtgDiskWritable
# against the live disk before it runs anything.
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

Set-StrictMode -Version 2.0

# Dependency: WinToGo.Storage.psm1, WinToGo.Guard.psm1 and WinToGo.Layout.psm1 must
# be imported by the entry point first. See the note in WinToGo.Guard.psm1 for why
# these modules do not import each other.

# Boot-critical storage and USB services that must be boot-start for Windows to
# come up from removable media. All of these are inbox drivers on Windows 10/11
# x64, so setting Start=0 patches an existing key rather than creating one.
$script:PortableBootServices = @(
    'USBXHCI',    # xHCI host controller
    'USBHUB3',    # USB 3 hub
    'USBSTOR',    # USB mass storage class driver
    'UASPStor',   # USB attached SCSI
    'EhStorClass',# storage class filter
    'stornvme',   # NVMe
    'storahci',   # AHCI / SATA
    'sdstor'      # SD host controller
)

# ---------------------------------------------------------------------------
# Command execution (injectable so the whole pipeline can be audited in tests)
# ---------------------------------------------------------------------------

$script:Executor = {
    param([string]$FilePath, [string[]]$Arguments)

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output   = (($output | Out-String).Trim())
    }
}

function Set-WtgCommandExecutor {
    <#
    .SYNOPSIS
        Replaces the command executor. Tests use this to record what would run.
    #>
    param([Parameter(Mandatory = $true)][scriptblock]$Executor)
    $script:Executor = $Executor
}

function Get-WtgCommandExecutor {
    param()
    return $script:Executor
}

function Invoke-WtgExternal {
    <#
    .SYNOPSIS
        Runs an external command through the current executor.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [string]$JournalPath,
        [string]$Description
    )

    if ($JournalPath) {
        Add-WtgJournal -Path $JournalPath -Event 'exec' -Message ($Description + ' ' + $FilePath) -Data @{
            file = $FilePath
            args = $Arguments
        }
    }

    $result = & $script:Executor $FilePath $Arguments

    if ($null -eq $result) {
        $result = [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        $text = [string]$result.Output
        if ($text.Length -gt 1200) { $text = $text.Substring(0, 1200) }
        throw ('WTG-INSTALL: {0} exited with code {1}: {2}' -f (Split-Path -Leaf $FilePath), $result.ExitCode, $text)
    }

    return $result
}

# ---------------------------------------------------------------------------
# Diskpart
# ---------------------------------------------------------------------------

function New-WtgDiskpartScript {
    <#
    .SYNOPSIS
        Generates the diskpart script that wipes and partitions exactly one disk.

    .DESCRIPTION
        Pure function. The first line always selects the authorized disk number, and
        the script never contains a second select, so there is no way for it to
        address another disk part way through.
    #>
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][int]$DiskNumber
    )

    if (-not $Layout.Valid) {
        throw ('WTG-INSTALL: refusing to generate a diskpart script from an invalid layout: ' + ($Layout.Errors -join '; '))
    }

    $efi  = $Layout.Partitions | Where-Object { $_.Name -eq 'EFI' } | Select-Object -First 1
    $msr  = $Layout.Partitions | Where-Object { $_.Name -eq 'MSR' } | Select-Object -First 1
    $win  = $Layout.Partitions | Where-Object { $_.Name -eq 'Windows' } | Select-Object -First 1
    if ($null -eq $efi -or $null -eq $msr -or $null -eq $win) {
        throw 'WTG-INSTALL: layout is missing EFI, MSR or Windows partition'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('rem ShimUEFI portable Windows - generated partition script')
    $lines.Add('rem This script addresses one disk only.')
    $lines.Add(('select disk {0}' -f $DiskNumber))
    $lines.Add('clean')
    $lines.Add('convert gpt')
    $lines.Add(('create partition efi size={0}' -f $efi.SizeMB))
    $lines.Add('format quick fs=fat32 label="SYSTEM"')
    $lines.Add(('create partition msr size={0}' -f $msr.SizeMB))
    $lines.Add('create partition primary')
    $lines.Add('format quick fs=ntfs label="WINDOWS"')
    $lines.Add('exit')

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-WtgSingleUsbDiskpartScript {
    <#
    .SYNOPSIS
        Generates the diskpart script used when the installer medium is also the
        installation target.

    .DESCRIPTION
        Pure function. The device already carries ESP + MSR + an empty Windows
        partition from the build, so nothing is cleaned and no partition is
        created: the installer payload lives on the ESP of this very disk, and
        wiping the table would destroy it mid-install. Only the Windows partition
        is formatted.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [int]$WindowsPartitionNumber = 3
    )

    if ($WindowsPartitionNumber -lt 1) {
        throw 'WTG-INSTALL: single-USB mode needs a valid Windows partition number'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('rem ShimUEFI portable Windows - single-USB install')
    $lines.Add('rem The partition table and the installer payload are preserved.')
    $lines.Add(('select disk {0}' -f $DiskNumber))
    $lines.Add(('select partition {0}' -f $WindowsPartitionNumber))
    $lines.Add('format quick fs=ntfs label="WINDOWS"')
    $lines.Add('exit')

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-WtgLegacyDiskpartScript {
    <#
    .SYNOPSIS
        Generates the diskpart script that wipes and partitions exactly one disk
        for BIOS firmware.

    .DESCRIPTION
        Pure function. MBR rather than GPT, because the firmware being booted is
        BIOS: \bootmgr is loaded from the active partition and winload.exe from
        the Windows partition. The boot partition is marked active so the master
        boot record can find it; the boot code itself is written afterwards by
        bootsect.

        As with the GPT script, the first line selects the authorized disk number
        and no second select ever appears.
    #>
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][int]$DiskNumber
    )

    if (-not $Layout.Valid) {
        throw ('WTG-INSTALL: refusing to generate a diskpart script from an invalid layout: ' + ($Layout.Errors -join '; '))
    }

    $boot = $Layout.Partitions | Where-Object { $_.Name -eq 'Boot' } | Select-Object -First 1
    $win  = $Layout.Partitions | Where-Object { $_.Name -eq 'Windows' } | Select-Object -First 1
    if ($null -eq $boot -or $null -eq $win) {
        throw 'WTG-INSTALL: layout is missing the boot or Windows partition'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('rem ShimUEFI portable Windows - generated BIOS partition script')
    $lines.Add('rem This script addresses one disk only.')
    $lines.Add(('select disk {0}' -f $DiskNumber))
    $lines.Add('clean')
    $lines.Add('convert mbr')
    $lines.Add(('create partition primary size={0}' -f $boot.SizeMB))
    $lines.Add('format quick fs=fat32 label="SYSTEM"')
    $lines.Add('active')
    $lines.Add('create partition primary')
    $lines.Add('format quick fs=ntfs label="WINDOWS"')
    $lines.Add('exit')

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

# GPT partition types that matter when a single-USB medium formats its own
# Windows partition. Anything that is not Microsoft basic data is refused.
$script:GptTypeBasicData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$script:GptTypeEsp       = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:GptTypeMsr       = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$script:GptTypeRecovery  = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

function Get-WtgGptTypeLabel {
    <#
    .SYNOPSIS
        Names a GPT partition type so a refusal says what it refused.
    #>
    param([string]$GptType)

    switch ($GptType) {
        $script:GptTypeEsp      { return 'the EFI system partition' }
        $script:GptTypeMsr      { return 'the Microsoft reserved partition' }
        $script:GptTypeRecovery { return 'a recovery partition' }
        $script:GptTypeBasicData { return 'a Windows data partition' }
        default                 { return ('partition type ' + $GptType) }
    }
}

function Assert-WtgSingleUsbWindowsPartition {
    <#
    .SYNOPSIS
        Proves that the partition about to be formatted is the Windows partition.

    .DESCRIPTION
        In single-USB mode the medium's own GPT is preserved: partition 1 is the
        ESP that holds the installation image this code is running from, and only
        the Windows partition is formatted. A partition number is not evidence of
        what a partition is, so before any write the table is read back and the
        partition is required to be Microsoft basic data, to exist, to report a
        plausible size, and to sit on a disk that still carries an ESP.

        Read-only. Throws WTG-INSTALL with a specific message on any mismatch.

    .PARAMETER Partitions
        Partition records from Get-Partition for the authorized disk.

    .OUTPUTS
        The verified partition record.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Partitions,
        [Parameter(Mandatory = $true)][int]$WindowsPartitionNumber,
        [long]$MinimumBytes = 25GB
    )

    if ($WindowsPartitionNumber -lt 1) {
        throw 'WTG-INSTALL: single-USB mode needs a valid Windows partition number'
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($partition in @($Partitions)) {
        $numberProperty = $partition.PSObject.Properties['PartitionNumber']
        if ($null -eq $numberProperty -or $null -eq $numberProperty.Value) {
            throw 'WTG-INSTALL: a partition on the target device reports no partition number; refusing to format anything'
        }

        $typeProperty = $partition.PSObject.Properties['GptType']
        $gptType = ''
        if ($null -ne $typeProperty -and $null -ne $typeProperty.Value) {
            $gptType = ([string]$typeProperty.Value).Trim().ToLowerInvariant()
        }

        $sizeProperty = $partition.PSObject.Properties['Size']
        $size = 0L
        if ($null -ne $sizeProperty -and $null -ne $sizeProperty.Value) { $size = [long]$sizeProperty.Value }

        $records.Add([pscustomobject]@{
            Number      = [int]$numberProperty.Value
            GptType     = $gptType
            Size        = $size
            Partition   = $partition
        })
    }

    if ($records.Count -eq 0) {
        throw 'WTG-INSTALL: the target device reports no partitions, so its Windows partition cannot be identified; refusing to format anything'
    }

    $target = $records | Where-Object { $_.Number -eq $WindowsPartitionNumber } | Select-Object -First 1
    if ($null -eq $target) {
        throw ('WTG-INSTALL: partition {0} does not exist on this device; refusing to format anything' -f $WindowsPartitionNumber)
    }

    if (-not $target.GptType) {
        throw ('WTG-INSTALL: partition {0} does not report a GPT partition type, so it cannot be shown to be the Windows partition; refusing to format it' -f $WindowsPartitionNumber)
    }
    if ($target.GptType -ne $script:GptTypeBasicData) {
        throw ('WTG-INSTALL: partition {0} is {1}, not a Windows data partition; refusing to format it' -f `
            $WindowsPartitionNumber, (Get-WtgGptTypeLabel -GptType $target.GptType))
    }

    $esp = $records | Where-Object { $_.GptType -eq $script:GptTypeEsp } | Select-Object -First 1
    if ($null -eq $esp) {
        throw 'WTG-INSTALL: this device carries no EFI system partition, so it is not the single-USB medium it was booted as; refusing to format anything'
    }

    if ($target.Size -le 0) {
        throw ('WTG-INSTALL: partition {0} reports no size; refusing to format it' -f $WindowsPartitionNumber)
    }
    if ($target.Size -lt $MinimumBytes) {
        throw ('WTG-INSTALL: partition {0} is only {1:N1} GB, below the {2:N0} GB minimum for Windows; refusing to format it' -f `
            $WindowsPartitionNumber, ($target.Size / 1GB), ($MinimumBytes / 1GB))
    }

    return $target.Partition
}

function Invoke-WtgPartition {
    <#
    .SYNOPSIS
        Partitions the authorized disk: either a fresh whole disk, or the Windows
        partition of a single-USB medium.
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Authorization,
        [Parameter(Mandatory = $true)]$Policy,
        $Layout = $null,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [ValidateSet('Fresh', 'SingleUsb', 'Legacy')][string]$Mode = 'Fresh',
        [int]$WindowsPartitionNumber = 3,
        # Seam for tests: reads the target's partition table before anything is
        # formatted. Defaults to Get-Partition on the authorized disk.
        [scriptblock]$PartitionProvider = $null,
        [string]$JournalPath
    )

    Assert-WtgDiskWritable -Authorization $Authorization -Disk $Disk -Policy $Policy | Out-Null

    if ($Mode -eq 'SingleUsb') {
        if ($Disk.PartitionStyle -ne 'GPT') {
            throw ('WTG-INSTALL: single-USB mode needs a GPT device, but disk {0} reports {1}' -f $Disk.Number, $Disk.PartitionStyle)
        }

        # The partition that is about to be formatted is verified against the live
        # table first: formatting the ESP here would destroy the installation image
        # that is running this code.
        $provider = $PartitionProvider
        if ($null -eq $provider) {
            $provider = { param($diskNumber) @(Get-Partition -DiskNumber $diskNumber -ErrorAction Stop) }
        }

        $partitions = $null
        try {
            $partitions = @(& $provider $Authorization.DiskNumber)
        }
        catch {
            throw ('WTG-INSTALL: could not read the partition table of disk {0} before formatting it: {1}' -f $Authorization.DiskNumber, $_.Exception.Message)
        }

        $verified = Assert-WtgSingleUsbWindowsPartition -Partitions $partitions -WindowsPartitionNumber $WindowsPartitionNumber

        if ($JournalPath) {
            Add-WtgJournal -Path $JournalPath -Event 'single-usb-partition-verified' `
                -Message ('partition {0} on disk {1} is a Windows data partition' -f $WindowsPartitionNumber, $Authorization.DiskNumber) `
                -Data @{ disk = $Authorization.DiskNumber; partition = $WindowsPartitionNumber; sizeBytes = [long]$verified.Size }
        }
    }

    if (-not (Test-Path -LiteralPath $WorkDirectory)) {
        New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
    }

    $scriptPath = Join-Path $WorkDirectory 'partition.txt'
    switch ($Mode) {
        'SingleUsb' {
            $scriptText = New-WtgSingleUsbDiskpartScript -DiskNumber $Authorization.DiskNumber -WindowsPartitionNumber $WindowsPartitionNumber
        }
        'Legacy' {
            $scriptText = New-WtgLegacyDiskpartScript -Layout $Layout -DiskNumber $Authorization.DiskNumber
        }
        default {
            $scriptText = New-WtgDiskpartScript -Layout $Layout -DiskNumber $Authorization.DiskNumber
        }
    }
    Set-Content -LiteralPath $scriptPath -Value $scriptText -Encoding ASCII

    Invoke-WtgExternal -FilePath 'diskpart.exe' -Arguments @('/s', $scriptPath) -JournalPath $JournalPath -Description 'partition target disk' | Out-Null

    return $scriptText
}

# ---------------------------------------------------------------------------
# Volume discovery
# ---------------------------------------------------------------------------

function Get-WtgTargetVolumes {
    <#
    .SYNOPSIS
        Finds the ESP and Windows volumes that belong to the authorized disk.

    .DESCRIPTION
        Matched by disk number and partition type, never by drive letter, so a
        leftover letter on another disk cannot be mistaken for the target.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber
    )

    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)

    $esp = $partitions | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    $windows = $partitions | Where-Object {
        $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    } | Sort-Object Size -Descending | Select-Object -First 1

    if ($null -eq $esp)     { throw ('WTG-INSTALL: no EFI system partition found on disk {0}' -f $DiskNumber) }
    if ($null -eq $windows) { throw ('WTG-INSTALL: no Windows data partition found on disk {0}' -f $DiskNumber) }

    $espLetter = [string]$esp.DriveLetter
    if (-not $espLetter) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -NewDriveLetter 'S' -ErrorAction Stop
        $espLetter = 'S'
    }

    $winLetter = [string]$windows.DriveLetter
    if (-not $winLetter) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $windows.PartitionNumber -NewDriveLetter 'W' -ErrorAction Stop
        $winLetter = 'W'
    }

    return [pscustomobject]@{
        EspPartitionNumber = $esp.PartitionNumber
        EspDriveLetter     = $espLetter
        WindowsPartitionNumber = $windows.PartitionNumber
        WindowsDriveLetter = $winLetter
        WindowsSizeBytes   = [long]$windows.Size
    }
}

function Get-WtgLegacyVolumes {
    <#
    .SYNOPSIS
        Finds the active boot partition and the Windows partition of an
        MBR-partitioned target.

    .DESCRIPTION
        MBR has no partition type GUID to match, so the boot partition is
        identified by the active flag (or a FAT filesystem) and Windows by being
        the largest NTFS partition on the same disk. Both are matched by disk
        number, never by drive letter, so a leftover letter on another disk cannot
        be mistaken for the target.

    .OUTPUTS
        The same shape as Get-WtgTargetVolumes; BootDriveLetter duplicates
        EspDriveLetter so the rest of the pipeline does not branch on firmware.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber
    )

    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)

    $boot = $partitions | Where-Object {
        $isActive = [bool](Get-WtgProp $_ 'IsActive' $false)
        $isActive -or ([string](Get-WtgProp $_ 'Type' '') -match 'FAT')
    } | Select-Object -First 1

    $windows = $partitions | Where-Object {
        [string](Get-WtgProp $_ 'Type' '') -match 'NTFS|IFS'
    } | Sort-Object Size -Descending | Select-Object -First 1

    if ($null -eq $boot)    { throw ('WTG-INSTALL: no active FAT boot partition found on disk {0}' -f $DiskNumber) }
    if ($null -eq $windows) { throw ('WTG-INSTALL: no NTFS Windows partition found on disk {0}' -f $DiskNumber) }
    if ($boot.PartitionNumber -eq $windows.PartitionNumber) {
        throw ('WTG-INSTALL: the boot partition and the Windows partition are the same partition on disk {0}; refusing' -f $DiskNumber)
    }

    $bootLetter = [string]$boot.DriveLetter
    if (-not $bootLetter) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $boot.PartitionNumber -NewDriveLetter 'S' -ErrorAction Stop
        $bootLetter = 'S'
    }

    $winLetter = [string]$windows.DriveLetter
    if (-not $winLetter) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $windows.PartitionNumber -NewDriveLetter 'W' -ErrorAction Stop
        $winLetter = 'W'
    }

    return [pscustomobject]@{
        BootPartitionNumber    = $boot.PartitionNumber
        BootDriveLetter        = $bootLetter
        EspPartitionNumber     = $boot.PartitionNumber
        EspDriveLetter         = $bootLetter
        WindowsPartitionNumber = $windows.PartitionNumber
        WindowsDriveLetter     = $winLetter
        WindowsSizeBytes       = [long]$windows.Size
    }
}

# ---------------------------------------------------------------------------
# Image handling
# ---------------------------------------------------------------------------

function ConvertFrom-WtgWimInfo {
    <#
    .SYNOPSIS
        Parses `dism /Get-WimInfo` output into edition objects.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $editions = New-Object 'System.Collections.Generic.List[object]'
    $current = $null

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(?:Index|Index Number)\s*:\s*(\d+)\s*$') {
            if ($null -ne $current) { $editions.Add($current) }
            $current = [ordered]@{ Index = [int]$Matches[1]; Name = ''; Description = ''; SizeBytes = 0 }
            continue
        }
        if ($null -eq $current) { continue }

        if ($line -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $current.Name = $Matches[1]
        }
        elseif ($line -match '^\s*Description\s*:\s*(.+?)\s*$') {
            $current.Description = $Matches[1]
        }
        elseif ($line -match '^\s*Size\s*:\s*([\d,]+)\s*bytes\s*$') {
            $current.SizeBytes = [long]($Matches[1] -replace ',', '')
        }
    }
    if ($null -ne $current) { $editions.Add($current) }

    return $editions.ToArray() | ForEach-Object { [pscustomobject]$_ }
}

function Get-WtgImageEditions {
    <#
    .SYNOPSIS
        Lists the editions available in a WIM/ESD/SWM image.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [string]$JournalPath
    )

    $result = Invoke-WtgExternal -FilePath 'dism.exe' -Arguments @('/English', '/Get-WimInfo', ('/WimFile:' + $ImagePath)) -JournalPath $JournalPath -Description 'query image editions'
    return (ConvertFrom-WtgWimInfo -Text $result.Output)
}

function Invoke-WtgApplyImage {
    <#
    .SYNOPSIS
        Applies one image index to the target Windows partition.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$ApplyDirectory,
        [string]$SwmPath,
        [string]$JournalPath
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add('/English')
    $arguments.Add('/Apply-Image')
    $arguments.Add('/ImageFile:' + $ImagePath)
    $arguments.Add('/Index:' + $Index)
    $arguments.Add('/ApplyDir:' + $ApplyDirectory)
    if ($SwmPath) {
        $arguments.Add('/SWMFile:' + $SwmPath)
        $arguments.Add('/CheckIntegrity')
    }

    Invoke-WtgExternal -FilePath 'dism.exe' -Arguments $arguments.ToArray() -JournalPath $JournalPath -Description 'apply windows image' | Out-Null
    return $true
}

function Invoke-WtgAddDrivers {
    <#
    .SYNOPSIS
        Injects storage/chipset drivers into the offline image.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ImageDirectory,
        [Parameter(Mandatory = $true)][string]$DriverDirectory,
        [string]$JournalPath
    )

    Invoke-WtgExternal -FilePath 'dism.exe' -Arguments @(
        '/English', '/Image:' + $ImageDirectory, '/Add-Driver', '/Driver:' + $DriverDirectory, '/Recurse'
    ) -JournalPath $JournalPath -Description 'add drivers to offline image' | Out-Null
    return $true
}

# ---------------------------------------------------------------------------
# Boot configuration
# ---------------------------------------------------------------------------

function Invoke-WtgBcdboot {
    <#
    .SYNOPSIS
        Writes Windows Boot Manager and BCD to the target's own ESP.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WindowsDriveLetter,
        [Parameter(Mandatory = $true)][string]$EspDriveLetter,
        [ValidateSet('UEFI', 'BIOS')][string]$Firmware = 'UEFI',
        [string]$Locale = 'en-us',
        [string]$JournalPath
    )

    # /f decides which boot files are written: EFI\Microsoft\Boot\bootmgfw.efi for
    # UEFI, or \bootmgr plus \Boot\BCD on the active partition for BIOS.
    Invoke-WtgExternal -FilePath 'bcdboot.exe' -Arguments @(
        ($WindowsDriveLetter + ':\Windows'), '/s', ($EspDriveLetter + ':'), '/f', $Firmware, '/l', $Locale
    ) -JournalPath $JournalPath -Description 'install windows boot manager on the target boot partition' | Out-Null
    return $true
}

function Invoke-WtgBootsect {
    <#
    .SYNOPSIS
        Writes the Windows master boot record and volume boot record.

    .DESCRIPTION
        bcdboot only places files. On BIOS firmware the code that loads them must
        exist as well: bootsect /nt60 writes the volume boot record that loads
        \bootmgr, and /mbr writes the master boot record that starts the active
        partition. Without both, a disk can contain a perfectly correct Boot
        Manager and still not start.

        Only ever called on a disk that is already authorized and partitioned, and
        it only names the boot partition of that disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BootDriveLetter,
        [string]$Executable = 'bootsect.exe',
        [string]$JournalPath
    )

    Invoke-WtgExternal -FilePath $Executable -Arguments @(
        '/nt60', ($BootDriveLetter + ':'), '/mbr', '/force'
    ) -JournalPath $JournalPath -Description 'write windows boot code to the target disk' | Out-Null
    return $true
}

function New-WtgRegistryOperations {
    <#
    .SYNOPSIS
        Builds the sequence of reg.exe operations applied to the offline SYSTEM hive.

    .DESCRIPTION
        Pure function: returns the exact command list, bracketed by the hive
        load/unload. Set-WtgOfflinePortableSettings executes it.

        PortableOperatingSystem=1 is the documented Windows To Go marker; it makes
        Windows treat the volume as portable (no hibernation, no boot-time
        assumptions about a fixed disk). HibernateEnabled=0 removes the hibernation
        file, which cannot be relocated off a removable volume. The storage services
        are set boot-start so a machine whose image had them disabled can still
        enumerate the USB/NVMe/SATA controller it booted from.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WindowsDriveLetter,
        [string[]]$BootServices = $script:PortableBootServices
    )

    $hivePath = $WindowsDriveLetter + ':\Windows\System32\config\SYSTEM'
    $mountKey = 'HKLM\WTGOFFLINE_SYSTEM'

    $ops = New-Object 'System.Collections.Generic.List[object]'

    $ops.Add([pscustomobject]@{
        File        = 'reg.exe'
        Arguments   = @('load', $mountKey, $hivePath)
        Description = 'load offline SYSTEM hive'
    })

    $ops.Add([pscustomobject]@{
        File        = 'reg.exe'
        Arguments   = @('add', ($mountKey + '\ControlSet001\Control'), '/v', 'PortableOperatingSystem', '/t', 'REG_DWORD', '/d', '1', '/f')
        Description = 'mark installation as portable'
    })

    $ops.Add([pscustomobject]@{
        File        = 'reg.exe'
        Arguments   = @('add', ($mountKey + '\ControlSet001\Control\Power'), '/v', 'HibernateEnabled', '/t', 'REG_DWORD', '/d', '0', '/f')
        Description = 'disable hibernation'
    })

    foreach ($service in $BootServices) {
        $ops.Add([pscustomobject]@{
            File        = 'reg.exe'
            Arguments   = @('add', ($mountKey + '\ControlSet001\Services\' + $service), '/v', 'Start', '/t', 'REG_DWORD', '/d', '0', '/f')
            Description = ('set ' + $service + ' to boot-start')
        })
    }

    $ops.Add([pscustomobject]@{
        File        = 'reg.exe'
        Arguments   = @('unload', $mountKey)
        Description = 'unload offline SYSTEM hive'
    })

    return $ops.ToArray()
}

function Set-WtgOfflinePortableSettings {
    <#
    .SYNOPSIS
        Executes the offline registry operations and always unloads the hive.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WindowsDriveLetter,
        [string]$JournalPath
    )

    $operations = New-WtgRegistryOperations -WindowsDriveLetter $WindowsDriveLetter
    $hiveLoaded = $false
    $failed = New-Object 'System.Collections.Generic.List[string]'

    try {
        foreach ($operation in $operations) {
            $isLoad = ($operation.Description -eq 'load offline SYSTEM hive')
            $isUnload = ($operation.Description -eq 'unload offline SYSTEM hive')

            $result = Invoke-WtgExternal -FilePath $operation.File -Arguments $operation.Arguments `
                -AllowFailure:($isUnload) -JournalPath $JournalPath -Description $operation.Description

            if ($isLoad) {
                if ($result.ExitCode -ne 0) {
                    throw ('WTG-INSTALL: could not load the offline SYSTEM hive: ' + $result.Output)
                }
                $hiveLoaded = $true
            }

            if ($result.ExitCode -ne 0 -and -not $isUnload) {
                $failed.Add($operation.Description)
            }
        }
    }
    finally {
        if ($hiveLoaded) {
            # Best effort, but a hive left mounted would be a real problem, so retry.
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                $unload = Invoke-WtgExternal -FilePath 'reg.exe' -Arguments @('unload', 'HKLM\WTGOFFLINE_SYSTEM') -AllowFailure
                if ($unload.ExitCode -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
        }
    }

    if ($failed.Count -gt 0) {
        throw ('WTG-INSTALL: portable settings were only partly applied: ' + ($failed -join '; '))
    }

    return $true
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

function Confirm-WtgFallbackLoader {
    <#
    .SYNOPSIS
        Ensures \EFI\Boot\BOOTX64.EFI exists on the target ESP.

    .DESCRIPTION
        Firmware fallback paths vary between vendors, and a disk that only has
        \EFI\Microsoft\Boot\bootmgfw.efi is invisible to some of them. bcdboot
        creates the fallback copy on most builds but not reliably on all, so it is
        verified and copied from bootmgfw.efi when missing.

    .OUTPUTS
        bool - true when the loader is present afterwards.

    .NOTES
        Best effort by design: the caller does not abort on false, because
        Test-WtgInstallation independently requires the same file and is the one
        authority on whether the target is bootable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EspDriveLetter,
        [string]$JournalPath
    )

    $espRoot = $EspDriveLetter + ':'
    $fallback = $espRoot + '\EFI\Boot\BOOTX64.EFI'
    if (Test-Path -LiteralPath $fallback) { return $true }

    $bootManager = $espRoot + '\EFI\Microsoft\Boot\bootmgfw.efi'
    if (-not (Test-Path -LiteralPath $bootManager)) { return $false }

    $fallbackDirectory = $espRoot + '\EFI\Boot'
    if (-not (Test-Path -LiteralPath $fallbackDirectory)) {
        New-Item -ItemType Directory -Path $fallbackDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $bootManager -Destination $fallback -Force

    if ($JournalPath) {
        Add-WtgJournal -Path $JournalPath -Event 'fallback-loader' -Message 'copied bootmgfw.efi to \EFI\Boot\BOOTX64.EFI'
    }

    return (Test-Path -LiteralPath $fallback)
}

function Test-WtgInstallation {
    <#
    .SYNOPSIS
        Checks that a completed installation has the files needed to boot.

    .DESCRIPTION
        Read-only. A missing boot file is reported, never silently ignored.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EspDriveLetter,
        [Parameter(Mandatory = $true)][string]$WindowsDriveLetter
    )

    $checks = New-Object 'System.Collections.Generic.List[object]'

    $required = @(
        @{ Path = ($EspDriveLetter + ':\EFI\Microsoft\Boot\bootmgfw.efi'); Description = 'Windows Boot Manager on the target ESP' },
        @{ Path = ($EspDriveLetter + ':\EFI\Microsoft\Boot\BCD');          Description = 'BCD store on the target ESP' },
        @{ Path = ($EspDriveLetter + ':\EFI\Boot\BOOTX64.EFI');            Description = 'removable-media fallback loader' },
        @{ Path = ($WindowsDriveLetter + ':\Windows\System32\winload.efi'); Description = 'Windows UEFI loader' },
        @{ Path = ($WindowsDriveLetter + ':\Windows\System32\config\SYSTEM'); Description = 'Windows SYSTEM hive' }
    )

    foreach ($item in $required) {
        $exists = Test-Path -LiteralPath $item.Path -ErrorAction SilentlyContinue
        $checks.Add([pscustomobject]@{
            Path        = $item.Path
            Description = $item.Description
            Present     = [bool]$exists
        })
    }

    # The fallback loader is what most firmware actually finds when the drive is
    # selected from a one-time boot menu on an unfamiliar machine.
    $fallback = ($checks | Where-Object { $_.Description -eq 'removable-media fallback loader' } | Select-Object -First 1)
    $missing = @($checks | Where-Object { -not $_.Present })

    return [pscustomobject]@{
        Valid          = ($missing.Count -eq 0)
        Checks         = $checks.ToArray()
        Missing        = @($missing | ForEach-Object { $_.Path })
        FallbackLoader = ($null -ne $fallback -and $fallback.Present)
    }
}

function Test-WtgLegacyInstallation {
    <#
    .SYNOPSIS
        Checks that a completed BIOS installation has the files needed to boot.

    .DESCRIPTION
        Read-only. The BIOS chain is \bootmgr and \Boot\BCD on the active
        partition, then \Windows\System32\winload.exe inside the image.
        winload.efi is deliberately not required: a BIOS installation does not use
        it, and requiring it here would fail a working disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BootDriveLetter,
        [Parameter(Mandatory = $true)][string]$WindowsDriveLetter
    )

    $required = @(
        @{ Path = ($BootDriveLetter + ':\bootmgr');                           Description = 'Windows Boot Manager on the active partition' },
        @{ Path = ($BootDriveLetter + ':\Boot\BCD');                          Description = 'BCD store on the active partition' },
        @{ Path = ($WindowsDriveLetter + ':\Windows\System32\winload.exe');    Description = 'Windows BIOS loader' },
        @{ Path = ($WindowsDriveLetter + ':\Windows\System32\config\SYSTEM');  Description = 'Windows SYSTEM hive' }
    )

    $checks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $required) {
        $exists = Test-Path -LiteralPath $item.Path -ErrorAction SilentlyContinue
        $checks.Add([pscustomobject]@{
            Path        = $item.Path
            Description = $item.Description
            Present     = [bool]$exists
        })
    }

    $missing = @($checks | Where-Object { -not $_.Present })

    return [pscustomobject]@{
        Valid          = ($missing.Count -eq 0)
        Checks         = $checks.ToArray()
        Missing        = @($missing | ForEach-Object { $_.Path })
        FallbackLoader = $false
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-WtgInstall {
    <#
    .SYNOPSIS
        Runs the full installation against one authorized external disk.

    .PARAMETER OnProgress
        Optional scriptblock invoked as (stage, percent, message).
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Authorization,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][int]$ImageIndex,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [string]$SwmPath,
        [string]$DriverDirectory,
        [string]$JournalPath,
        [string]$OperatingSystemLocale = 'en-us',
        [ValidateSet('Uefi', 'Bios')][string]$Firmware = 'Uefi',
        [ValidateSet('Fresh', 'SingleUsb', 'Legacy')][string]$Mode = 'Fresh',
        [int]$WindowsPartitionNumber = 3,
        # bootsect.exe is on PATH in WinPE; a medium built from an ISO also
        # carries a copy at \boot\bootsect.exe for images that lack it.
        [string]$BootsectPath = 'bootsect.exe',
        # Seam for tests: see Invoke-WtgPartition.
        [scriptblock]$PartitionProvider = $null,
        [scriptblock]$OnProgress,
        # Seam for tests: resolves the ESP and Windows drive letters after
        # partitioning. Defaults to the real volume discovery.
        [scriptblock]$VolumeResolver = $null
    )

    $report = {
        param([string]$stage, [int]$percent, [string]$message)
        if ($null -ne $OnProgress) { & $OnProgress $stage $percent $message }
    }

    # ---- stage 1: re-validate the target -------------------------------------
    & $report 'validate' 3 'Re-checking the selected device'
    Assert-WtgDiskWritable -Authorization $Authorization -Disk $Disk -Policy $Policy | Out-Null

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw ('WTG-INSTALL: installation image not found: ' + $ImagePath)
    }
    if ($SwmPath -and -not (Test-Path -LiteralPath $SwmPath)) {
        throw ('WTG-INSTALL: split image set not found: ' + $SwmPath)
    }

    # The partition style has to match the firmware that will start the disk.
    # Getting this wrong produces a complete installation that cannot boot, so it
    # is refused here rather than discovered after an hour of copying.
    if ($Mode -eq 'Legacy' -and $Firmware -ne 'Bios') {
        throw 'WTG-INSTALL: an MBR/BIOS installation cannot be started by UEFI firmware; refusing'
    }
    if ($Mode -ne 'Legacy' -and $Firmware -eq 'Bios') {
        throw ('WTG-INSTALL: this firmware is BIOS, so a {0} layout could not be started from it; refusing' -f $Mode)
    }

    # ---- stage 2: plan the layout -------------------------------------------
    & $report 'layout' 6 'Planning the partition layout'
    if ($Mode -eq 'SingleUsb') {
        # The device is already partitioned by the build; only its capacity is
        # worth checking, because a too-small device cannot hold Windows.
        if ([long]$Disk.Size -lt [long]$Policy.MinimumTargetBytes) {
            throw ('WTG-INSTALL: this device is smaller than the {0:N0} GB minimum for Windows' -f ($Policy.MinimumTargetBytes / 1GB))
        }
        $layout = $null
    }
    elseif ($Mode -eq 'Legacy') {
        $layout = New-WtgLegacyLayoutPlan -DiskSize ([long]$Disk.Size)
        if (-not $layout.Valid) {
            throw ('WTG-INSTALL: the target disk cannot take an MBR layout: ' + ($layout.Errors -join '; '))
        }
    }
    else {
        $layout = New-WtgLayoutPlan -DiskSize ([long]$Disk.Size)
        if (-not $layout.Valid) {
            throw ('WTG-INSTALL: the target disk is too small or the layout is invalid: ' + ($layout.Errors -join '; '))
        }
    }

    if ($JournalPath) {
        $layoutDescription = @()
        if ($null -ne $layout) {
            $layoutDescription = @($layout.Partitions | ForEach-Object { @{ name = $_.Name; mb = $_.SizeMB } })
        }
        Add-WtgJournal -Path $JournalPath -Event 'install-begin' -Message 'starting installation' -Data @{
            disk    = $Authorization.DiskNumber
            serial  = $Authorization.SerialNumber
            image   = $ImagePath
            index   = $ImageIndex
            mode    = $Mode
            layout  = $layoutDescription
        }
    }

    # ---- stage 3: partition --------------------------------------------------
    if ($Mode -eq 'SingleUsb') {
        & $report 'partition' 12 'Formatting the Windows partition on the selected device'
    }
    else {
        & $report 'partition' 12 'Wiping and partitioning the selected device'
    }
    $partitionParameters = @{
        Disk                   = $Disk
        Authorization          = $Authorization
        Policy                 = $Policy
        Layout                 = $layout
        WorkDirectory          = $WorkDirectory
        Mode                   = $Mode
        WindowsPartitionNumber = $WindowsPartitionNumber
        JournalPath            = $JournalPath
    }
    if ($null -ne $PartitionProvider) { $partitionParameters['PartitionProvider'] = $PartitionProvider }
    Invoke-WtgPartition @partitionParameters | Out-Null

    & $report 'partition' 20 'Waiting for the new volumes'
    if ($null -eq $VolumeResolver) {
        if ($Mode -eq 'Legacy') {
            $VolumeResolver = { param($diskNumber) Get-WtgLegacyVolumes -DiskNumber $diskNumber }
        }
        else {
            $VolumeResolver = { param($diskNumber) Get-WtgTargetVolumes -DiskNumber $diskNumber }
        }
    }

    $volumes = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $volumes = & $VolumeResolver $Authorization.DiskNumber
            break
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    if ($null -eq $volumes) {
        throw ('WTG-INSTALL: the new partitions on disk {0} never appeared' -f $Authorization.DiskNumber)
    }

    # ---- stage 4: apply ------------------------------------------------------
    & $report 'apply' 22 ('Applying Windows image index {0}' -f $ImageIndex)
    Invoke-WtgApplyImage -ImagePath $ImagePath -Index $ImageIndex `
        -ApplyDirectory ($volumes.WindowsDriveLetter + ':\') -SwmPath $SwmPath -JournalPath $JournalPath | Out-Null

    if ($DriverDirectory) {
        & $report 'drivers' 72 'Adding additional storage drivers'
        Invoke-WtgAddDrivers -ImageDirectory ($volumes.WindowsDriveLetter + ':\') `
            -DriverDirectory $DriverDirectory -JournalPath $JournalPath | Out-Null
    }

    # ---- stage 5: boot manager ----------------------------------------------
    if ($Mode -eq 'Legacy') {
        & $report 'boot' 80 'Writing Windows Boot Manager to the active partition'
        Invoke-WtgBcdboot -WindowsDriveLetter $volumes.WindowsDriveLetter `
            -EspDriveLetter $volumes.BootDriveLetter -Firmware 'BIOS' `
            -Locale $OperatingSystemLocale -JournalPath $JournalPath | Out-Null

        # Files alone are not a bootable disk: the MBR and volume boot record
        # that lead the firmware to \bootmgr are written here.
        & $report 'boot' 83 'Writing the master and volume boot records'
        Invoke-WtgBootsect -BootDriveLetter $volumes.BootDriveLetter `
            -Executable $BootsectPath -JournalPath $JournalPath | Out-Null
    }
    else {
        & $report 'boot' 80 'Writing Windows Boot Manager to the target ESP'
        Invoke-WtgBcdboot -WindowsDriveLetter $volumes.WindowsDriveLetter `
            -EspDriveLetter $volumes.EspDriveLetter -Firmware 'UEFI' `
            -Locale $OperatingSystemLocale -JournalPath $JournalPath | Out-Null

        # bcdboot may leave \EFI\Boot\BOOTX64.EFI absent; without it many firmware
        # boot menus cannot find the disk at all, so it is placed explicitly.
        if (-not (Confirm-WtgFallbackLoader -EspDriveLetter $volumes.EspDriveLetter -JournalPath $JournalPath)) {
            # Deliberately not fatal here. Test-WtgInstallation is the single place
            # that decides whether the target can boot, and it requires this file,
            # so a failed copy surfaces there instead of as a weaker second verdict.
            & $report 'boot' 82 'could not place the EFI fallback loader; verification will report it'
        }
    }

    # ---- stage 6: portable settings -----------------------------------------
    & $report 'portable' 88 'Configuring portable-OS settings'
    Set-WtgOfflinePortableSettings -WindowsDriveLetter $volumes.WindowsDriveLetter -JournalPath $JournalPath | Out-Null

    # ---- stage 7: verify ----------------------------------------------------
    & $report 'verify' 95 'Verifying boot files on the target'
    if ($Mode -eq 'Legacy') {
        $verification = Test-WtgLegacyInstallation -BootDriveLetter $volumes.BootDriveLetter `
            -WindowsDriveLetter $volumes.WindowsDriveLetter
    }
    else {
        $verification = Test-WtgInstallation -EspDriveLetter $volumes.EspDriveLetter `
            -WindowsDriveLetter $volumes.WindowsDriveLetter
    }

    # Copy the installer log onto the target so it survives a reboot.
    if ($JournalPath -and (Test-Path -LiteralPath $JournalPath)) {
        try {
            # String concatenation, not Join-Path: Join-Path resolves the drive and
            # would throw on a letter that the target does not expose yet.
            $logTarget = ($volumes.WindowsDriveLetter + ':\shimuefi-install.log')
            Copy-Item -LiteralPath $JournalPath -Destination $logTarget -Force -ErrorAction Stop
        }
        catch { }
    }

    & $report 'done' 100 'Installation finished'

    return [pscustomobject]@{
        Verification       = $verification
        EspDriveLetter     = $volumes.EspDriveLetter
        WindowsDriveLetter = $volumes.WindowsDriveLetter
        Layout             = $layout
        Firmware           = $Firmware
        Mode               = $Mode
        DiskNumber         = $Authorization.DiskNumber
        SerialNumber       = $Authorization.SerialNumber
    }
}

Export-ModuleMember -Function @(
    'Set-WtgCommandExecutor',
    'Get-WtgCommandExecutor',
    'Invoke-WtgExternal',
    'New-WtgDiskpartScript',
    'New-WtgSingleUsbDiskpartScript',
    'New-WtgLegacyDiskpartScript',
    'Get-WtgGptTypeLabel',
    'Assert-WtgSingleUsbWindowsPartition',
    'Invoke-WtgPartition',
    'Get-WtgTargetVolumes',
    'Get-WtgLegacyVolumes',
    'ConvertFrom-WtgWimInfo',
    'Get-WtgImageEditions',
    'Invoke-WtgApplyImage',
    'Invoke-WtgAddDrivers',
    'Invoke-WtgBcdboot',
    'Invoke-WtgBootsect',
    'Confirm-WtgFallbackLoader',
    'New-WtgRegistryOperations',
    'Set-WtgOfflinePortableSettings',
    'Test-WtgInstallation',
    'Test-WtgLegacyInstallation',
    'Invoke-WtgInstall'
)
