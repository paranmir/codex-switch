Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexRuntime.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AccountService.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RestartService.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -Function Enter-SwitchLock,Exit-SwitchLock,Read-SwitchOperation -DisableNameChecking

function Write-ConsoleNotice($Message, $ForegroundColor, $Warning) {
    if ($Warning) { Write-Warning $Message } else { Write-Host $Message -ForegroundColor $ForegroundColor }
}

function Invoke-CodexSwitchCommand {
    param([object]$Context, [string]$Command, [string]$Name, [string]$NewName, [switch]$Json, [switch]$Manual)
    if ($Json -and $Command -notin @('plan','status')) { throw '-Json is supported only with plan or status.' }
    if ($Manual -and $Command -ne 'switch') { throw '-Manual is supported only with switch.' }
    $lock = $null
    try {
        if ($Command -notin @('plan','help','status','menu')) { $lock=Enter-SwitchLock }
        Invoke-SwitchCommandCore -Context $Context -Command $Command -Name $Name -NewName $NewName -Json:$Json -Manual:$Manual
    } finally { if ($lock) { Exit-SwitchLock $lock } }
}

function Invoke-SwitchCommandCore {
    param($Context, [string]$Command, [string]$Name, [string]$NewName, [switch]$Json, [switch]$Manual)
    if ($Command -eq 'plan') {
        Show-StandaloneSwitchPlan -Context $Context -ProfileName $Name -AsJson:$Json
        return
    }
    if ($Command -eq 'help') { Show-Help; return }
    if ($Command -eq 'menu') { Start-Menu -Context $Context; return }
    if ($Command -eq 'status') {
        $operation = Read-SwitchOperation $Context
        if ($Json) { ConvertTo-Json -InputObject $operation -Depth 5 }
        elseif ($operation) {
            Write-Host "Last operation: $($operation.Stage); target: $($operation.Target); auth file applied: $($operation.AccountChanged)"
            Write-Host 'The selected account inside each application has not been verified.' -ForegroundColor Yellow
            if ($operation.Stage -ne 'completed') { Write-Host 'Check whoami and the affected applications before retrying.' -ForegroundColor Yellow }
        } else { Write-Host 'No automatic restart operation has been recorded.' }
        return
    }
    Initialize-SwitchApplication -Context $Context
    switch ($Command) {
        'menu'   { Start-Menu -Context $Context }
        'whoami' { Show-WhoAmI -Context $Context }
        'list'   { Show-List -Context $Context }
        'add'    { Add-Account -Context $Context -ProfileName $Name }
        'save'   { Save-Current -Context $Context -ProfileName $Name -SetActive }
        'switch' {
            if ($Manual) { Switch-Profile -Context $Context -ProfileName $Name }
            else {
                $result = Invoke-AutomaticAccountSwitch -Context $Context -ProfileName $Name
                if ($result.AppsRestarted) {
                    Write-Host "Reopen requested: $($result.WindowCount) app(s), $($result.ConsoleCount) CLI session(s). Details: codexSwitch status" -ForegroundColor DarkGray
                    if ($result.ConsoleCount -gt 0) {
                        Write-Host 'CLI sessions opened in new consoles; previous terminal tabs and conversations were not restored.' -ForegroundColor Yellow
                    }
                }
            }
            Show-WhoAmI -Context $Context
        }
        'rename' { Rename-Profile -Context $Context -Old $Name -New $NewName }
        'remove' { Remove-Profile -Context $Context -ProfileName $Name }
        'delete' { Remove-Profile -Context $Context -ProfileName $Name }
        'files'  { Start-Process explorer.exe $Context.ProfilesDir; Write-Host $Context.ProfilesDir }
        'setup'  { Ensure-FileCredentialStore -Context $Context }
        'doctor' { Show-Doctor -Context $Context }
        default { throw "Unknown command: $Command" }
    }
}

function Show-StandaloneSwitchPlan([object]$Context, [string]$ProfileName, [switch]$AsJson) {
    $plan = Get-AutomaticSwitchPlan -Context $Context $ProfileName
    if ($AsJson) { $plan | ConvertTo-Json -Depth 8; return }
    Write-Host 'Standalone switch plan (read-only)' -ForegroundColor Cyan
    if ($plan.TargetProfile) {
        Write-Host "Target: $($plan.TargetProfile.Name); saved file exists: $($plan.TargetProfile.Exists); authentication not checked"
    }
    Write-Host "Status: $($plan.Status)"
    foreach ($blocker in $plan.Blockers) { Write-Host "  Blocked PID $($blocker.ClientId): $($blocker.Reason)" -ForegroundColor Yellow }
    foreach ($target in $plan.RestartTargets) { Write-Host "  $($target.Mechanism): $($target.Name) (PID $($target.Id))" }
    Write-Host "Detected runtimes: $($plan.Clients.Count); related processes: $($plan.RelatedProcesses.Count)"
    foreach ($client in $plan.Clients) {
        Write-Host "`n$($client.Environment) / $($client.Mode): $($client.ProcessName) (PID: $($client.Id))"
        Write-Host ('  Chain: ' + (($client.Ancestry | ForEach-Object { "$($_.Name) [$($_.Id)]" }) -join ' <- '))
        Write-Host "  Ancestry: $($client.AncestryState)"
    }
    Write-Host "`nRecovery requirements (apply to every detected runtime):"
    foreach ($requirement in $plan.RecoveryRequirements) { Write-Host "- $requirement" }
    Write-Host "`nNo applications were stopped, restarted, or reconfigured. No authentication files were changed."
    foreach ($limitation in $plan.Coverage) { Write-Host "- $limitation" -ForegroundColor DarkGray }
}

function Wait-CodexClientsStopped([object]$Context) {
    while ($true) {
        $running = @(Get-CodexClientProcesses -Context $Context)
        if ($running.Count -eq 0) { return $true }
        Write-Host ''
        Write-Host 'Codex clients are still running.' -ForegroundColor Yellow
        foreach ($client in $running) { Write-Host "  $(Get-CodexClientDescription $client)" }
        Write-Host 'Close the listed apps or their Codex extension completely.'
        $answer = Read-Host 'After closing it, press Enter to retry (or type C to cancel)'
        if ($answer -match '^[Cc]$') {
            Write-Host 'Canceled.' -ForegroundColor Yellow
            return $false
        }
    }
}

function Register-CurrentInteractive($Context) {
    $view = Get-RegistrationView $Context
    if (-not $view.Current) { Write-Host 'No current Codex login was found.' -ForegroundColor Yellow; return }
    Write-Host "Current account: $($view.Current.Email)" -ForegroundColor Cyan
    $name = Read-Host 'Save this account as profile'
    $lock=Enter-SwitchLock
    try { $view = Get-RegistrationView $Context $name } finally { Exit-SwitchLock $lock }
    if ($view.Existing) {
        if ($view.Existing.IdentityKey -eq $view.Current.IdentityKey) {
            Write-Host "Profile '$name' already contains this account; refreshing it." -ForegroundColor Yellow
        } elseif ((Read-Host "Profile '$name' already exists. Overwrite it? (y/N)") -notmatch '^[Yy]') {
            Write-Host 'Canceled.' -ForegroundColor Yellow; return
        }
    }
    Invoke-CodexSwitchCommand -Context $Context -Command save -Name $name
    Write-Host 'The currently signed-in Codex account is now registered. No additional login is required.' -ForegroundColor Green
}

function Show-WhoAmI($Context) {
    $view = Get-AccountView $Context
    if (-not $view.Summary) { Write-Host 'Codex is not currently logged in.' -ForegroundColor Yellow; return }
    if ($view.Stale) { Write-Warning "The current login differs from saved active profile '$($view.RecordedProfile)'. Showing the account in auth.json." }
    $active = if ($view.MatchingProfile) { $view.MatchingProfile } else { '(not assigned)' }
    Write-Host "Profile: $active"
    Write-Host "Account: $($view.Summary.Email)"
    Write-Host "Method:  $($view.Summary.AuthMode)"
    if ($view.Summary.AccountSuffix) { Write-Host "ID tail: ...$($view.Summary.AccountSuffix)" }
}

function Show-List($Context) {
    $profiles = @(Get-ProfileViews $Context)
    if ($profiles.Count -eq 0) { Write-Host 'No saved profiles.'; return }
    foreach ($profile in $profiles) {
        $mark = if ($profile.Current) { '*' } else { ' ' }
        Write-Host "$mark $($profile.Name)`t$($profile.Email)"
    }
    Write-Host '* = current auth file; already-running sessions may still use an earlier login.' -ForegroundColor DarkGray
}

function Show-Help {
    @'
Codex Switch
  codexSwitch whoami
  codexSwitch list
  codexSwitch add <name>             Sign in and save a new account
  codexSwitch save <name>            Save the current login
  codexSwitch switch <name>          Switch and restart eligible applications
  codexSwitch switch <name> -Manual  Require clients to be closed beforehand
  codexSwitch status [-Json]        Last automatic restart operation
  codexSwitch rename <old> <new>
  codexSwitch remove <name>          Delete a saved profile
  codexSwitch delete <name>          Alias for remove
  codexSwitch files                  Open the profile data directory
  codexSwitch setup                  Configure reliable file-based auth storage
  codexSwitch doctor                 Check installation, paths, and login
  codexSwitch plan [name] [-Json]     Inspect restart readiness without changes
  codexSwitch                        Interactive menu
'@ | Write-Host
}

function Show-Doctor($Context) {
    $report = Get-DoctorReport $Context
    Write-Host "Codex executable: $(if ($report.Executable) { $report.Executable } else { 'NOT FOUND' })"
    Write-Host "CODEX_HOME:       $($Context.CodexHome)"
    Write-Host "Auth file:        $($Context.AuthPath) ($(if ($report.AuthExists) { 'found' } else { 'not found' }))"
    Write-Host "Credential store: $(if ($report.CredentialMode) { $report.CredentialMode } else { 'default/unspecified' })"
    Write-Host "Profile data:     $($Context.DataRoot)"
    Write-Host "Registry:         $($Context.RegistryPath)"
    Write-Host "Codex clients:    $(if ($report.Clients.Count) { 'RUNNING - switch restarts clients automatically; save/add require clients to exit' } else { 'not running' })"
    foreach ($client in $report.Clients) { Write-Host "  $(Get-CodexClientDescription $client)" }
    foreach ($warning in $report.Warnings) { Write-Warning $warning }
    if ($report.Executable) { Invoke-CodexLogin -Context $Context -StatusOnly }
}

function Start-Menu([object]$Context) {
    while ($true) {
        try {
            Write-Host "`n=== Codex Switch ===" -ForegroundColor Cyan
            Invoke-CodexSwitchCommand -Context $Context -Command whoami
            Write-Host '1. Show current account'
            Write-Host '2. Rename a profile'
            Write-Host '3. List profiles / open data folder'
            Write-Host '4. Switch account'
            Write-Host '5. Add an account'
            Write-Host '6. Delete a profile'
            Write-Host '7. Register the currently signed-in account'
            Write-Host '8. Inspect automatic restart readiness (read-only)'
            Write-Host '0. Exit'
            switch (Read-Host 'Choose') {
                '1' { Invoke-CodexSwitchCommand -Context $Context -Command whoami }
                '2' { Invoke-CodexSwitchCommand -Context $Context -Command rename -Name (Read-Host 'Current name') -NewName (Read-Host 'New name') }
                '3' { Invoke-CodexSwitchCommand -Context $Context -Command list; if ((Read-Host 'Open the profile folder? (y/N)') -match '^[Yy]') { Start-Process explorer.exe $($Context.ProfilesDir) } }
                '4' { Invoke-CodexSwitchCommand -Context $Context -Command list; Invoke-CodexSwitchCommand -Context $Context -Command switch -Name (Read-Host 'Profile name') }
                '5' { if (Wait-CodexClientsStopped -Context $Context) { Invoke-CodexSwitchCommand -Context $Context -Command add -Name (Read-Host 'New profile name') } }
                '6' {
                    Invoke-CodexSwitchCommand -Context $Context -Command list
                    $profileName = Read-Host 'Profile name to delete'
                    if ((Read-Host "Permanently delete '$profileName'? (y/N)") -match '^[Yy]') {
                        Invoke-CodexSwitchCommand -Context $Context -Command remove -Name $profileName
                    } else {
                        Write-Host 'Canceled.' -ForegroundColor Yellow
                    }
                }
                '7' { if (Wait-CodexClientsStopped -Context $Context) { Register-CurrentInteractive -Context $Context } }
                '8' { Show-StandaloneSwitchPlan -Context $Context }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "Could not complete the action: $($_.Exception.Message)" -ForegroundColor Red
            Read-Host 'Press Enter to return to the menu' | Out-Null
        }
    }
}

Export-ModuleMember -Function Write-ConsoleNotice, Invoke-CodexSwitchCommand, Show-StandaloneSwitchPlan, Wait-CodexClientsStopped, Register-CurrentInteractive, Show-WhoAmI, Show-List, Show-Help, Show-Doctor, Start-Menu
