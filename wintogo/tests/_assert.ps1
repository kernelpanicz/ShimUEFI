# _assert.ps1 - a very small assertion harness.
#
# Pester is not part of WinPE and is not guaranteed on a build host, so the tests
# carry their own harness. Each *.Tests.ps1 file is a standalone script that exits
# non-zero if any assertion fails.

$script:WtgTestCount = 0
$script:WtgTestFailures = New-Object 'System.Collections.Generic.List[string]'

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:WtgTestCount++
    try {
        & $Body
        Write-Host ('  ok    ' + $Name) -ForegroundColor DarkGray
    }
    catch {
        $script:WtgTestFailures.Add(($Name + ' :: ' + $_.Exception.Message))
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        Write-Host ('        ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param($Condition, [string]$Message = 'expected false')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ("$Expected" -ne "$Actual") {
        throw ("{0} expected <{1}> but got <{2}>" -f $Message, $Expected, $Actual)
    }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if ($Haystack -notlike ('*' + $Needle + '*')) {
        throw ("{0} expected to contain <{1}>" -f $Message, $Needle)
    }
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if ($Haystack -like ('*' + $Needle + '*')) {
        throw ("{0} expected NOT to contain <{1}>" -f $Message, $Needle)
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [string]$MessagePattern = '',
        [string]$Message = 'expected an exception'
    )

    $threw = $false
    $text = ''
    try { & $Body } catch { $threw = $true; $text = $_.Exception.Message }
    if (-not $threw) { throw $Message }
    if ($MessagePattern -and $text -notmatch $MessagePattern) {
        throw ("{0}: exception message was <{1}>" -f $Message, $text)
    }
}

function Complete-WtgTestRun {
    param([string]$SuiteName)

    Write-Host ''
    if ($script:WtgTestFailures.Count -gt 0) {
        Write-Host ("{0}: {1} of {2} assertions groups FAILED" -f $SuiteName, $script:WtgTestFailures.Count, $script:WtgTestCount) -ForegroundColor Red
        foreach ($failure in $script:WtgTestFailures) { Write-Host ('  - ' + $failure) -ForegroundColor Red }
        exit 1
    }

    Write-Host ("{0}: {1} tests passed" -f $SuiteName, $script:WtgTestCount) -ForegroundColor Green
    exit 0
}

# Shared test fixtures: disk records shaped exactly like Get-WtgDisk output.
function New-TestDisk {
    param(
        [int]$Number = 0,
        [string]$FriendlyName = 'Test Disk',
        [string]$SerialNumber = 'SN-TEST-0001',
        $BusType = 7,
        [long]$Size = 128GB,
        [bool]$IsBoot = $false,
        [bool]$IsSystem = $false,
        [bool]$IsReadOnly = $false,
        [bool]$IsOffline = $false,
        [string]$PartitionStyle = 'GPT'
    )

    [pscustomobject]@{
        Number         = $Number
        FriendlyName   = $FriendlyName
        SerialNumber   = $SerialNumber
        BusType        = $BusType
        Size           = $Size
        IsBoot         = $IsBoot
        IsSystem       = $IsSystem
        IsReadOnly     = $IsReadOnly
        IsOffline      = $IsOffline
        PartitionStyle = $PartitionStyle
        Path           = '\\.\PhysicalDrive' + $Number
        Location       = 'test'
    }
}

# A realistic machine: internal NVMe system disk + external USB SSD.
function Get-TestMachine {
    $internal = New-TestDisk -Number 0 -FriendlyName 'Samsung SSD 980 PRO 1TB' -SerialNumber 'S6B0NL0T123456A' `
        -BusType 17 -Size 1000GB -IsBoot $true -IsSystem $true
    $external = New-TestDisk -Number 1 -FriendlyName 'Samsung PSSD T7' -SerialNumber 'S6T7TEST0001234' `
        -BusType 7 -Size 1000GB
    return @($internal, $external)
}
