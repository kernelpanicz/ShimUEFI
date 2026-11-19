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

function Invoke-WtgPartition {
    <#
    .SYNOPSIS
        Wipes and partitions the authorized disk.
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Authorization,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [string]$JournalPath
    )

    Assert-WtgDiskWritable -Authorization $Authorization -Disk $Disk -Policy $Policy | Out-Null

    if (-not (Test-Path -LiteralPath $WorkDirectory)) {
        New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
    }

    $scriptPath = Join-Path $WorkDirectory 'partition.txt'
    $scriptText = New-WtgDiskpartScript -Layout $Layout -DiskNumber $Authorization.DiskNumber
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
        [string]$Locale = 'en-us',
        [string]$JournalPath
    )

    Invoke-WtgExternal -FilePath 'bcdboot.exe' -Arguments @(
        ($WindowsDriveLetter + ':\Windows'), '/s', ($EspDriveLetter + ':'), '/f', 'UEFI', '/l', $Locale
    ) -JournalPath $JournalPath -Description 'install windows boot manager on target esp' | Out-Null
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
        [switch]$WithRecovery,
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

    # ---- stage 2: plan the layout -------------------------------------------
    & $report 'layout' 6 'Planning the partition layout'
    $layout = New-WtgLayoutPlan -DiskSize ([long]$Disk.Size) -WithRecovery:$WithRecovery
    if (-not $layout.Valid) {
        throw ('WTG-INSTALL: the target disk is too small or the layout is invalid: ' + ($layout.Errors -join '; '))
    }

    if ($JournalPath) {
        Add-WtgJournal -Path $JournalPath -Event 'install-begin' -Message 'starting installation' -Data @{
            disk    = $Authorization.DiskNumber
            serial  = $Authorization.SerialNumber
            image   = $ImagePath
            index   = $ImageIndex
            layout  = @($layout.Partitions | ForEach-Object { @{ name = $_.Name; mb = $_.SizeMB } })
        }
    }

    # ---- stage 3: partition --------------------------------------------------
    & $report 'partition' 12 'Wiping and partitioning the selected device'
    Invoke-WtgPartition -Disk $Disk -Authorization $Authorization -Policy $Policy `
        -Layout $layout -WorkDirectory $WorkDirectory -JournalPath $JournalPath | Out-Null

    & $report 'partition' 20 'Waiting for the new volumes'
    if ($null -eq $VolumeResolver) {
        $VolumeResolver = { param($diskNumber) Get-WtgTargetVolumes -DiskNumber $diskNumber }
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
    & $report 'boot' 80 'Writing Windows Boot Manager to the target ESP'
    Invoke-WtgBcdboot -WindowsDriveLetter $volumes.WindowsDriveLetter `
        -EspDriveLetter $volumes.EspDriveLetter -Locale $OperatingSystemLocale -JournalPath $JournalPath | Out-Null

    # ---- stage 6: portable settings -----------------------------------------
    & $report 'portable' 88 'Configuring portable-OS settings'
    Set-WtgOfflinePortableSettings -WindowsDriveLetter $volumes.WindowsDriveLetter -JournalPath $JournalPath | Out-Null

    # ---- stage 7: verify ----------------------------------------------------
    & $report 'verify' 95 'Verifying boot files on the target'
    $verification = Test-WtgInstallation -EspDriveLetter $volumes.EspDriveLetter `
        -WindowsDriveLetter $volumes.WindowsDriveLetter

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
        DiskNumber         = $Authorization.DiskNumber
        SerialNumber       = $Authorization.SerialNumber
    }
}

Export-ModuleMember -Function @(
    'Set-WtgCommandExecutor',
    'Get-WtgCommandExecutor',
    'Invoke-WtgExternal',
    'New-WtgDiskpartScript',
    'Invoke-WtgPartition',
    'Get-WtgTargetVolumes',
    'ConvertFrom-WtgWimInfo',
    'Get-WtgImageEditions',
    'Invoke-WtgApplyImage',
    'Invoke-WtgAddDrivers',
    'Invoke-WtgBcdboot',
    'New-WtgRegistryOperations',
    'Set-WtgOfflinePortableSettings',
    'Test-WtgInstallation',
    'Invoke-WtgInstall'
)
