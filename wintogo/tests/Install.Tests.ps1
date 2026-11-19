# Install.Tests.ps1 - the installation pipeline.
#
# The last test in this file is the one the project exists for: run a complete
# installation with a mock executor while an internal disk is attached, then prove
# that no command produced by the pipeline ever addresses that internal disk.

. (Join-Path $PSScriptRoot '_assert.ps1')
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
Import-Module (Join-Path $engine 'WinToGo.Storage.psm1') -Force
Import-Module (Join-Path $engine 'WinToGo.Guard.psm1') -Force
Import-Module (Join-Path $engine 'WinToGo.Layout.psm1') -Force
Import-Module (Join-Path $engine 'WinToGo.Install.psm1') -Force

$policy = New-WtgStoragePolicy
$machine = Get-TestMachine
$internal = $machine[0]
$external = $machine[1]

function New-TestAuthorization {
    New-WtgAuthorization -Disk $external -ConfirmedSerial 'S6T7TEST0001234' -Policy $policy -Operator 'test'
}

# Partition records shaped like Get-Partition output.
function New-TestPartition {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [string]$GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}',
        [long]$Size = 900GB,
        [string]$DriveLetter = ''
    )

    [pscustomobject]@{
        PartitionNumber = $Number
        GptType         = $GptType
        Size            = $Size
        DriveLetter     = $DriveLetter
        DiskNumber      = 1
    }
}

# The GPT a single-USB medium is built with: ESP + MSR + empty Windows partition.
function Get-TestSingleUsbPartitions {
    return @(
        (New-TestPartition -Number 1 -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -Size 512MB -DriveLetter 'S'),
        (New-TestPartition -Number 2 -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 16MB),
        (New-TestPartition -Number 3 -Size 960GB)
    )
}

$recordedCalls = New-Object 'System.Collections.Generic.List[object]'

function Reset-RecordedCalls {
    $recordedCalls.Clear()
    $executor = {
        param([string]$FilePath, [string[]]$Arguments)
        $recordedCalls.Add([pscustomobject]@{
            File = $FilePath
            Args = ($Arguments -join ' ')
            Text = ($FilePath + ' ' + ($Arguments -join ' '))
        })
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    Set-WtgCommandExecutor -Executor $executor
}

Test-Case 'the diskpart script targets exactly one disk and builds an ESP/MSR/primary set' {
    $layout = New-WtgLayoutPlan -DiskSize 512GB
    $script = New-WtgDiskpartScript -Layout $layout -DiskNumber 3

    Assert-Contains $script 'select disk 3'
    Assert-Contains $script 'clean'
    Assert-Contains $script 'convert gpt'
    Assert-Contains $script 'create partition efi size=512'
    Assert-Contains $script 'format quick fs=fat32'
    Assert-Contains $script 'create partition msr size=16'
    Assert-Contains $script 'create partition primary'
    Assert-Contains $script 'format quick fs=ntfs'

    # Order matters: the MSR must come after the ESP and before the primary.
    $efiIndex = $script.IndexOf('create partition efi')
    $msrIndex = $script.IndexOf('create partition msr')
    $primaryIndex = $script.IndexOf('create partition primary')
    Assert-True ($efiIndex -lt $msrIndex -and $msrIndex -lt $primaryIndex) 'partition creation order is wrong'

    # Exactly one select statement, and it is never repeated mid-script.
    $selects = ([regex]::Matches($script, '(?im)^\s*select\s+disk')).Count
    Assert-Equal 1 $selects
}

Test-Case 'the single-USB script formats only the Windows partition' {
    $script = New-WtgSingleUsbDiskpartScript -DiskNumber 2 -WindowsPartitionNumber 3

    Assert-Contains $script 'select disk 2'
    Assert-Contains $script 'select partition 3'
    Assert-Contains $script 'format quick fs=ntfs'

    # The installer payload lives on this disk's ESP: wiping the table would
    # destroy the installation image mid-run.
    Assert-NotContains $script 'clean'
    Assert-NotContains $script 'convert gpt'
    Assert-NotContains $script 'create partition efi'
    Assert-NotContains $script 'create partition msr'
    Assert-Equal 1 ([regex]::Matches($script, '(?im)^\s*select\s+disk')).Count
}

Test-Case 'single-USB partitioning refuses a device that is not GPT' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $mbr = New-TestDisk -Number 1 -BusType 7 -SerialNumber 'S6T7TEST0001234' -Size 1000GB -PartitionStyle 'MBR'
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $mbr -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 3
    } -MessagePattern 'GPT'

    Assert-Equal 0 $recordedCalls.Count 'no command may run on a non-GPT device'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses to format the EFI system partition' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    # The ESP holds the installation image this code is running from, so a wrong
    # partition number must be caught before diskpart is started.
    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 1 `
            -PartitionProvider { param($diskNumber) Get-TestSingleUsbPartitions }
    } -MessagePattern 'EFI system partition'

    Assert-Equal 0 $recordedCalls.Count 'nothing may run before the partition is verified'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses the Microsoft reserved partition' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 2 `
            -PartitionProvider { param($diskNumber) Get-TestSingleUsbPartitions }
    } -MessagePattern 'Microsoft reserved partition'

    Assert-Equal 0 $recordedCalls.Count
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses a partition the device does not have' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 4 `
            -PartitionProvider { param($diskNumber) Get-TestSingleUsbPartitions }
    } -MessagePattern 'does not exist'

    Assert-Equal 0 $recordedCalls.Count
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses an unreadable partition table' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 3 `
            -PartitionProvider { param($diskNumber) throw 'storage stack did not answer' }
    } -MessagePattern 'could not read the partition table'

    Assert-Equal 0 $recordedCalls.Count
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses a device without an EFI system partition' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    $noEsp = @(
        (New-TestPartition -Number 1 -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 16MB),
        (New-TestPartition -Number 2 -Size 960GB)
    )

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 2 `
            -PartitionProvider { param($diskNumber) $noEsp }
    } -MessagePattern 'no EFI system partition'

    Assert-Equal 0 $recordedCalls.Count
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning refuses a Windows partition that is too small' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    $tiny = @(
        (New-TestPartition -Number 1 -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -Size 512MB),
        (New-TestPartition -Number 2 -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 16MB),
        (New-TestPartition -Number 3 -Size 4GB)
    )

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
            -Mode SingleUsb -WindowsPartitionNumber 3 `
            -PartitionProvider { param($diskNumber) $tiny }
    } -MessagePattern 'below the'

    Assert-Equal 0 $recordedCalls.Count
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'single-USB partitioning verifies the Windows partition, then formats only it' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $journal = Join-Path $work 'journal.jsonl'

    Invoke-WtgPartition -Disk $external -Authorization $auth -Policy $policy -WorkDirectory $work `
        -Mode SingleUsb -WindowsPartitionNumber 3 -JournalPath $journal `
        -PartitionProvider { param($diskNumber) Get-TestSingleUsbPartitions } | Out-Null

    $scriptText = Get-Content -LiteralPath (Join-Path $work 'partition.txt') -Raw
    Assert-Contains $scriptText 'select partition 3'
    Assert-NotContains $scriptText 'clean'

    Assert-Contains (Get-Content -LiteralPath $journal -Raw) 'single-usb-partition-verified' 'the verification must be journalled'

    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'a malformed layout never produces a partitioning script' {
    $invalid = [pscustomobject]@{ Valid = $false; Errors = @('synthetic failure'); Partitions = @() }
    Assert-Throws -Body { New-WtgDiskpartScript -Layout $invalid -DiskNumber 1 } -MessagePattern 'invalid layout'
}

Test-Case 'partitioning refuses to run against a disk other than the authorized one' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $layout = New-WtgLayoutPlan -DiskSize 512GB
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-test-' + [guid]::NewGuid().ToString('N'))

    Assert-Throws -Body {
        Invoke-WtgPartition -Disk $internal -Authorization $auth -Policy $policy -Layout $layout -WorkDirectory $work
    } -MessagePattern 'WTG-PROTECTION'

    Assert-Equal 0 $recordedCalls.Count 'no command may run when the target is not authorized'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'dism image info output is parsed into editions' {
    $text = @"
Deployment Image Servicing and Management tool
Version: 10.0.22621.1

Details for image : X:\sources\install.wim

Index : 1
Name : Windows 11 Home
Description : Windows 11 Home
Size : 16,384,000,000 bytes

Index : 6
Name : Windows 11 Pro
Description : Windows 11 Pro
Size : 16,500,000,000 bytes

The operation completed successfully.
"@
    $editions = @(ConvertFrom-WtgWimInfo -Text $text)
    Assert-Equal 2 $editions.Count
    Assert-Equal 1 $editions[0].Index
    Assert-Equal 'Windows 11 Home' $editions[0].Name
    Assert-Equal 6 $editions[1].Index
    Assert-Equal 'Windows 11 Pro' $editions[1].Name
    Assert-Equal 16500000000 $editions[1].SizeBytes
}

Test-Case 'the offline registry operations load, set portable flags, then unload' {
    $ops = @(New-WtgRegistryOperations -WindowsDriveLetter 'W')
    Assert-True ($ops.Count -ge 4)

    $load = $ops | Where-Object { $_.Arguments[0] -eq 'load' }
    $unload = $ops | Where-Object { $_.Arguments[0] -eq 'unload' }
    Assert-Equal 1 @($load).Count
    Assert-Equal 1 @($unload).Count
    Assert-Contains ($load.Arguments -join ' ') 'WTGOFFLINE_SYSTEM'
    Assert-Contains ($load.Arguments -join ' ') 'W:\Windows\System32\config\SYSTEM'

    $portable = $ops | Where-Object { $_.Arguments -contains 'PortableOperatingSystem' }
    Assert-Equal 1 @($portable).Count 'PortableOperatingSystem must be set exactly once'
    Assert-Contains ($portable.Arguments -join ' ') 'ControlSet001\Control'
    Assert-Contains ($portable.Arguments -join ' ') '1'

    $hibernate = $ops | Where-Object { $_.Arguments -contains 'HibernateEnabled' }
    Assert-Equal 1 @($hibernate).Count

    $usb = $ops | Where-Object { ($_.Arguments -join ' ') -like '*Services\USBSTOR*' }
    Assert-Equal 1 @($usb).Count 'USBSTOR must be made boot-start for USB boot'
    Assert-Contains ($usb.Arguments -join ' ') 'Start'

    # The hive must be unloaded last: everything else has to happen before it.
    Assert-Equal 'unload' $ops[$ops.Count - 1].Arguments[0]
}

Test-Case 'verification reports every missing boot file instead of assuming success' {
    $result = Test-WtgInstallation -EspDriveLetter 'Q' -WindowsDriveLetter 'R'
    Assert-False $result.Valid
    Assert-True ($result.Missing.Count -ge 5)
    Assert-True (($result.Missing -join ' ') -match 'BCD')
}

# ---------------------------------------------------------------------------
# The critical test.
# ---------------------------------------------------------------------------

Test-Case 'a full install with an internal disk attached writes only to the selected external disk' {
    Reset-RecordedCalls

    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # A stand-in for install.wim: the pipeline only checks that it exists.
    $image = Join-Path $work 'install.wim'
    Set-Content -LiteralPath $image -Value 'test-image'
    $journal = Join-Path $work 'journal.jsonl'

    $progress = New-Object 'System.Collections.Generic.List[string]'
    $onProgress = { param($stage, $percent, $message) $progress.Add($stage) }.GetNewClosure()

    $volumeResolver = { param($diskNumber) [pscustomobject]@{ EspDriveLetter = 'S'; WindowsDriveLetter = 'W' } }

    $result = Invoke-WtgInstall -Disk $external -Authorization $auth -Policy $policy `
        -ImagePath $image -ImageIndex 1 -WorkDirectory $work -JournalPath $journal `
        -OnProgress $onProgress -VolumeResolver $volumeResolver

    # The pipeline really ran to completion.
    Assert-Equal 1 $result.DiskNumber
    Assert-True ($progress.Count -ge 7) 'every stage should report progress'
    Assert-Contains ($progress -join ',') 'partition'
    Assert-Contains ($progress -join ',') 'apply'
    Assert-Contains ($progress -join ',') 'boot'

    # The generated partition script only ever selects the external disk.
    $scriptPath = Join-Path $work 'partition.txt'
    Assert-True (Test-Path -LiteralPath $scriptPath) 'the partition script should exist'
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    Assert-Contains $scriptText 'select disk 1'
    Assert-NotContains $scriptText 'disk 0'

    # No executed command anywhere in the run mentions the internal disk.
    $allText = ($recordedCalls | ForEach-Object { $_.Text }) -join ' || '
    Assert-True ($recordedCalls.Count -gt 5) 'the pipeline should have run external tools'
    Assert-NotContains $allText 'disk 0'
    Assert-NotContains $allText 'PhysicalDrive0'
    Assert-NotContains $allText 'Clean-Disk 0'

    # The expected Microsoft tools were used, and bcdboot wrote to the target ESP.
    Assert-Contains $allText 'diskpart.exe'
    Assert-Contains $allText 'dism.exe'
    Assert-Contains $allText 'bcdboot.exe'
    Assert-Contains $allText 'S:'
    $bcd = $recordedCalls | Where-Object { $_.File -eq 'bcdboot.exe' }
    Assert-Contains ($bcd.Args -join ' ') 'W:\Windows'
    Assert-Contains ($bcd.Args -join ' ') '/f UEFI'

    # Verification honestly reports that the fake target has no boot files.
    Assert-False $result.Verification.Valid

    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'a single-USB install reuses the device partition table and still protects internal disks' {
    Reset-RecordedCalls

    $auth = New-TestAuthorization
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-single-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $image = Join-Path $work 'install.wim'
    Set-Content -LiteralPath $image -Value 'test-image'

    $volumeResolver = { param($diskNumber) [pscustomobject]@{ EspDriveLetter = 'S'; WindowsDriveLetter = 'W' } }
    $partitionProvider = { param($diskNumber) Get-TestSingleUsbPartitions }

    $null = Invoke-WtgInstall -Disk $external -Authorization $auth -Policy $policy `
        -ImagePath $image -ImageIndex 1 -WorkDirectory $work -Mode SingleUsb `
        -WindowsPartitionNumber 3 -VolumeResolver $volumeResolver -PartitionProvider $partitionProvider

    $scriptText = Get-Content -LiteralPath (Join-Path $work 'partition.txt') -Raw
    Assert-NotContains $scriptText 'clean'
    Assert-Contains $scriptText 'select partition 3'

    $allText = ($recordedCalls | ForEach-Object { $_.Text }) -join ' || '
    Assert-NotContains $allText 'disk 0'
    Assert-Contains $allText 'bcdboot.exe'

    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Test-Case 'an install refuses to start when the target is no longer the authorized device' {
    Reset-RecordedCalls
    $auth = New-TestAuthorization
    $swapped = New-TestDisk -Number 1 -BusType 7 -SerialNumber 'DIFFERENTDEVICE' -Size 1000GB

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('wtg-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $image = Join-Path $work 'install.wim'
    Set-Content -LiteralPath $image -Value 'test-image'

    Assert-Throws -Body {
        Invoke-WtgInstall -Disk $swapped -Authorization $auth -Policy $policy -ImagePath $image -ImageIndex 1 `
            -WorkDirectory $work -VolumeResolver { param($n) [pscustomobject]@{ EspDriveLetter = 'S'; WindowsDriveLetter = 'W' } }
    } -MessagePattern 'WTG-PROTECTION'

    $allText = ($recordedCalls | ForEach-Object { $_.Text }) -join ' || '
    Assert-NotContains $allText 'diskpart.exe'
    Assert-NotContains $allText 'bcdboot.exe'

    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

Complete-WtgTestRun 'Install.Tests'
