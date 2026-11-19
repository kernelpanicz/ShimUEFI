# Layout.Tests.ps1 - partition arithmetic.

. (Join-Path $PSScriptRoot '_assert.ps1')
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
Import-Module (Join-Path $engine 'WinToGo.Layout.psm1') -Force

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

Test-Case 'the recovery partition is only added on request' {
    $without = New-WtgLayoutPlan -DiskSize 256GB
    Assert-Equal 3 $without.Partitions.Count
    $with = New-WtgLayoutPlan -DiskSize 256GB -WithRecovery
    Assert-Equal 4 $with.Partitions.Count
    Assert-Equal 'Recovery' $with.Partitions[3].Name
    Assert-True ($with.UnallocatedBytes -ge 0)
}

Test-Case 'the rendered layout mentions every partition' {
    $plan = New-WtgLayoutPlan -DiskSize 512GB
    $text = Format-WtgLayout -Plan $plan
    Assert-Contains $text 'EFI'
    Assert-Contains $text 'MSR'
    Assert-Contains $text 'Windows'
}

Complete-WtgTestRun 'Layout.Tests'
