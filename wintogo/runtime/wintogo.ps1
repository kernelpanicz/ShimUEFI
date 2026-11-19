# wintogo.ps1
#
# ShimUEFI portable Windows - installer front end.
#
# Runs inside WinPE when the installation medium boots. It is a console
# application: WinPE has no window manager, and a console installer is what
# every Windows deployment tool actually uses.
#
# Order of operations is the safety model:
#   1. show what hardware this is
#   2. classify every attached disk (internal / external / unknown)
#   3. require the operator to pick one eligible disk and retype its serial
#   4. re-plan the layout from the real capacity
#   5. take every other disk offline + read-only and verify the storage stack
#      accepted it
#   6. only then start the first write
#
# Nothing can be selected by accident: there is no default disk, and no
# non-interactive path that does not include an explicit serial number.
#
# Copyright (C) 2026 ShimUEFI contributors
# Licensed under the GNU GPL v3. See LICENSE.

[CmdletBinding()]
param(
    # Optional unattended parameters. Both a disk number and its serial number are
    # required together; a bare disk number is refused.
    [int]$DiskNumber = -1,
    [string]$Serial = '',
    [int]$ImageIndex = 0,
    [string]$ImagePath = '',
    [string]$DriverDirectory = '',
    [switch]$AllowSdCard,
    [switch]$AllowInternalBusOverride,
    [switch]$Yes,
    [switch]$DryRun,
    [string]$LogPath = '',
    [string]$UnattendedFile = ''
)

$ErrorActionPreference = 'Stop'

# On the built medium the engine sits next to this script (X:\wintogo\engine).
# Running straight from the repository it is one level up (wintogo/engine).
$script:EngineRoot = Join-Path $PSScriptRoot 'engine'
if (-not (Test-Path -LiteralPath $script:EngineRoot)) {
    $repositoryEngine = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine'
    if (Test-Path -LiteralPath $repositoryEngine) { $script:EngineRoot = $repositoryEngine }
}

if (-not $LogPath) {
    $LogPath = Join-Path $env:TEMP 'shimuefi-install.jsonl'
}

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host ('  ' + $Text) -ForegroundColor White
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('- ' + $Text) -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Text)
    Write-Host ('    ' + $Text) -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Text)
    Write-Host ('    ! ' + $Text) -ForegroundColor Yellow
}

function Write-Bad {
    param([string]$Text)
    Write-Host ('    x ' + $Text) -ForegroundColor Red
}

function Read-Line {
    param([string]$Prompt)
    Write-Host ''
    Write-Host ('  ' + $Prompt) -ForegroundColor White -NoNewline
    return ([string](Read-Host)).Trim()
}

function Exit-Fatal {
    param([string]$Message)
    Write-Host ''
    Write-Host '  INSTALLATION ABORTED' -ForegroundColor Red
    Write-Host ('  ' + $Message) -ForegroundColor Red
    Write-Host ''
    Write-Host '  Nothing was written to any disk. Remove the medium and reboot.' -ForegroundColor Yellow
    Add-WtgJournal -Path $LogPath -Event 'abort' -Message $Message
    exit 1
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $script:EngineRoot)) {
    Write-Host ('engine directory not found at ' + $script:EngineRoot) -ForegroundColor Red
    exit 1
}

Import-Module (Join-Path $script:EngineRoot 'WinToGo.Storage.psm1') -Force
Import-Module (Join-Path $script:EngineRoot 'WinToGo.Guard.psm1')   -Force
Import-Module (Join-Path $script:EngineRoot 'WinToGo.Layout.psm1')  -Force
Import-Module (Join-Path $script:EngineRoot 'WinToGo.Install.psm1') -Force

$policy = New-WtgStoragePolicy -AllowSdCards:$AllowSdCard -AllowInternalBusOverride:$AllowInternalBusOverride

# An unattended answer file shipped on the medium: X:\wintogo\unattended.json
if (-not $UnattendedFile) {
    $candidate = Join-Path $PSScriptRoot 'unattended.json'
    if (Test-Path -LiteralPath $candidate) { $UnattendedFile = $candidate }
}

if ($UnattendedFile -and (Test-Path -LiteralPath $UnattendedFile)) {
    try {
        $answers = Get-Content -LiteralPath $UnattendedFile -Raw | ConvertFrom-Json
        if ($null -ne $answers.diskNumber) { $DiskNumber = [int]$answers.diskNumber }
        if ($answers.serial)      { $Serial = [string]$answers.serial }
        if ($null -ne $answers.imageIndex) { $ImageIndex = [int]$answers.imageIndex }
        if ($answers.imagePath)   { $ImagePath = [string]$answers.imagePath }
        if ($answers.driverDirectory) { $DriverDirectory = [string]$answers.driverDirectory }
        if ($answers.allowSdCard) { $AllowSdCard = $true }
        if ($answers.allowInternalBusOverride) { $AllowInternalBusOverride = $true }
        if ($answers.yes)         { $Yes = $true }
    }
    catch {
        Exit-Fatal ('the unattended answer file is unreadable: ' + $_.Exception.Message)
    }
}

# True when both a disk and its serial were supplied (answer file or arguments).
# Even then the authorization step re-checks the serial against the live disk.
$unattendedRun = ($DiskNumber -ge 0) -and ($Serial -ne '')

Write-Head 'ShimUEFI - Portable Windows installation'
if ($DryRun) {
    Write-Host '  DRY RUN: the full plan is computed, nothing is written.' -ForegroundColor Yellow
}
Write-Note ('log: ' + $LogPath)

Add-WtgJournal -Path $LogPath -Event 'start' -Message 'installer started' -Data @{
    dryRun  = [bool]$DryRun
    version = '1.0'
}

# ---------------------------------------------------------------------------
# Step 1: hardware
# ---------------------------------------------------------------------------

Write-Step 'This computer'
try {
    $hardware = Get-WtgHardwareReport
    Write-Note ('model       ' + $hardware.ComputerModel)
    Write-Note ('firmware    ' + $hardware.Firmware + ' / Secure Boot ' + $hardware.SecureBoot)
    Write-Note ('cpu         ' + $hardware.Processor)
    Write-Note ('memory      ' + $hardware.MemoryGB + ' GB')
}
catch {
    Write-Warn 'hardware details unavailable'
}

# ---------------------------------------------------------------------------
# Step 2: disks
# ---------------------------------------------------------------------------

Write-Step 'Attached storage'
$disks = @(Get-WtgDisk)
if ($disks.Count -eq 0) { Exit-Fatal 'no disks were detected' }

$candidates = New-Object 'System.Collections.Generic.List[object]'

foreach ($disk in $disks) {
    $classification = Get-WtgDiskClassify -Disk $disk -Policy $policy
    $eligibility = Test-WtgTargetEligible -Disk $disk -Policy $policy `
        -AllowSdCard:$AllowSdCard -AllowInternalBusOverride:$AllowInternalBusOverride

    $label = switch ($classification.Class) {
        'External' { 'EXTERNAL' }
        'Internal' { 'INTERNAL' }
        default    { 'UNKNOWN ' }
    }

    $colour = switch ($classification.Class) {
        'External' { 'Green' }
        'Internal' { 'Red' }
        default    { 'Yellow' }
    }

    Write-Host ('  ' + $label + '  ') -ForegroundColor $colour -NoNewline
    Write-Host (Format-WtgDiskSummary -Disk $disk) -NoNewline
    Write-Host ''

    if ($eligibility.Eligible) {
        $candidates.Add([pscustomobject]@{
            Disk = $disk
            Index = $candidates.Count + 1
            Eligibility = $eligibility
        })
        Write-Host ('              selectable as option ' + $candidates.Count) -ForegroundColor Green
    }
    else {
        Write-Note ('not selectable: ' + ($eligibility.Errors[0]))
    }
}

Write-Host ''
Write-Host '  Internal and unknown disks are protected by the storage stack before any' -ForegroundColor DarkGray
Write-Host '  write happens. They are never offered as a target.' -ForegroundColor DarkGray

if ($candidates.Count -eq 0) {
    Write-Host ''
    Write-Bad 'no external disk is available as an installation target'
    Write-Note 'connect a USB drive, external SSD/HDD or SD card and reboot the medium'
    Exit-Fatal 'no eligible external disk'
}

# ---------------------------------------------------------------------------
# Step 3: locate the Windows image on this medium
# ---------------------------------------------------------------------------

function Find-WindowsImage {
    # Returns the image set found on a volume, and the disk that volume lives on,
    # so the medium itself can never be offered as an installation target.
    $found = New-Object 'System.Collections.Generic.List[object]'

    foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue)) {
        $letter = [string]$volume.DriveLetter
        if (-not $letter) { continue }

        $root = $letter + ':\sources\'
        $candidates = @(
            @{ Path = ($root + 'install.wim'); Swm = $null },
            @{ Path = ($root + 'install.esd'); Swm = $null },
            @{ Path = ($root + 'install.swm'); Swm = ($root + 'install*.swm') }
        )

        foreach ($candidateSet in $candidates) {
            if (Test-Path -LiteralPath $candidateSet.Path) {
                $diskNumber = -1
                try {
                    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
                    $diskNumber = [int]$partition.DiskNumber
                }
                catch { }

                $found.Add([pscustomobject]@{
                    ImagePath  = $candidateSet.Path
                    SwmPath    = $candidateSet.Swm
                    DriveLetter = $letter
                    DiskNumber = $diskNumber
                    SizeBytes  = (Get-Item -LiteralPath $candidateSet.Path).Length
                })
                break
            }
        }
    }

    return $found.ToArray()
}

Write-Step 'Windows installation media on this medium'
$images = @(Find-WindowsImage)
if ($images.Count -eq 0) {
    Write-Bad 'no Windows image (sources\install.wim, .esd or .swm) was found'
    Write-Note 'this medium was not built with Windows installation media attached'
    Exit-Fatal 'installation media missing'
}

$imageSet = $images | Where-Object { $_.SizeBytes -gt 1GB } | Select-Object -First 1
if ($null -eq $imageSet) {
    Write-Bad 'the Windows image on this medium appears to be incomplete'
    Exit-Fatal 'installation media incomplete'
}

Write-Note ('image  ' + $imageSet.ImagePath)
Write-Note ('source disk ' + $imageSet.DiskNumber + ' (this medium - it will be made read-only)')

# Remove the medium from the candidate list: overwriting the running installer's
# own disk mid-install is not recoverable.
$before = $candidates.Count
$filtered = @($candidates | Where-Object { $_.Disk.Number -ne $imageSet.DiskNumber })
$candidates = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $filtered.Count; $i++) {
    $entry = $filtered[$i]
    $candidates.Add([pscustomobject]@{ Disk = $entry.Disk; Index = $i + 1; Eligibility = $entry.Eligibility })
}
if ($candidates.Count -lt $before) {
    Write-Warn 'the disk holding this installer was removed from the list of targets'
}

if ($candidates.Count -eq 0) {
    Exit-Fatal 'the only removable disk is the installer medium itself; connect a second external disk'
}

# ---------------------------------------------------------------------------
# Step 4: choose the target
# ---------------------------------------------------------------------------

Write-Step 'Choose the installation target'
foreach ($candidate in $candidates) {
    Write-Host ('  ' + $candidate.Index + ') ') -ForegroundColor White -NoNewline
    Write-Host (Format-WtgDiskSummary -Disk $candidate.Disk -Classification $candidate.Eligibility.Classification)
    Write-Host ('     ' + [math]::Round($candidate.Disk.Size / 1GB, 1) + ' GB, ' + $candidate.Disk.PartitionStyle + ' partition table, serial ' + $candidate.Disk.SerialNumber) -ForegroundColor DarkGray
}

$selected = $null

if ($DiskNumber -ge 0) {
    $selected = $candidates | Where-Object { $_.Disk.Number -eq $DiskNumber } | Select-Object -First 1
    if ($null -eq $selected) {
        Exit-Fatal ("disk {0} is not an eligible external target on this computer" -f $DiskNumber)
    }
}
else {
    while ($null -eq $selected) {
        $answer = Read-Line ('Enter the number of the disk to install Windows onto, or "q" to quit: ')
        if ($answer -eq 'q') { Exit-Fatal 'cancelled by the operator' }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number)) {
            $selected = $candidates | Where-Object { $_.Index -eq $number } | Select-Object -First 1
            if ($null -eq $selected) { Write-Bad 'that is not one of the listed options' }
        }
        else { Write-Bad 'enter a number from the list' }
    }
}

$target = $selected.Disk
$targetClassification = $selected.Eligibility.Classification

Write-Host ''
Write-Host '  Selected device' -ForegroundColor White
Write-Host ('    model      ' + $target.FriendlyName)
Write-Host ('    capacity   ' + [math]::Round($target.Size / 1GB, 1) + ' GB')
Write-Host ('    connection ' + $targetClassification.BusType + ' (' + $targetClassification.Class + ', confidence ' + $targetClassification.Confidence + ')')
Write-Host ('    serial     ' + $target.SerialNumber) -ForegroundColor Yellow
Write-Host ('    disk index ' + $target.Number)

# The operator must repeat the serial. This is the step that makes installing to
# the wrong device effectively impossible, including in a rack of identical drives.
$confirmed = $Serial
if (-not $confirmed) {
    Write-Host ''
    Write-Host '  Type the serial number above exactly to confirm this device.' -ForegroundColor White
    Write-Host '  Every byte of this installation will go to this disk and nowhere else.' -ForegroundColor DarkGray
    $confirmed = Read-Line 'Serial number, or "q" to quit: '
    if ($confirmed -eq 'q') { Exit-Fatal 'cancelled by the operator' }
}

$authorization = $null
try {
    $authorization = New-WtgAuthorization -Disk $target -ConfirmedSerial $confirmed -Policy $policy `
        -AllowSdCard:$AllowSdCard -AllowInternalBusOverride:$AllowInternalBusOverride
}
catch {
    Exit-Fatal $_.Exception.Message
}

foreach ($warning in $authorization.Warnings) { Write-Warn $warning }

Write-Host ''
Write-Host ('  Authorized: disk ' + $authorization.DiskNumber + ', serial ' + $authorization.SerialNumber) -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 5: edition and layout
# ---------------------------------------------------------------------------

Write-Step 'Windows edition'
$editions = @()
try {
    $editions = @(Get-WtgImageEditions -ImagePath $imageSet.ImagePath -JournalPath $LogPath)
}
catch {
    Write-Warn ('could not list editions automatically: ' + $_.Exception.Message)
}

if ($editions.Count -eq 0) {
    Exit-Fatal 'the Windows image contains no usable image index'
}

for ($i = 0; $i -lt $editions.Count; $i++) {
    Write-Host ('  ' + ($i + 1) + ') ') -ForegroundColor White -NoNewline
    Write-Host ($editions[$i].Name) -NoNewline
    Write-Host ('  [' + [math]::Round($editions[$i].SizeBytes / 1GB, 1) + ' GB]') -ForegroundColor DarkGray
}

$chosenEdition = $null
if ($ImageIndex -gt 0) {
    $chosenEdition = $editions | Where-Object { $_.Index -eq $ImageIndex } | Select-Object -First 1
    if ($null -eq $chosenEdition) {
        Exit-Fatal ('image index {0} does not exist in this image' -f $ImageIndex)
    }
}
elseif ($editions.Count -eq 1) {
    $chosenEdition = $editions[0]
}
else {
    while ($null -eq $chosenEdition) {
        $answer = Read-Line 'Edition number: '
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $editions.Count) {
            $chosenEdition = $editions[$number - 1]
        }
        else { Write-Bad 'enter a number from the list' }
    }
}

Write-Host ('  selected: ' + $chosenEdition.Name) -ForegroundColor Green

Write-Step 'Partition layout for this device'
$layout = New-WtgLayoutPlan -DiskSize ([long]$target.Size)
if (-not $layout.Valid) {
    Exit-Fatal ('this device is too small: ' + ($layout.Errors -join '; '))
}
Write-Host (Format-WtgLayout -Plan $layout)
Write-Note ('unallocated at the end: ' + [math]::Round($layout.UnallocatedBytes / 1MB, 1) + ' MiB (backup partition table)')

# ---------------------------------------------------------------------------
# Step 6: storage protection
# ---------------------------------------------------------------------------

Write-Step 'Internal storage protection'
$plan = Get-WtgProtectionPlan -Disks $disks -Policy $policy -Authorization $authorization

foreach ($action in $plan) {
    $verb = if ($action.Offline) { 'offline + read-only' } elseif ($action.ReadOnly) { 'read-only' } else { 'left writable' }
    $colour = if ($action.Offline -or $action.ReadOnly) { 'Green' } else { 'Yellow' }
    Write-Host ('  disk ' + $action.DiskNumber + '  ') -NoNewline
    Write-Host ($verb.PadRight(20)) -ForegroundColor $colour -NoNewline
    Write-Host (' ' + $action.Class + ' ' + $action.BusType) -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host ''
    Write-Host '  DRY RUN: the protection plan above was NOT applied and nothing was written.' -ForegroundColor Yellow
    Add-WtgJournal -Path $LogPath -Event 'dry-run-complete' -Message 'plan computed, no writes'
    Write-Host ''
    Write-Host ('  Planned target: disk ' + $authorization.DiskNumber + ' ' + $authorization.Model) -ForegroundColor White
    Write-Host ('  Planned edition: ' + $chosenEdition.Name + ' (index ' + $chosenEdition.Index + ')') -ForegroundColor White
    exit 0
}

$protection = $null
try {
    $protection = Invoke-WtgProtectionPlan -Plan $plan -JournalPath $LogPath
}
catch {
    Exit-Fatal $_.Exception.Message
}

if (-not $protection.Protected) {
    Exit-Fatal 'storage protection could not be verified'
}

Write-Host ''
Write-Host '  Protection verified: every other disk is read-only, internal disks are offline.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 7: confirmation
# ---------------------------------------------------------------------------

Write-Head 'Ready to install'
Write-Host ('  Target disk   ' + $authorization.DiskNumber + '  ' + $authorization.Model)
Write-Host ('  Serial        ' + $authorization.SerialNumber)
Write-Host ('  Capacity      ' + [math]::Round($authorization.Size / 1GB, 1) + ' GB')
Write-Host ('  Edition       ' + $chosenEdition.Name)
Write-Host ''
Write-Host '  THIS ERASES THE SELECTED DISK COMPLETELY.' -ForegroundColor Red
Write-Host '  No internal disk will be touched. Type INSTALL to continue.' -ForegroundColor White

if ($unattendedRun -or $Yes) {
    Write-Host '  (unattended: the serial number above was supplied and verified)' -ForegroundColor DarkGray
}
else {
    $confirmation = Read-Line 'Type INSTALL: '
    if ($confirmation -cne 'INSTALL') { Exit-Fatal 'not confirmed by the operator' }
}

# ---------------------------------------------------------------------------
# Step 8: install
# ---------------------------------------------------------------------------

Write-Head 'Installing Windows'
$workDirectory = Join-Path $env:TEMP 'shimuefi-work'
if (-not (Test-Path -LiteralPath $workDirectory)) {
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
}

$lastPercent = -1
$progress = {
    param($stage, $percent, $message)

    if ($percent -ne $lastPercent) {
        $lastPercent = $percent
        $filled = [int]([math]::Floor($percent / 2))
        $bar = ('#' * $filled).PadRight(50, '.')
        Write-Host ("`r  [" + $bar + ('] {0,3}%  ' -f $percent)) -NoNewline -ForegroundColor Cyan
    }
    if ($message) {
        Write-Host ''
        Write-Host ('      ' + $message) -ForegroundColor DarkGray
    }
}

$result = $null
try {
    $result = Invoke-WtgInstall -Disk $target -Authorization $authorization -Policy $policy `
        -ImagePath $imageSet.ImagePath -SwmPath $imageSet.SwmPath -ImageIndex $chosenEdition.Index `
        -WorkDirectory $workDirectory -DriverDirectory $DriverDirectory -JournalPath $LogPath `
        -OnProgress $progress
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Add-WtgJournal -Path $LogPath -Event 'install-failed' -Message $_.Exception.Message
    Write-Host ''
    Write-Host '  The installation did not complete. The selected disk may be partly written;' -ForegroundColor Yellow
    Write-Host '  no other disk was touched. Re-run the installer to retry.' -ForegroundColor Yellow
    Write-Host ('  Log: ' + $LogPath) -ForegroundColor DarkGray
    exit 1
}

Write-Host ''
Write-Host ''

# ---------------------------------------------------------------------------
# Step 9: result
# ---------------------------------------------------------------------------

if (-not $result.Verification.Valid) {
    Write-Head 'Installation finished with problems'
    Write-Bad 'these required boot files are missing on the target:'
    foreach ($missing in $result.Verification.Missing) { Write-Note $missing }
    Write-Host ''
    Write-Host '  Do not expect this disk to boot. The installer log is on the Windows' -ForegroundColor Yellow
    Write-Host '  partition as shimuefi-install.log.' -ForegroundColor Yellow
    Add-WtgJournal -Path $LogPath -Event 'verify-failed' -Message 'missing boot files'
    exit 1
}

Write-Head 'Installation complete'
Write-Host '  Windows is installed on the external disk and is independently bootable.' -ForegroundColor Green
Write-Host ''
Write-Host '  Next steps' -ForegroundColor White
Write-Host '    1. Remove the installer medium.'
Write-Host '    2. Keep the external disk connected and reboot this computer, choosing the'
Write-Host '       external disk in the one-time boot menu (usually F12, F9, F10 or Esc).'
Write-Host '    3. Windows will finish setup (language, account, licence) on first boot.'
Write-Host '    4. On another computer, use that computer''s boot menu to pick the disk.'
Write-Host ''
Write-Host '  Notes' -ForegroundColor White
Write-Host '    - The internal disk of this computer was never written to.' -ForegroundColor Green
Write-Host '    - First boot on a different computer may take several minutes while Windows'
Write-Host '      installs drivers. BitLocker is off by default for portable installs.'
Write-Host '    - Some copy-protected software and Windows Update features behave differently'
Write-Host '      on removable media; see the project documentation.'
Write-Host ''
Write-Host ('  Log: ' + $LogPath)

Add-WtgJournal -Path $LogPath -Event 'install-complete' -Message 'installation verified'

if ($unattendedRun -or $Yes) {
    # No prompt on an automated run: nothing would answer it.
    Write-Host '  Leaving the installer. Reboot to start Windows.' -ForegroundColor DarkGray
    exit 0
}

Write-Host ''
$answer = Read-Line 'Reboot now into the new installation? (y/N): '
if ($answer -eq 'y') {
    Write-Host '  Rebooting...' -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    wpeutil reboot
}
exit 0
