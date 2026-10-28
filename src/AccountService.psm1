Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CodexRuntime.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProcessAnalysis.psm1') -DisableNameChecking

function Initialize-SwitchApplication($Context) {
    Initialize-Store $Context
}

function Ensure-FileCredentialStore($Context) {
    Assert-CodexClientsStopped -Context $Context
    Set-FileCredentialStore -Context $Context
}

function Get-StandaloneSwitchPlan($Context, [string]$ProfileName) {
    $target = if ($ProfileName) { Get-ProfileObservation $Context $ProfileName } else { $null }
    $processes = @(Get-SwitchProcessSnapshot -Context $Context)
    return New-SwitchPlan -Processes $processes -TargetProfile $target
}

function Save-Current($Context, [string]$ProfileName, [switch]$SetActive) {
    Assert-ProfileName $ProfileName
    Ensure-FileCredentialStore $Context
    Write-CurrentProfile -Context $Context -ProfileName $ProfileName -SetActive:$SetActive
}

function Preserve-CurrentAccount($Context, [switch]$Adding) {
    if (-not (Test-CurrentAuth $Context)) { return }
    $registry = Read-Registry $Context
    $matchingName = Get-MatchingProfileName -Context $Context -Path $Context.AuthPath -Registry $registry
    if (-not $Adding -and $registry.active -and $matchingName -ne [string]$registry.active) {
        Send-SwitchNotice -Context $Context -Warning "The current Codex login does not match the saved active profile '$($registry.active)'. It was not written over that profile."
    }
    if ($matchingName) {
        Save-Current -Context $Context -ProfileName $matchingName -SetActive:$Adding
    } else {
        $profileCount = @($registry.profiles.PSObject.Properties | ForEach-Object { $_.Name }).Count
        $prefix = if ($Adding -and $profileCount -eq 0) { 'previous-' } else { 'recovered-' }
        $backupName = $prefix + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Save-Current -Context $Context -ProfileName $backupName -SetActive:$Adding
        Send-SwitchNotice -Context $Context "The current login was preserved as: $backupName" -ForegroundColor Yellow
    }
}

function Switch-Profile($Context, [string]$ProfileName, [switch]$AutomaticRestart) {
    Assert-ProfileName $ProfileName
    Assert-CodexClientsStopped $Context
    Ensure-FileCredentialStore $Context
    $registry = Read-Registry $Context
    if (-not $registry.profiles.PSObject.Properties[$ProfileName]) { throw "Profile not found: $ProfileName" }
    Preserve-CurrentAccount $Context
    $registry = Read-Registry $Context
    $source = Get-ProfilePath -Context $Context -ProfileName $ProfileName
    if (-not (Get-ProfileObservation $Context $ProfileName).Exists) { throw "Profile file not found: $source" }
    Send-SwitchNotice -Context $Context "Checking saved login: $ProfileName" -ForegroundColor Cyan
    $currentHash = Get-CurrentAuthHash $Context
    try {
        Confirm-CodexProfileAuth -Context $Context -ProfilePath $source
    } finally {
        # Rotation must survive validation failure without overwriting another account.
        Sync-RefreshedCurrentAuth $Context $ProfileName $currentHash
    }
    Assert-CodexClientsStopped $Context
    Set-CurrentAuthFromProfile $Context $ProfileName
    $registry.active = $ProfileName
    Write-Registry $Context $registry
    Send-SwitchNotice -Context $Context "Switched to: $ProfileName" -ForegroundColor Green
    if (-not $AutomaticRestart) { Send-SwitchNotice -Context $Context 'Reopen Codex Desktop, CLI sessions, or your IDE to use the selected account.' -ForegroundColor Yellow }
}

function Add-Account($Context, [string]$ProfileName) {
    Assert-ProfileName $ProfileName
    Assert-CodexClientsStopped $Context
    Ensure-FileCredentialStore $Context
    Preserve-CurrentAccount -Context $Context -Adding
    $pendingAuth = Suspend-CurrentAuth $Context
    try {
        Send-SwitchNotice -Context $Context 'Sign in to the Codex account you want to add in the browser.' -ForegroundColor Cyan
        Invoke-CodexLogin $Context
        Save-Current -Context $Context -ProfileName $ProfileName -SetActive
        Complete-AuthRegistration $Context $pendingAuth
    } catch {
        Complete-AuthRegistration -Context $Context -PendingAuth $pendingAuth -Rollback
        throw
    }
}

function Rename-Profile($Context, [string]$Old, [string]$New) {
    Rename-StoredProfile $Context $Old $New
}

function Remove-Profile($Context, [string]$ProfileName) {
    Remove-StoredProfile $Context $ProfileName
}

function Get-AccountView($Context) {
    $registry = Read-Registry $Context
    $summary = Get-AuthSummary $Context.AuthPath
    $matching = Get-MatchingProfileName -Context $Context -Path $Context.AuthPath -Registry $registry
    $stale = $false
    if ($summary -and $registry.active) {
        $stale = -not (Test-SameAuthIdentity $Context.AuthPath (Get-ProfilePath $Context ([string]$registry.active)))
    }
    [pscustomobject]@{
        Summary=$summary
        MatchingProfile=$matching
        RecordedProfile=$registry.active
        Stale=$stale
    }
}

function Get-ProfileViews($Context) {
    $registry = Read-Registry $Context
    $matching = Get-MatchingProfileName -Context $Context -Path $Context.AuthPath -Registry $registry
    foreach ($property in @($registry.profiles.PSObject.Properties | Sort-Object Name)) {
        [pscustomobject]@{ Name=$property.Name; Email=$property.Value.email; Current=($property.Name -eq $matching) }
    }
}

function Get-RegistrationView($Context, [string]$ProfileName) {
    $summary = Get-AuthSummary $Context.AuthPath
    $existing = $null
    if ($ProfileName) {
        $path = Get-ProfilePath $Context $ProfileName
        $registry = Read-Registry $Context
        if ($registry.profiles.PSObject.Properties[$ProfileName]) { $existing = Get-AuthSummary $path }
    }
    [pscustomobject]@{ Current=$summary; Existing=$existing }
}

function Get-DoctorReport($Context) {
    $cli = Get-CodexExecutable
    $mode = Get-CredentialStoreMode $Context
    $clients = @(Get-CodexClientProcesses $Context)
    $registry = Read-Registry $Context
    $warnings = @()
    if ($mode -ne 'file') { $warnings += 'Reliable switching requires file-based credentials. Close all Codex clients and run: codexSwitch setup' }
    if ($registry.active -and (Test-CurrentAuth $Context)) {
        $activeName = [string]$registry.active
        if (-not (Get-ProfileObservation $Context $activeName).Exists) {
            $warnings += "The active profile file is missing: $activeName"
        } elseif (-not (Test-SameAuthIdentity $Context.AuthPath (Get-ProfilePath $Context $activeName))) {
            $warnings += "The current Codex login does not match the saved active profile '$activeName'."
        }
    }
    $owners = @{}
    foreach ($property in $registry.profiles.PSObject.Properties) {
        $summary = Get-AuthSummary (Get-ProfilePath $Context $property.Name)
        if (-not $summary -or -not $summary.IdentityKey) { continue }
        if (-not $owners.ContainsKey($summary.IdentityKey)) { $owners[$summary.IdentityKey] = @() }
        $owners[$summary.IdentityKey] += $property.Name
    }
    foreach ($names in $owners.Values) {
        if ($names.Count -gt 1) { $warnings += "These profiles contain the same Codex account: $($names -join ', ')" }
    }
    [pscustomobject]@{
        Executable=$cli
        CredentialMode=$mode
        AuthExists=(Test-CurrentAuth $Context)
        Clients=$clients
        Warnings=$warnings
    }
}

Export-ModuleMember -Function Initialize-SwitchApplication, Ensure-FileCredentialStore, Get-StandaloneSwitchPlan, Save-Current, Switch-Profile, Add-Account, Rename-Profile, Remove-Profile, Get-AccountView, Get-ProfileViews, Get-RegistrationView, Get-DoctorReport
