# Layout.Tests.ps1 - partition arithmetic.

. (Join-Path $PSScriptRoot '_assert.ps1')
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
Import-Module (Join-Path $engine 'WinToGo.Layout.psm1') -Force

# Test-WtgSingleUsbTarget takes a plain disk record; _assert.ps1 provides one.

Test-Case 'a typical 1 TB layout fits inside the disk' {
    $plan = New-WtgLayoutPlan -DiskSize 1000GB
    Assert-True $plan.Valid ($plan.Errors -join '; ')
    Assert-Equal 3 $plan.Partitions.Count
    Assert-Equal 'EFI' $plan.Partitions[0].Name
    Assert-Equal 'MSR' $plan.Partitions[1].Name
    Assert-Equal 'Windows' $plan.Partitions[2].Name
    Assert-Equal 512 $plan.Partitions[0].SizeMB
    Assert-Equal 16 $plan.Partitions[1].SizeMB
    Assert-True ($plan.UnallocatedBytes -ge 0)
    Assert-True ($plan.Partitions[2].SizeBytes -gt (900GB)) 'Windows partition should get the remainder'
}

Test-Case 'partitions are ordered, non-overlapping and 1 MiB aligned' {
    $plan = New-WtgLayoutPlan -DiskSize 512GB
    $previousEnd = 0L
    foreach ($partition in $plan.Partitions) {
        Assert-Equal 0 ($partition.StartBytes % 1MB) ('partition ' + $partition.Name + ' is not aligned')
        Assert-True ($partition.StartBytes -ge $previousEnd) ('partition ' + $partition.Name + ' overlaps the previous one')
        $previousEnd = $partition.StartBytes + $partition.SizeBytes
    }
    Assert-True ($previousEnd -le 512GB)
}

Test-Case 'the last partition never runs past the end of the disk' {
    foreach ($size in @(64GB, 100GB, 240GB, 1000GB, 4000GB)) {
        $plan = New-WtgLayoutPlan -DiskSize $size
        $last = $plan.Partitions[$plan.Partitions.Count - 1]
        Assert-True (($last.StartBytes + $last.SizeBytes) -le $size) ('layout overflows a ' + $size + ' byte disk')
    }
}

Test-Case 'a disk that leaves too little room for Windows is rejected' {
    $plan = New-WtgLayoutPlan -DiskSize 20GB
    Assert-False $plan.Valid
    Assert-True (($plan.Errors -join ' ') -match 'below the')
    Assert-Equal 0 $plan.Partitions.Count
}

Test-Case 'an undersized ESP is rejected rather than silently used' {
    $plan = New-WtgLayoutPlan -DiskSize 512GB -EspSizeMB 100
    Assert-False $plan.Valid
    Assert-True (($plan.Errors -join ' ') -match 'EFI system partition')
}

Test-Case 'unreasonable alignment is rejected' {
    $plan = New-WtgLayoutPlan -DiskSize 512GB -AlignmentBytes 512
    Assert-False $plan.Valid
}

Test-Case 'there is no recovery partition option' {
    # A recovery partition that nothing wires into reagentc would be decoration.
    $command = Get-Command New-WtgLayoutPlan
    Assert-False ($command.Parameters.ContainsKey('WithRecovery')) 'WithRecovery must not exist'
    $plan = New-WtgLayoutPlan -DiskSize 256GB
    Assert-Equal 3 $plan.Partitions.Count
    foreach ($partition in $plan.Partitions) {
        Assert-True ($partition.Name -ne 'Recovery') 'no Recovery partition may be planned'
    }
    Assert-True ($plan.UnallocatedBytes -ge 0)
}

Test-Case 'a single-USB target matches the device it was built for' {
    $disk = New-TestDisk -Size 256GB
    $info = [pscustomobject]@{ diskSizeBytes = 256GB; windowsPartition = 3 }
    $result = Test-WtgSingleUsbTarget -Disk $disk -LayoutInfo $info
    Assert-True $result.Valid ($result.Errors -join '; ')
    Assert-Equal 3 $result.WindowsPartition
}

Test-Case 'a single-USB target refuses a device that is not the declared size' {
    $disk = New-TestDisk -Size 128GB
    $info = [pscustomobject]@{ diskSizeBytes = 256GB; windowsPartition = 3 }
    $result = Test-WtgSingleUsbTarget -Disk $disk -LayoutInfo $info
    Assert-False $result.Valid
    Assert-True (($result.Errors -join ' ') -match 'rebuild it with --disk-size') 'the error must say how to fix it'
}

Test-Case 'a single-USB target refuses a medium with no layout description' {
    $result = Test-WtgSingleUsbTarget -Disk (New-TestDisk) -LayoutInfo $null
    Assert-False $result.Valid
    Assert-True (($result.Errors -join ' ') -match 'no single-USB layout description')
}

Test-Case 'a single-USB target refuses a description with no size' {
    $info = [pscustomobject]@{ windowsPartition = 3 }
    $result = Test-WtgSingleUsbTarget -Disk (New-TestDisk -Size 256GB) -LayoutInfo $info
    Assert-False $result.Valid
}

Test-Case 'the rendered layout mentions every partition' {
    $plan = New-WtgLayoutPlan -DiskSize 512GB
    $text = Format-WtgLayout -Plan $plan
    Assert-Contains $text 'EFI'
    Assert-Contains $text 'MSR'
    Assert-Contains $text 'Windows'
}

Test-Case 'a null layout renders an explanation instead of failing' {
    $text = Format-WtgLayout -Plan $null
    Assert-Contains $text 'single-USB'
}

Complete-WtgTestRun 'Layout.Tests'
