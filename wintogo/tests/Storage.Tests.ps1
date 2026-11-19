# Storage.Tests.ps1 - classification and eligibility.
#
# The whole safety model rests on this file: if eMMC, UFS, NVMe or SATA can ever
# classify as External, the installer can destroy an internal disk.

. (Join-Path $PSScriptRoot '_assert.ps1')
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
Import-Module (Join-Path $engine 'WinToGo.Storage.psm1') -Force

$policy = New-WtgStoragePolicy

Test-Case 'USB disk classifies as External with High confidence' {
    $disk = New-TestDisk -Number 1 -BusType 7
    $result = Get-WtgDiskClassify -Disk $disk -Policy $policy
    Assert-Equal 'External' $result.Class
    Assert-Equal 'High' $result.Confidence
    Assert-True $result.External
    Assert-True ($result.Reasons.Count -gt 0) 'classification must always explain itself'
}

Test-Case 'SD card classifies as External but only with Medium confidence' {
    $disk = New-TestDisk -Number 2 -BusType 12
    $result = Get-WtgDiskClassify -Disk $disk -Policy $policy
    Assert-Equal 'External' $result.Class
    Assert-Equal 'Medium' $result.Confidence
}

Test-Case 'eMMC (MMC bus) classifies as Internal' {
    $disk = New-TestDisk -Number 0 -BusType 13 -FriendlyName 'eMMC 64GB'
    $result = Get-WtgDiskClassify -Disk $disk -Policy $policy
    Assert-Equal 'Internal' $result.Class
    Assert-False $result.External
}

Test-Case 'UFS storage classifies as Internal' {
    $result = Get-WtgDiskClassify -Disk (New-TestDisk -BusType 19 -FriendlyName 'UFS 128GB') -Policy $policy
    Assert-Equal 'Internal' $result.Class
}

Test-Case 'NVMe classifies as Internal' {
    $result = Get-WtgDiskClassify -Disk (New-TestDisk -BusType 17) -Policy $policy
    Assert-Equal 'Internal' $result.Class
}

Test-Case 'SATA classifies as Internal' {
    $result = Get-WtgDiskClassify -Disk (New-TestDisk -BusType 11) -Policy $policy
    Assert-Equal 'Internal' $result.Class
}

Test-Case 'the system disk is Internal even when the bus says USB' {
    $disk = New-TestDisk -Number 3 -BusType 7 -IsSystem $true
    $result = Get-WtgDiskClassify -Disk $disk -Policy $policy
    Assert-Equal 'Internal' $result.Class
    Assert-True (($result.Reasons -join ' ') -match 'running-operating-system')
}

Test-Case 'an unrecognised bus type classifies as Unknown, never External' {
    $result = Get-WtgDiskClassify -Disk (New-TestDisk -BusType 999) -Policy $policy
    Assert-Equal 'Unknown' $result.Class
    Assert-Equal 'None' $result.Confidence
    Assert-False $result.External
}

Test-Case 'bus type names are normalised from integers and strings' {
    Assert-Equal 'USB' (ConvertTo-WtgBusTypeName 7)
    Assert-Equal 'USB' (ConvertTo-WtgBusTypeName '7')
    Assert-Equal 'USB' (ConvertTo-WtgBusTypeName 'USB')
    Assert-Equal 'NVMe' (ConvertTo-WtgBusTypeName 17)
    Assert-Equal 'MMC' (ConvertTo-WtgBusTypeName 13)
    Assert-Equal 'SD' (ConvertTo-WtgBusTypeName 12)
    Assert-Equal 'UFS' (ConvertTo-WtgBusTypeName 19)
}

Test-Case 'serial comparison ignores case, spaces and separators' {
    Assert-True (Test-WtgSerialMatch -Actual 'S6T7TEST0001234' -Expected 's6t7 test 0001 234')
    Assert-False (Test-WtgSerialMatch -Actual 'AAAA' -Expected 'BBBB')
    Assert-False (Test-WtgSerialMatch -Actual '' -Expected 'AAAA')
}

Test-Case 'a healthy external disk is eligible' {
    $eligibility = Test-WtgTargetEligible -Disk (New-TestDisk -Number 1 -BusType 7 -Size 256GB) -Policy $policy
    Assert-True $eligibility.Eligible ($eligibility.Errors -join '; ')
    Assert-Equal 0 $eligibility.Errors.Count
}

Test-Case 'an internal disk is never eligible, even with the internal-bus override' {
    $disk = New-TestDisk -Number 0 -BusType 13 -IsSystem $false
    $eligibility = Test-WtgTargetEligible -Disk $disk -Policy $policy -AllowInternalBusOverride
    Assert-False $eligibility.Eligible
    Assert-True (($eligibility.Errors -join ' ') -match 'can never be a target')
}

Test-Case 'a USB disk that is the system disk is not eligible' {
    $eligibility = Test-WtgTargetEligible -Disk (New-TestDisk -BusType 7 -IsSystem $true) -Policy $policy
    Assert-False $eligibility.Eligible
}

Test-Case 'a disk below the minimum capacity is not eligible' {
    $eligibility = Test-WtgTargetEligible -Disk (New-TestDisk -BusType 7 -Size 8GB) -Policy $policy
    Assert-False $eligibility.Eligible
    Assert-True (($eligibility.Errors -join ' ') -match 'below the')
}

Test-Case 'a disk without a serial number is not eligible' {
    $eligibility = Test-WtgTargetEligible -Disk (New-TestDisk -BusType 7 -SerialNumber '') -Policy $policy
    Assert-False $eligibility.Eligible
    Assert-True (($eligibility.Errors -join ' ') -match 'no serial number')
}

Test-Case 'SD cards need explicit confirmation before they are eligible' {
    $card = New-TestDisk -Number 2 -BusType 12 -Size 128GB
    $default = Test-WtgTargetEligible -Disk $card -Policy $policy
    Assert-False $default.Eligible
    Assert-True (($default.Errors -join ' ') -match 'SD')

    $confirmedPolicy = New-WtgStoragePolicy -AllowSdCards
    $confirmed = Test-WtgTargetEligible -Disk $card -Policy $confirmedPolicy -AllowSdCard
    Assert-True $confirmed.Eligible ($confirmed.Errors -join '; ')
}

Test-Case 'an NVMe enclosure needs the explicit override and still warns' {
    $enclosure = New-TestDisk -Number 4 -BusType 17 -Size 512GB
    $default = Test-WtgTargetEligible -Disk $enclosure -Policy $policy
    Assert-False $default.Eligible

    $overridePolicy = New-WtgStoragePolicy -AllowInternalBusOverride
    $overridden = Test-WtgTargetEligible -Disk $enclosure -Policy $overridePolicy -AllowInternalBusOverride
    Assert-True $overridden.Eligible ($overridden.Errors -join '; ')
    Assert-True (($overridden.Warnings -join ' ') -match 'override')
}

Test-Case 'a read-only or offline disk is not eligible' {
    $readOnly = Test-WtgTargetEligible -Disk (New-TestDisk -BusType 7 -IsReadOnly $true) -Policy $policy
    Assert-False $readOnly.Eligible
    $offline = Test-WtgTargetEligible -Disk (New-TestDisk -BusType 7 -IsOffline $true) -Policy $policy
    Assert-False $offline.Eligible
}

Complete-WtgTestRun 'Storage.Tests'
