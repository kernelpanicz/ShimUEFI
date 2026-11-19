# Guard.Tests.ps1 - authorization, the TOCTOU re-check, and the protection plan.
#
# These are the tests that must never be allowed to regress. If they pass, no code
# path can obtain permission to write to an internal disk.

. (Join-Path $PSScriptRoot '_assert.ps1')
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
Import-Module (Join-Path $engine 'WinToGo.Storage.psm1') -Force
Import-Module (Join-Path $engine 'WinToGo.Guard.psm1') -Force

$policy = New-WtgStoragePolicy
$machine = Get-TestMachine
$internal = $machine[0]
$external = $machine[1]

function New-ExternalAuthorization {
    param($Disk = $external, $Policy = $policy, [string]$Serial = 'S6T7TEST0001234')
    New-WtgAuthorization -Disk $Disk -ConfirmedSerial $Serial -Policy $Policy -Operator 'test'
}

Test-Case 'authorization is issued for a matching external disk' {
    $auth = New-ExternalAuthorization
    Assert-Equal $external.Number $auth.DiskNumber
    Assert-Equal 'External' $auth.Class
    Assert-True ($auth.Token.Length -gt 0)
}

Test-Case 'authorization refuses an internal disk' {
    Assert-Throws -Body {
        New-WtgAuthorization -Disk $internal -ConfirmedSerial 'S6B0NL0T123456A' -Policy $policy
    } -MessagePattern 'WTG-PROTECTION'
}

Test-Case 'authorization refuses an eMMC disk even when its serial is confirmed' {
    $emmc = New-TestDisk -Number 0 -BusType 13 -FriendlyName 'eMMC' -SerialNumber 'EMMC0001'
    Assert-Throws -Body {
        New-WtgAuthorization -Disk $emmc -ConfirmedSerial 'EMMC0001' -Policy $policy
    } -MessagePattern 'WTG-PROTECTION'
}

Test-Case 'authorization refuses a mismatched serial number' {
    Assert-Throws -Body {
        New-WtgAuthorization -Disk $external -ConfirmedSerial 'WRONG-SERIAL' -Policy $policy
    } -MessagePattern 'serial number you entered does not match'
}

Test-Case 'authorization accepts a serial typed with spaces and lower case' {
    $auth = New-ExternalAuthorization -Serial ' s6t7 test 0001234 '
    Assert-Equal $external.Number $auth.DiskNumber
}

Test-Case 'authorization denies SD cards unless the policy allows them' {
    $card = New-TestDisk -Number 5 -BusType 12 -Size 128GB -SerialNumber 'SDCARD0001'
    Assert-Throws -Body { New-ExternalAuthorization -Disk $card -Serial 'SDCARD0001' } -MessagePattern 'WTG-PROTECTION'
}

Test-Case 'authorization denies internal-bus overrides the policy forbids' {
    $enclosure = New-TestDisk -Number 6 -BusType 17 -Size 512GB -SerialNumber 'TB3NVME0001'
    Assert-Throws -Body {
        New-WtgAuthorization -Disk $enclosure -ConfirmedSerial 'TB3NVME0001' -Policy $policy -AllowInternalBusOverride
    } -MessagePattern 'policy forbids internal-bus overrides'
}

Test-Case 'a valid token passes the pre-write check' {
    $auth = New-ExternalAuthorization
    Assert-True (Assert-WtgDiskWritable -Authorization $auth -Disk $external -Policy $policy)
}

Test-Case 'the pre-write check refuses a different disk number' {
    $auth = New-ExternalAuthorization
    Assert-Throws -Body {
        Assert-WtgDiskWritable -Authorization $auth -Disk $internal -Policy $policy
    } -MessagePattern 'authorized'
}

Test-Case 'the pre-write check refuses a swapped device with the same number' {
    $auth = New-ExternalAuthorization
    $impostor = New-TestDisk -Number 1 -BusType 7 -SerialNumber 'SOMEOTHERDISK'
    Assert-Throws -Body {
        Assert-WtgDiskWritable -Authorization $auth -Disk $impostor -Policy $policy
    } -MessagePattern 'serial number'
}

Test-Case 'the pre-write check refuses a capacity change' {
    $auth = New-ExternalAuthorization
    $resized = New-TestDisk -Number 1 -BusType 7 -SerialNumber 'S6T7TEST0001234' -Size 64GB
    Assert-Throws -Body {
        Assert-WtgDiskWritable -Authorization $auth -Disk $resized -Policy $policy
    } -MessagePattern 'capacity'
}

Test-Case 'the pre-write check refuses a device that now reports an internal bus' {
    $auth = New-ExternalAuthorization
    $lie = New-TestDisk -Number 1 -BusType 13 -SerialNumber 'S6T7TEST0001234' -Size 1000GB
    Assert-Throws -Body {
        Assert-WtgDiskWritable -Authorization $auth -Disk $lie -Policy $policy
    } -MessagePattern 'classifies as Internal'
}

Test-Case 'the pre-write check refuses when no token was supplied' {
    Assert-Throws -Body {
        Assert-WtgDiskWritable -Authorization $null -Disk $external -Policy $policy
    } -MessagePattern 'no authorization token'
}

Test-Case 'protection plan leaves only the authorized disk writable' {
    $auth = New-ExternalAuthorization
    $media = New-TestDisk -Number 2 -BusType 7 -Size 16GB -FriendlyName 'Installer USB' -SerialNumber 'INSTALLER01'
    $plan = Get-WtgProtectionPlan -Disks @($internal, $external, $media) -Policy $policy -Authorization $auth

    $target = $plan | Where-Object { $_.DiskNumber -eq 1 }
    Assert-False $target.Offline
    Assert-False $target.ReadOnly

    $internalAction = $plan | Where-Object { $_.DiskNumber -eq 0 }
    Assert-True $internalAction.Offline 'internal disk must be offlined'
    Assert-True $internalAction.ReadOnly 'internal disk must be read-only'

    $mediaAction = $plan | Where-Object { $_.DiskNumber -eq 2 }
    Assert-False $mediaAction.Offline 'installer medium must stay readable'
    Assert-True $mediaAction.ReadOnly 'installer medium must be read-only'
}

Test-Case 'protection plan without an authorization protects every disk' {
    $plan = Get-WtgProtectionPlan -Disks @($internal, $external) -Policy $policy -Authorization $null
    foreach ($action in $plan) {
        Assert-True ($action.ReadOnly -or $action.Offline) ('disk ' + $action.DiskNumber + ' was left writable without authorization')
    }
}

Test-Case 'protection plan treats an unclassifiable disk as internal' {
    $weird = New-TestDisk -Number 9 -BusType 900 -SerialNumber 'WEIRD0001'
    $plan = Get-WtgProtectionPlan -Disks @($weird) -Policy $policy -Authorization $null
    Assert-True $plan[0].Offline
    Assert-True $plan[0].ReadOnly
}

Test-Case 'the command filter blocks a command that names a protected disk' {
    $auth = New-ExternalAuthorization
    $plan = Get-WtgProtectionPlan -Disks @($internal, $external) -Policy $policy -Authorization $auth

    Assert-True (Assert-WtgNoWriteToProtected -CommandText 'diskpart /s select disk 1' -Authorization $auth -Plan $plan)
    Assert-Throws -Body {
        Assert-WtgNoWriteToProtected -CommandText 'diskpart select disk 0 clean' -Authorization $auth -Plan $plan
    } -MessagePattern 'protected disk 0'
    Assert-Throws -Body {
        Assert-WtgNoWriteToProtected -CommandText 'dd if=x of=\\.\PhysicalDrive0' -Authorization $auth -Plan $plan
    } -MessagePattern 'protected disk 0'
}

Test-Case 'the journal records one JSON line per event' {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-journal-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    Add-WtgJournal -Path $path -Event 'test' -Message 'hello' -Data @{ disk = 1 }
    Add-WtgJournal -Path $path -Event 'test2' -Message 'world' -Data $null

    $lines = @(Get-Content -LiteralPath $path)
    Assert-Equal 2 $lines.Count
    $parsed = $lines[0] | ConvertFrom-Json
    Assert-Equal 'test' $parsed.event
    Assert-Equal 1 $parsed.data.disk
    Remove-Item -LiteralPath $path -Force
}

Complete-WtgTestRun 'Guard.Tests'
