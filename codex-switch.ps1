[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu','whoami','list','add','save','switch','rename','remove','delete','files','setup','doctor','help')]
    [string]$Command = 'menu',
    [Parameter(Position = 1)]
    [string]$Name,
    [Parameter(Position = 2)]
    [string]$NewName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataRoot = if ($env:CODEX_SWITCH_HOME) {
    $env:CODEX_SWITCH_HOME
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexSwitch'
} else {
    Join-Path $env:USERPROFILE '.codex-switch'
}
$ProfilesDir = Join-Path $DataRoot 'profiles'
$RegistryPath = Join-Path $DataRoot 'profiles.json'
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$AuthPath = Join-Path $CodexHome 'auth.json'
$ConfigPath = Join-Path $CodexHome 'config.toml'
. (Join-Path $ScriptRoot 'auth-check.ps1')

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-CredentialStoreSetting {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $config = Get-Content -Raw -LiteralPath $ConfigPath
    # Only a root setting applies globally; table-local settings must not hide it.
    $rootConfig = [regex]::new('(?m)^[\t ]*\[').Split($config, 2)[0]
    return [regex]::Match($rootConfig, '(?im)^[\t ]*cli_auth_credentials_store[\t ]*=[\t ]*["''](file|keyring|auto|ephemeral)["''][\t ]*(?:#[^\r\n]*)?\r?$')
}

function Get-CredentialStoreMode {
    $match = Get-CredentialStoreSetting
    if (-not $match) { return $null }
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Ensure-FileCredentialStore {
    Assert-CodexClientsStopped
    $currentMode = Get-CredentialStoreMode
    if ($currentMode -eq 'file') { return }

    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $original = if (Test-Path -LiteralPath $ConfigPath) {
        Get-Content -Raw -LiteralPath $ConfigPath
    } else {
        ''
    }

    if ($original) {
        $backupPath = "$ConfigPath.codex-switch.bak"
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $ConfigPath -Destination $backupPath
        }
    }

    $setting = Get-CredentialStoreSetting
    if ($setting -and $setting.Success) {
        $lineEnding = if ($setting.Value.EndsWith("`r")) { "`r" } else { '' }
        $updated = $original.Remove($setting.Index, $setting.Length).Insert(
            $setting.Index, 'cli_auth_credentials_store = "file"' + $lineEnding)
    } else {
        $separator = if ($original -and -not $original.StartsWith("`r") -and -not $original.StartsWith("`n")) { "`r`n`r`n" } else { '' }
        $updated = "cli_auth_credentials_store = `"file`"$separator$original"
    }

    $temp = "$ConfigPath.codex-switch.tmp"
    Write-Utf8NoBom $temp $updated
    Move-Item -Force -LiteralPath $temp -Destination $ConfigPath
    Write-Host 'Configured Codex to use file-based credentials for reliable profile switching.' -ForegroundColor Green
    if ($original) { Write-Host "Config backup: $ConfigPath.codex-switch.bak" -ForegroundColor DarkGray }
}

function Initialize-Store {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $ProfilesDir | Out-Null
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        Write-Utf8NoBom $RegistryPath "{`n  `"active`": null,`n  `"profiles`": {}`n}"
    }
    Import-LegacyStore
    Protect-Store
}

function Protect-Store {
    if ($env:OS -ne 'Windows_NT') { return }
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $DataRoot '/inheritance:r' '/grant:r' "*$sid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    } catch {
        Write-Warning "Could not restrict permissions on $DataRoot"
    }
}

function Import-LegacyStore {
    $legacyRegistry = Join-Path $ScriptRoot 'profiles.json'
    $legacyProfiles = Join-Path $ScriptRoot 'profiles'
    if ((Test-Path -LiteralPath $legacyRegistry) -and
        ((Get-Item -LiteralPath $legacyRegistry).FullName -ne (Get-Item -LiteralPath $RegistryPath).FullName) -and
        ((Get-Item -LiteralPath $RegistryPath).Length -le 40)) {
        Copy-Item -Force -LiteralPath $legacyRegistry -Destination $RegistryPath
        if (Test-Path -LiteralPath $legacyProfiles) {
            Get-ChildItem -File -LiteralPath $legacyProfiles | Copy-Item -Force -Destination $ProfilesDir
        }
        Write-Host "Imported profiles from the legacy repository-local store." -ForegroundColor Yellow
    }
}

function Read-Registry {
    Initialize-Store
    $registry = Get-Content -Raw -LiteralPath $RegistryPath | ConvertFrom-Json
    $changed = $false

    foreach ($property in @($registry.profiles.PSObject.Properties)) {
        if (-not (Test-Path -LiteralPath (Get-ProfilePath $property.Name))) {
            $registry.profiles.PSObject.Properties.Remove($property.Name)
            if ($registry.active -eq $property.Name) { $registry.active = $null }
            $changed = $true
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $ProfilesDir -File -Filter '*.auth.json' -ErrorAction SilentlyContinue)) {
        $profileName = $file.Name.Substring(0, $file.Name.Length - '.auth.json'.Length)
        if ($profileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' -or
            $registry.profiles.PSObject.Properties[$profileName]) { continue }
        $summary = Get-AuthSummary $file.FullName
        if (-not $summary) { continue }
        $entry = [pscustomobject]@{
            file = $file.Name
            email = $summary.Email
            updated = $file.LastWriteTime.ToString('o')
        }
        $registry.profiles | Add-Member -NotePropertyName $profileName -NotePropertyValue $entry
        $changed = $true
    }

    if ($changed) { Write-Registry $registry }
    return $registry
}

function Write-Registry([object]$Registry) {
    $temp = "$RegistryPath.tmp"
    Write-Utf8NoBom $temp ($Registry | ConvertTo-Json -Depth 6)
    Move-Item -Force -LiteralPath $temp -Destination $RegistryPath
}

function Assert-ProfileName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$') {
        throw 'Profile names must be 1-40 characters, start with a letter or number, and contain only letters, numbers, dots, underscores, or hyphens.'
    }
}

function Get-ProfilePath([string]$ProfileName) {
    return Join-Path $ProfilesDir "$ProfileName.auth.json"
}

function Decode-JwtPayload([string]$Token) {
    try {
        $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    } catch { return $null }
}

function Get-AuthSummary([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $auth = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $claims = $null
    if ($auth.tokens -and $auth.tokens.id_token) { $claims = Decode-JwtPayload $auth.tokens.id_token }
    $email = if ($claims -and $claims.email) { [string]$claims.email } else { '(email unavailable)' }
    $accountId = if ($auth.tokens -and $auth.tokens.account_id) { [string]$auth.tokens.account_id } else { '' }
    $userId = if ($claims -and $claims.sub) { [string]$claims.sub } else { '' }
    $identityKey = if ($accountId) {
        "account:$accountId"
    } elseif ($userId) {
        "user:$userId"
    } elseif ($email -ne '(email unavailable)') {
        "email:$($email.ToLowerInvariant())"
    } else {
        ''
    }
    $suffix = if ($accountId.Length -gt 8) { $accountId.Substring($accountId.Length - 8) } else { $accountId }
    return [pscustomobject]@{
        Email = $email
        AccountSuffix = $suffix
        AuthMode = [string]$auth.auth_mode
        IdentityKey = $identityKey
    }
}

function Test-SameAuthIdentity([string]$FirstPath, [string]$SecondPath) {
    $first = Get-AuthSummary $FirstPath
    $second = Get-AuthSummary $SecondPath
    return ($first -and $second -and $first.IdentityKey -and ($first.IdentityKey -eq $second.IdentityKey))
}

function Get-MatchingProfileName([string]$Path, [object]$Registry) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $current = Get-AuthSummary $Path
    if (-not $current -or -not $current.IdentityKey) { return $null }

    $matches = @($Registry.profiles.PSObject.Properties | Where-Object {
        $profileSummary = Get-AuthSummary (Get-ProfilePath $_.Name)
        $profileSummary -and ($profileSummary.IdentityKey -eq $current.IdentityKey)
    } | ForEach-Object { $_.Name })
    if ($Registry.active -and $matches -contains [string]$Registry.active) { return [string]$Registry.active }
    return $matches | Select-Object -First 1
}

function Get-CodexClientProcesses {
    if ($env:CODEX_SWITCH_TEST_SKIP_APP_CHECK -eq '1') { return @() }
    $processes = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate -ErrorAction Stop)
    $byId = @{}
    foreach ($process in $processes) { $byId[[int]$process.ProcessId] = $process }
    foreach ($process in $processes) {
        $path = [string]$process.ExecutablePath
        $isDesktop = $process.Name -ieq 'ChatGPT.exe' -and
            (-not $path -or $path -match '[\\/]WindowsApps[\\/]OpenAI\.(Codex|ChatGPT)_')
        if ($process.Name -ine 'codex.exe' -and -not $isDesktop) { continue }
        $parent = $byId[[int]$process.ParentProcessId]
        # An exited parent's PID may have been reused by an unrelated process.
        $parentName = if ($parent -and $parent.CreationDate -and $process.CreationDate -and
            $parent.CreationDate -le $process.CreationDate) { [string]$parent.Name } else { '' }
        [pscustomobject]@{
            Id = [int]$process.ProcessId
            ProcessName = [string]$process.Name
            Path = $path
            ParentId = [int]$process.ParentProcessId
            ParentName = $parentName
        }
    }
}

function Get-CodexClientDescription([object]$Client) {
    $description = "$($Client.ProcessName) (PID: $($Client.Id))"
    if ($Client.ParentName) {
        $description += "; parent: $($Client.ParentName) (PID: $($Client.ParentId))"
    } elseif ($Client.ParentId) {
        $description += "; parent PID: $($Client.ParentId) (exited or unavailable)"
    }
    if ($Client.Path) { $description += " - $($Client.Path)" }
    return $description
}

function Assert-CodexClientsStopped {
    $running = @(Get-CodexClientProcesses)
    if ($running.Count -eq 0) { return }
    $details = ($running | Sort-Object Id | ForEach-Object { Get-CodexClientDescription $_ }) -join "`n  "
    throw "Codex clients are still running:`n  $details`nClose the listed apps or their Codex extension completely, then retry. Existing processes can keep the old login and write it back to auth.json."
}

function Wait-CodexClientsStopped {
    while ($true) {
        $running = @(Get-CodexClientProcesses)
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

function Save-Current([string]$ProfileName, [switch]$SetActive) {
    Assert-ProfileName $ProfileName
    Ensure-FileCredentialStore
    if (-not (Test-Path -LiteralPath $AuthPath)) { throw "Codex auth file not found: $AuthPath" }
    $registry = Read-Registry
    $destination = Get-ProfilePath $ProfileName
    Copy-Item -Force -LiteralPath $AuthPath -Destination $destination
    $summary = Get-AuthSummary $destination
    $entry = [pscustomobject]@{
        file = [IO.Path]::GetFileName($destination)
        email = $summary.Email
        updated = (Get-Date).ToString('o')
    }
    $registry.profiles | Add-Member -Force -NotePropertyName $ProfileName -NotePropertyValue $entry
    if ($SetActive) { $registry.active = $ProfileName }
    Write-Registry $registry
    Write-Host "Saved: $ProfileName ($($summary.Email))" -ForegroundColor Green
}

function Register-CurrentInteractive {
    $summary = Get-AuthSummary $AuthPath
    if (-not $summary) {
        Write-Host 'No current Codex login was found.' -ForegroundColor Yellow
        return
    }

    Write-Host "Current account: $($summary.Email)" -ForegroundColor Cyan
    $profileName = Read-Host 'Save this account as profile'
    Assert-ProfileName $profileName
    $registry = Read-Registry
    if ($registry.profiles.PSObject.Properties[$profileName]) {
        $existing = Get-AuthSummary (Get-ProfilePath $profileName)
        if ($existing -and $existing.IdentityKey -eq $summary.IdentityKey) {
            Write-Host "Profile '$profileName' already contains this account; refreshing it." -ForegroundColor Yellow
        } elseif ((Read-Host "Profile '$profileName' already exists. Overwrite it? (y/N)") -notmatch '^[Yy]') {
            Write-Host 'Canceled.' -ForegroundColor Yellow
            return
        }
    }
    Save-Current $profileName -SetActive
    Write-Host 'The currently signed-in Codex account is now registered. No additional login is required.' -ForegroundColor Green
}

function Show-WhoAmI {
    $registry = Read-Registry
    $summary = Get-AuthSummary $AuthPath
    if (-not $summary) { Write-Host 'Codex is not currently logged in.' -ForegroundColor Yellow; return }
    $matchingName = Get-MatchingProfileName $AuthPath $registry
    $active = if ($matchingName) { $matchingName } else { '(not assigned)' }
    if ($registry.active) {
        $candidate = [string]$registry.active
        $profilePath = Get-ProfilePath $candidate
        if (-not ((Test-Path -LiteralPath $profilePath) -and (Test-SameAuthIdentity $AuthPath $profilePath))) {
            Write-Warning "The current login differs from saved active profile '$candidate'. Showing the account in auth.json."
        }
    }
    Write-Host "Profile: $active"
    Write-Host "Account: $($summary.Email)"
    Write-Host "Method:  $($summary.AuthMode)"
    if ($summary.AccountSuffix) { Write-Host "ID tail: ...$($summary.AccountSuffix)" }
}

function Show-List {
    $registry = Read-Registry
    $names = @($registry.profiles.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    if ($names.Count -eq 0) { Write-Host 'No saved profiles.'; return }
    $matchingName = Get-MatchingProfileName $AuthPath $registry
    foreach ($profileName in $names) {
        $entry = $registry.profiles.$profileName
        $mark = if ($matchingName -eq $profileName) { '*' } else { ' ' }
        Write-Host "$mark $profileName`t$($entry.email)"
    }
    Write-Host '* = current auth file; already-running sessions may still use an earlier login.' -ForegroundColor DarkGray
}

function Switch-Profile([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    Assert-CodexClientsStopped
    Ensure-FileCredentialStore
    $registry = Read-Registry
    $property = $registry.profiles.PSObject.Properties[$ProfileName]
    if (-not $property) { throw "Profile not found: $ProfileName" }
    if (Test-Path -LiteralPath $AuthPath) {
        $activeName = [string]$registry.active
        $matchingName = Get-MatchingProfileName $AuthPath $registry
        if ($activeName -and $matchingName -ne $activeName) {
            Write-Warning "The current Codex login does not match the saved active profile '$activeName'. It was not written over that profile."
        }
        if ($matchingName) {
            # Preserve refreshed tokens even when the recorded active name is stale.
            Save-Current $matchingName
        } else {
            $backupName = 'recovered-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Save-Current $backupName
            Write-Host "The current login was preserved as: $backupName" -ForegroundColor Yellow
        }
        $registry = Read-Registry
    }
    $source = Get-ProfilePath $ProfileName
    if (-not (Test-Path -LiteralPath $source)) { throw "Profile file not found: $source" }
    Write-Host "Checking saved login: $ProfileName" -ForegroundColor Cyan
    $currentHash = if (Test-Path -LiteralPath $AuthPath) { (Get-FileHash -LiteralPath $AuthPath -Algorithm SHA256).Hash } else { '' }
    try {
        Confirm-CodexProfileAuth $source
    } finally {
        # A same-account refresh can rotate tokens before a later network check
        # fails. Keep that account's current file in sync without switching users.
        if ($currentHash -and (Test-Path -LiteralPath $AuthPath) -and
            (Get-FileHash -LiteralPath $AuthPath -Algorithm SHA256).Hash -eq $currentHash -and
            (Test-SameAuthIdentity $AuthPath $source)) {
            Copy-Item -LiteralPath $source -Destination "$AuthPath.switching" -Force
            Move-Item -LiteralPath "$AuthPath.switching" -Destination $AuthPath -Force
        }
    }
    Assert-CodexClientsStopped
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $temp = "$AuthPath.switching"
    Copy-Item -Force -LiteralPath $source -Destination $temp
    Move-Item -Force -LiteralPath $temp -Destination $AuthPath
    $registry.active = $ProfileName
    Write-Registry $registry
    Write-Host "Switched to: $ProfileName" -ForegroundColor Green
    Show-WhoAmI
    Write-Host 'Reopen Codex Desktop, CLI sessions, or your IDE to use the selected account.' -ForegroundColor Yellow
}

function Add-Account([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    Assert-CodexClientsStopped
    Ensure-FileCredentialStore
    $registry = Read-Registry
    if (Test-Path -LiteralPath $AuthPath) {
        $matchingName = Get-MatchingProfileName $AuthPath $registry
        if ($matchingName) {
            Save-Current $matchingName -SetActive
        } else {
            $profileCount = @($registry.profiles.PSObject.Properties | ForEach-Object { $_.Name }).Count
            $prefix = if ($profileCount -eq 0) { 'previous-' } else { 'recovered-' }
            $backupName = $prefix + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Save-Current $backupName -SetActive
            Write-Host "The current login was preserved once as: $backupName" -ForegroundColor Yellow
        }
    }
    $pendingAuth = $null
    if (Test-Path -LiteralPath $AuthPath) {
        $pendingAuth = Join-Path $DataRoot ("auth-before-add-{0}.json" -f [guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $AuthPath -Destination $pendingAuth
    }

    try {
        Write-Host 'Sign in to the Codex account you want to add in the browser.' -ForegroundColor Cyan
        Write-Host 'The previous local login was set aside without calling codex logout.' -ForegroundColor DarkGray
        & codex login -c 'cli_auth_credentials_store="file"'
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $AuthPath)) { throw 'Codex login did not complete.' }
        Save-Current $ProfileName -SetActive
        if ($pendingAuth -and (Test-Path -LiteralPath $pendingAuth)) {
            Remove-Item -LiteralPath $pendingAuth
        }
    } catch {
        if (Test-Path -LiteralPath $AuthPath) { Remove-Item -LiteralPath $AuthPath }
        if ($pendingAuth -and (Test-Path -LiteralPath $pendingAuth)) {
            Move-Item -LiteralPath $pendingAuth -Destination $AuthPath
            Write-Warning 'The new login failed, so the previous Codex login was restored.'
        }
        throw
    }
}

function Rename-Profile([string]$Old, [string]$New) {
    Assert-ProfileName $Old; Assert-ProfileName $New
    $registry = Read-Registry
    if (-not $registry.profiles.PSObject.Properties[$Old]) { throw "Profile not found: $Old" }
    if ($registry.profiles.PSObject.Properties[$New]) { throw "Profile already exists: $New" }
    Move-Item -LiteralPath (Get-ProfilePath $Old) -Destination (Get-ProfilePath $New)
    $entry = $registry.profiles.$Old
    $entry.file = "$New.auth.json"
    $registry.profiles | Add-Member -Force -NotePropertyName $New -NotePropertyValue $entry
    $registry.profiles.PSObject.Properties.Remove($Old)
    if ($registry.active -eq $Old) { $registry.active = $New }
    Write-Registry $registry
    Write-Host "Renamed: $Old -> $New" -ForegroundColor Green
}

function Remove-Profile([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    $registry = Read-Registry
    if (-not $registry.profiles.PSObject.Properties[$ProfileName]) { throw "Profile not found: $ProfileName" }
    $profilePath = Get-ProfilePath $ProfileName
    if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath }
    $registry.profiles.PSObject.Properties.Remove($ProfileName)
    if ($registry.active -eq $ProfileName) { $registry.active = $null }
    Write-Registry $registry
    Write-Host "Deleted permanently: $ProfileName" -ForegroundColor Yellow
}

function Show-Help {
    @'
Codex Switch
  codexSwitch whoami
  codexSwitch list
  codexSwitch add <name>             Sign in and save a new account
  codexSwitch save <name>            Save the current login
  codexSwitch switch <name>          Switch to a saved account
  codexSwitch rename <old> <new>
  codexSwitch remove <name>          Delete a saved profile
  codexSwitch delete <name>          Alias for remove
  codexSwitch files                  Open the profile data directory
  codexSwitch setup                  Configure reliable file-based auth storage
  codexSwitch doctor                 Check installation, paths, and login
  codexSwitch                        Interactive menu
'@ | Write-Host
}

function Show-Doctor {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    Write-Host "Codex executable: $(if ($codex) { $codex.Source } else { 'NOT FOUND' })"
    Write-Host "CODEX_HOME:       $CodexHome"
    Write-Host "Auth file:        $AuthPath ($(if (Test-Path -LiteralPath $AuthPath) { 'found' } else { 'not found' }))"
    $credentialMode = Get-CredentialStoreMode
    Write-Host "Credential store: $(if ($credentialMode) { $credentialMode } else { 'default/unspecified' })"
    Write-Host "Profile data:     $DataRoot"
    Write-Host "Registry:         $RegistryPath"
    $clientProcesses = @(Get-CodexClientProcesses)
    Write-Host "Codex clients:    $(if ($clientProcesses.Count) { 'RUNNING - close Desktop, CLI, and IDE sessions before save/add/switch' } else { 'not running' })"
    if ($clientProcesses.Count) {
        foreach ($client in $clientProcesses) { Write-Host "  $(Get-CodexClientDescription $client)" }
    }
    $registry = Read-Registry
    if ($credentialMode -ne 'file') {
        Write-Warning 'Reliable switching requires file-based credentials. Close all Codex clients and run: codexSwitch setup'
    }
    if ($registry.active -and (Test-Path -LiteralPath $AuthPath)) {
        $activePath = Get-ProfilePath ([string]$registry.active)
        if (-not (Test-Path -LiteralPath $activePath)) {
            Write-Warning "The active profile file is missing: $($registry.active)"
        } elseif (-not (Test-SameAuthIdentity $AuthPath $activePath)) {
            Write-Warning "The current Codex login does not match the saved active profile '$($registry.active)'."
        }
    }
    $identityOwners = @{}
    foreach ($profileProperty in $registry.profiles.PSObject.Properties) {
        $profilePath = Get-ProfilePath $profileProperty.Name
        $summary = Get-AuthSummary $profilePath
        if (-not $summary -or -not $summary.IdentityKey) { continue }
        if (-not $identityOwners.ContainsKey($summary.IdentityKey)) { $identityOwners[$summary.IdentityKey] = @() }
        $identityOwners[$summary.IdentityKey] += $profileProperty.Name
    }
    foreach ($owners in $identityOwners.Values) {
        if ($owners.Count -gt 1) {
            Write-Warning "These profiles contain the same Codex account: $($owners -join ', ')"
        }
    }
    if ($codex) { & codex login status }
}

function Start-Menu {
    while ($true) {
        try {
            Write-Host "`n=== Codex Switch ===" -ForegroundColor Cyan
            Show-WhoAmI
            Write-Host '1. Show current account'
            Write-Host '2. Rename a profile'
            Write-Host '3. List profiles / open data folder'
            Write-Host '4. Switch account'
            Write-Host '5. Add an account'
            Write-Host '6. Delete a profile'
            Write-Host '7. Register the currently signed-in account'
            Write-Host '0. Exit'
            switch (Read-Host 'Choose') {
                '1' { Show-WhoAmI }
                '2' { Rename-Profile (Read-Host 'Current name') (Read-Host 'New name') }
                '3' { Show-List; if ((Read-Host 'Open the profile folder? (y/N)') -match '^[Yy]') { Start-Process explorer.exe $ProfilesDir } }
                '4' { Show-List; if (Wait-CodexClientsStopped) { Switch-Profile (Read-Host 'Profile name') } }
                '5' { if (Wait-CodexClientsStopped) { Add-Account (Read-Host 'New profile name') } }
                '6' {
                    Show-List
                    $profileName = Read-Host 'Profile name to delete'
                    if ((Read-Host "Permanently delete '$profileName'? (y/N)") -match '^[Yy]') {
                        Remove-Profile $profileName
                    } else {
                        Write-Host 'Canceled.' -ForegroundColor Yellow
                    }
                }
                '7' { if (Wait-CodexClientsStopped) { Register-CurrentInteractive } }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "Could not complete the action: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

try {
    Initialize-Store
    switch ($Command) {
        'menu'   { Start-Menu }
        'whoami' { Show-WhoAmI }
        'list'   { Show-List }
        'add'    { Add-Account $Name }
        'save'   { Save-Current $Name -SetActive }
        'switch' { Switch-Profile $Name }
        'rename' { Rename-Profile $Name $NewName }
        'remove' { Remove-Profile $Name }
        'delete' { Remove-Profile $Name }
        'files'  { Start-Process explorer.exe $ProfilesDir; Write-Host $ProfilesDir }
        'setup'  { Ensure-FileCredentialStore }
        'doctor' { Show-Doctor }
        'help'   { Show-Help }
    }
} catch {
    Write-Host ''
    Write-Host "Could not complete the command: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
