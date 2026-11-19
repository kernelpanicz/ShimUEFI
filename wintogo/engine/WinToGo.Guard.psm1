# WinToGo.Guard.psm1
#
# The write gate and the storage protection plan.
#
# Two independent layers live here:
#
#   1. Authorization (software gate). Every destructive operation must present a
#      WtgAuthorization token that was issued for one specific disk. The token is
#      re-validated against the live disk immediately before each write, so a
#      device swapped in mid-install does not inherit the authorization.
#
#   2. Protection plan (storage-stack enforcement). Before the installer starts,
#      every disk other than the authorized target is taken offline and set
#      read-only through Set-Disk. That is enforced by the Windows storage stack,
#      not by this script: a later bug in the installer cannot write to a disk
#      that the port driver has flagged read-only.
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

# Dependency: WinToGo.Storage.psm1 must be imported by the entry point before this
# module is used. Modules deliberately do not import each other: in Windows
# PowerShell 5.1 a nested `Import-Module -Force` removes the dependency's exports
# from the caller's session, which silently breaks command resolution.
Set-StrictMode -Version 2.0

function New-WtgAuthorization {
    <#
    .SYNOPSIS
        Issues a write authorization token for exactly one disk.

    .DESCRIPTION
        This is the only way to obtain a token, and it refuses anything that is not
        a confidently external disk. The operator must repeat the serial number, so
        a wrong entry in a disk list cannot silently authorize the wrong device.

    .PARAMETER ConfirmedSerial
        The serial number the operator read off the screen. Must match the disk.
    #>
    param(
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)][string]$ConfirmedSerial,
        [Parameter(Mandatory = $true)]$Policy,
        [switch]$AllowSdCard,
        [switch]$AllowInternalBusOverride,
        [string]$Operator = $env:USERNAME
    )

    if (-not $Policy.AllowInternalBusOverride -and $AllowInternalBusOverride) {
        throw 'WTG-PROTECTION: this build policy forbids internal-bus overrides'
    }
    if (-not $Policy.AllowSdCards -and $AllowSdCard) {
        throw 'WTG-PROTECTION: this build policy forbids SD card targets'
    }

    $eligibility = Test-WtgTargetEligible -Disk $Disk -Policy $Policy `
        -AllowSdCard:$AllowSdCard -AllowInternalBusOverride:$AllowInternalBusOverride

    if (-not $eligibility.Eligible) {
        $detail = ($eligibility.Errors -join '; ')
        throw ('WTG-PROTECTION: refusing to authorize disk {0}: {1}' -f (Get-WtgProp $Disk 'Number' '?'), $detail)
    }

    $serial = [string](Get-WtgProp $Disk 'SerialNumber' '')
    if (-not (Test-WtgSerialMatch -Actual $serial -Expected $ConfirmedSerial)) {
        throw ('WTG-PROTECTION: the serial number you entered does not match disk {0}; no authorization was issued' -f (Get-WtgProp $Disk 'Number' '?'))
    }

    $classification = $eligibility.Classification

    return [pscustomobject]@{
        Token            = [guid]::NewGuid().ToString()
        DiskNumber       = [int](Get-WtgProp $Disk 'Number' -1)
        SerialNumber     = $serial
        Size             = [long](Get-WtgProp $Disk 'Size' 0)
        BusType          = $classification.BusType
        Model            = [string](Get-WtgProp $Disk 'FriendlyName' '')
        Class            = $classification.Class
        Confidence       = $classification.Confidence
        OverrideApplied  = [bool]($AllowSdCard -or $AllowInternalBusOverride)
        Operator         = $Operator
        IssuedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        Warnings         = $eligibility.Warnings
    }
}

function Assert-WtgDiskWritable {
    <#
    .SYNOPSIS
        Re-validates an authorization token against the live disk. Throws otherwise.

    .DESCRIPTION
        Called before every destructive step. Verifies disk number, serial number
        and capacity all still agree with the token, and that the disk still
        classifies as external. This is the TOCTOU guard.
    #>
    param(
        $Authorization = $null,
        [Parameter(Mandatory = $true)]$Disk,
        [Parameter(Mandatory = $true)]$Policy
    )

    if ($null -eq $Authorization) {
        throw 'WTG-PROTECTION: no authorization token; every write operation requires one'
    }
    if (-not (Get-WtgProp $Authorization 'Token')) {
        throw 'WTG-PROTECTION: authorization token is malformed'
    }

    $number = [int](Get-WtgProp $Disk 'Number' -1)
    if ($number -ne [int]$Authorization.DiskNumber) {
        throw ('WTG-PROTECTION: operation targets disk {0} but disk {1} is authorized' -f $number, $Authorization.DiskNumber)
    }

    if (-not (Test-WtgSerialMatch -Actual ([string](Get-WtgProp $Disk 'SerialNumber' '')) -Expected ([string]$Authorization.SerialNumber))) {
        throw ('WTG-PROTECTION: serial number of disk {0} no longer matches the authorization; the device was replaced or re-enumerated' -f $number)
    }

    if ([long](Get-WtgProp $Disk 'Size' 0) -ne [long]$Authorization.Size) {
        throw ('WTG-PROTECTION: capacity of disk {0} changed since authorization; refusing to write' -f $number)
    }

    $classification = Get-WtgDiskClassify -Disk $Disk -Policy $Policy
    if ($classification.Class -ne 'External' -and -not $Authorization.OverrideApplied) {
        throw ('WTG-PROTECTION: disk {0} now classifies as {1}; refusing to write' -f $number, $classification.Class)
    }

    return $true
}

function Get-WtgProtectionPlan {
    <#
    .SYNOPSIS
        Computes the protection actions for every attached disk.

    .DESCRIPTION
        - The authorized target is left writable (no action).
        - Every disk classified External but not authorized is set READ-ONLY. It is
          not offlined, because the installer medium itself is usually one of these
          disks and the installation image still has to be read from it.
        - Every disk classified Internal or Unknown is set OFFLINE and READ-ONLY.
          Unknown is treated as internal; we never need to read those disks.

    .OUTPUTS
        DiskNumber, BusType, Class, Offline, ReadOnly, Reason
    #>
    param(
        [Parameter(Mandatory = $true)]$Disks,
        [Parameter(Mandatory = $true)]$Policy,
        $Authorization = $null
    )

    $authorizedNumber = -1
    if ($null -ne $Authorization) { $authorizedNumber = [int]$Authorization.DiskNumber }

    $actions = New-Object 'System.Collections.Generic.List[object]'

    foreach ($disk in @($Disks)) {
        $number = [int](Get-WtgProp $disk 'Number' -1)
        $classification = Get-WtgDiskClassify -Disk $disk -Policy $Policy

        if ($null -ne $Authorization -and $number -eq $authorizedNumber) {
            # Only keep it writable if it still passes validation; otherwise the
            # plan protects it like anything else and the install will abort.
            $actions.Add([pscustomobject]@{
                DiskNumber = $number
                BusType    = $classification.BusType
                Class      = $classification.Class
                Offline    = $false
                ReadOnly   = $false
                Reason     = 'authorized-installation-target'
            })
            continue
        }

        if ($classification.Class -eq 'External') {
            $actions.Add([pscustomobject]@{
                DiskNumber = $number
                BusType    = $classification.BusType
                Class      = $classification.Class
                Offline    = $false
                ReadOnly   = $true
                Reason     = 'external-but-not-authorized; kept readable so the installation image stays available'
            })
        }
        else {
            $actions.Add([pscustomobject]@{
                DiskNumber = $number
                BusType    = $classification.BusType
                Class      = $classification.Class
                Offline    = $true
                ReadOnly   = $true
                Reason     = ('{0}-storage:{1}' -f $classification.Class.ToLowerInvariant(), $classification.BusType)
            })
        }
    }

    return $actions.ToArray()
}

function Invoke-WtgProtectionPlan {
    <#
    .SYNOPSIS
        Applies a plan to the real storage stack, then verifies it.

    .DESCRIPTION
        Read-only/offline flags are applied with Set-Disk. Verification re-reads
        every disk and throws if any protected disk is still writable or online.
        A failed protection plan aborts the whole installer: there is no path that
        continues with unverified protection.
    #>
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [string]$JournalPath
    )

    $applied = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($action in @($Plan)) {
        if (-not $action.ReadOnly -and -not $action.Offline) {
            $applied.Add([pscustomobject]@{ DiskNumber = $action.DiskNumber; Action = 'none'; Error = $null })
            continue
        }

        $errorText = $null
        try {
            if ($action.Offline) {
                Set-Disk -Number $action.DiskNumber -IsOffline $true -ErrorAction Stop
            }
            if ($action.ReadOnly) {
                Set-Disk -Number $action.DiskNumber -IsReadOnly $true -ErrorAction Stop
            }
        }
        catch {
            $errorText = $_.Exception.Message
        }

        if ($null -ne $errorText) {
            $failures.Add(('disk {0}: {1}' -f $action.DiskNumber, $errorText))
        }

        $applied.Add([pscustomobject]@{
            DiskNumber = $action.DiskNumber
            Action     = $(if ($action.Offline) { 'offline+readonly' } else { 'readonly' })
            Error      = $errorText
        })

        if ($JournalPath) {
            Add-WtgJournal -Path $JournalPath -Event 'protect' -Message ('disk {0} -> {1}' -f $action.DiskNumber, $applied[-1].Action) -Data @{
                disk = $action.DiskNumber
                bus  = $action.BusType
                kind = $action.Class
            }
        }
    }

    $verification = Test-WtgProtection -Plan $Plan

    if ($failures.Count -gt 0 -or -not $verification.Protected) {
        $details = @()
        $details += $failures.ToArray()
        $details += $verification.Failures
        throw ('WTG-PROTECTION: the storage protection plan could not be enforced, aborting before any write: ' + ($details -join '; '))
    }

    return [pscustomobject]@{
        Applied      = $applied.ToArray()
        Verification = $verification
        Protected    = $true
    }
}

function Test-WtgProtection {
    <#
    .SYNOPSIS
        Read-only check: is every disk in the plan actually in the state the plan
        requires?

    .OUTPUTS
        Protected  bool
        Failures   string[]
        Disks      per-disk actual state
    #>
    param(
        [Parameter(Mandatory = $true)]$Plan
    )

    $actualDisks = @(Get-WtgDisk)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $rows = New-Object 'System.Collections.Generic.List[object]'

    foreach ($action in @($Plan)) {
        $disk = $actualDisks | Where-Object { $_.Number -eq $action.DiskNumber } | Select-Object -First 1
        if ($null -eq $disk) {
            # Only a disk that vanished or is expected to stay writable may be missing.
            if ($action.ReadOnly -or $action.Offline) {
                $failures.Add(('disk {0} from the protection plan is no longer present' -f $action.DiskNumber))
            }
            continue
        }

        $rows.Add([pscustomobject]@{
            DiskNumber = $disk.Number
            BusType    = $disk.BusType
            IsOffline  = $disk.IsOffline
            IsReadOnly = $disk.IsReadOnly
        })

        if ($action.ReadOnly -and -not $disk.IsReadOnly) {
            $failures.Add(('disk {0} ({1}) is still writable' -f $disk.Number, $disk.BusType))
        }
        if ($action.Offline -and -not $disk.IsOffline) {
            $failures.Add(('disk {0} ({1}) is still online' -f $disk.Number, $disk.BusType))
        }
    }

    return [pscustomobject]@{
        Protected = ($failures.Count -eq 0)
        Failures  = $failures.ToArray()
        Disks     = $rows.ToArray()
    }
}

function Assert-WtgNoWriteToProtected {
    <#
    .SYNOPSIS
        Final sanity check used by the executor: given a command line, refuse to run
        it if it names a disk that is not the authorized target.

    .DESCRIPTION
        A cheap second net under the authorization checks. It is not the primary
        defence (a command line can name a volume instead of a disk) but it catches
        the common case of a stale disk number being passed through.

    .OUTPUTS
        bool
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CommandText,
        [Parameter(Mandatory = $true)]$Authorization,
        [Parameter(Mandatory = $true)]$Plan
    )

    $protectedNumbers = @(@($Plan) | Where-Object { $_.ReadOnly -or $_.Offline } | ForEach-Object { $_.DiskNumber })
    if ($protectedNumbers.Count -eq 0) { return $true }

    $authorized = [int]$Authorization.DiskNumber

    foreach ($text in @($CommandText)) {
        foreach ($number in $protectedNumbers) {
            if ($number -eq $authorized) { continue }
            $pattern = '(?i)(disk|physicaldrive)\s*[:= ]?\s*' + [regex]::Escape([string]$number) + '\b'
            if ($text -match $pattern) {
                throw ('WTG-PROTECTION: refusing to run a command that names protected disk {0}: {1}' -f $number, $text)
            }
        }
    }

    return $true
}

function Add-WtgJournal {
    <#
    .SYNOPSIS
        Appends one JSON line to the audit journal. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message = '',
        $Data = $null
    )

    # An empty path would silently create journal.jsonl in the current directory.
    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $record = [ordered]@{
            time    = (Get-Date).ToUniversalTime().ToString('o')
            event   = $Event
            message = $Message
            data    = $Data
        }

        $line = ($record | ConvertTo-Json -Compress -Depth 8)
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch { }
}

Export-ModuleMember -Function @(
    'New-WtgAuthorization',
    'Assert-WtgDiskWritable',
    'Get-WtgProtectionPlan',
    'Invoke-WtgProtectionPlan',
    'Test-WtgProtection',
    'Assert-WtgNoWriteToProtected',
    'Add-WtgJournal'
)
