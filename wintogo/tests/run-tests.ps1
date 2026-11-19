# run-tests.ps1 - runs every *.Tests.ps1 suite in a separate process.
#
# Works with Windows PowerShell 5.1 (the version present in WinPE) and with
# PowerShell 7+. No Pester requirement.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File wintogo\tests\run-tests.ps1

[cmdletBinding()]
param(
    [string]$Filter = '*.Tests.ps1'
)

$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$suites = @(Get-ChildItem -Path $testRoot -Filter $Filter | Sort-Object Name)

if ($suites.Count -eq 0) {
    Write-Host "No test suites matched $Filter in $testRoot" -ForegroundColor Red
    exit 1
}

# Prefer the same PowerShell through which we are running, so a pwsh host uses pwsh.
$hostExe = (Get-Process -Id $PID).Path
if (-not $hostExe) { $hostExe = 'powershell.exe' }

$failures = New-Object 'System.Collections.Generic.List[string]'

foreach ($suite in $suites) {
    Write-Host ''
    Write-Host ('== ' + $suite.Name) -ForegroundColor Cyan
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File $suite.FullName
    if ($LASTEXITCODE -ne 0) {
        $failures.Add($suite.Name)
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ('RESULT: {0} of {1} suites failed: {2}' -f $failures.Count, $suites.Count, ($failures -join ', ')) -ForegroundColor Red
    exit 1
}

Write-Host ('RESULT: all {0} suites passed' -f $suites.Count) -ForegroundColor Green
exit 0
