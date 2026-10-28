Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Send-SwitchNotice($Context, [string]$Message, [string]$ForegroundColor = 'Gray', [switch]$Warning) {
    & $Context.Report $Message $ForegroundColor ([bool]$Warning)
}

function Write-SwitchOperation($Context, $Operation) {
    $Operation.UpdatedAt=[datetime]::UtcNow.ToString('o')
    $path = Join-Path $Context.DataRoot 'last-operation.json'
    Write-Utf8NoBom "$path.tmp" ($Operation | ConvertTo-Json -Depth 5)
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

function Read-SwitchOperation($Context) {
    $path = Join-Path $Context.DataRoot 'last-operation.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
    return $null
}

function Enter-SwitchLock {
    $mutex = [Threading.Mutex]::new($false, 'Local\CodexSwitch.AccountOperations')
    try {
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'Another Codex Switch command is running. Wait for it to finish.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-SwitchLock($Mutex) {
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-CredentialStoreSetting([object]$Context) {
    if (-not (Test-Path -LiteralPath $($Context.ConfigPath))) { return $null }
    $config = Get-Content -Raw -LiteralPath $($Context.ConfigPath)
    # Only a root setting applies globally; table-local settings must not hide it.
    $rootConfig = [regex]::new('(?m)^[\t ]*\[').Split($config, 2)[0]
    return [regex]::Match($rootConfig, '(?im)^[\t ]*cli_auth_credentials_store[\t ]*=[\t ]*["''](file|keyring|auto|ephemeral)["''][\t ]*(?:#[^\r\n]*)?\r?$')
}

function Get-CredentialStoreMode([object]$Context) {
    $match = Get-CredentialStoreSetting -Context $Context
    if (-not $match) { return $null }
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Set-FileCredentialStore([object]$Context) {
    $currentMode = Get-CredentialStoreMode -Context $Context
    if ($currentMode -eq 'file') { return }

    New-Item -ItemType Directory -Force -Path $($Context.CodexHome) | Out-Null
    $original = if (Test-Path -LiteralPath $($Context.ConfigPath)) {
        Get-Content -Raw -LiteralPath $($Context.ConfigPath)
    } else {
        ''
    }

    if ($original) {
        $backupPath = "$($Context.ConfigPath).codex-switch.bak"
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $($Context.ConfigPath) -Destination $backupPath
        }
    }

    $setting = Get-CredentialStoreSetting -Context $Context
    if ($setting -and $setting.Success) {
        $lineEnding = if ($setting.Value.EndsWith("`r")) { "`r" } else { '' }
        $updated = $original.Remove($setting.Index, $setting.Length).Insert(
            $setting.Index, 'cli_auth_credentials_store = "file"' + $lineEnding)
    } else {
        $separator = if ($original -and -not $original.StartsWith("`r") -and -not $original.StartsWith("`n")) { "`r`n`r`n" } else { '' }
        $updated = "cli_auth_credentials_store = `"file`"$separator$original"
    }

    $temp = "$($Context.ConfigPath).codex-switch.tmp"
    Write-Utf8NoBom $temp $updated
    Move-Item -Force -LiteralPath $temp -Destination $($Context.ConfigPath)
    Send-SwitchNotice -Context $Context 'Configured Codex to use file-based credentials for reliable profile switching.' -ForegroundColor Green
    if ($original) { Send-SwitchNotice -Context $Context "Config backup: $($Context.ConfigPath).codex-switch.bak" -ForegroundColor DarkGray }
}

function Initialize-Store([object]$Context) {
    New-Item -ItemType Directory -Force -Path $($Context.DataRoot) | Out-Null
    New-Item -ItemType Directory -Force -Path $($Context.ProfilesDir) | Out-Null
    if (-not (Test-Path -LiteralPath $($Context.RegistryPath))) {
        Write-Utf8NoBom $($Context.RegistryPath) "{`n  `"active`": null,`n  `"profiles`": {}`n}"
    }
    Import-LegacyStore -Context $Context
    Protect-Store -Context $Context
}

function Protect-Store([object]$Context) {
    if (-not $Context.IsWindows) { return }
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $($Context.DataRoot) '/inheritance:r' '/grant:r' "*$sid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    } catch {
        Send-SwitchNotice -Context $Context -Warning "Could not restrict permissions on $($Context.DataRoot)"
    }
}

function Import-LegacyStore([object]$Context) {
    $legacyRegistry = Join-Path $($Context.ScriptRoot) 'profiles.json'
    $legacyProfiles = Join-Path $($Context.ScriptRoot) 'profiles'
    if ((Test-Path -LiteralPath $legacyRegistry) -and
        ((Get-Item -LiteralPath $legacyRegistry).FullName -ne (Get-Item -LiteralPath $($Context.RegistryPath)).FullName) -and
        ((Get-Item -LiteralPath $($Context.RegistryPath)).Length -le 40)) {
        Copy-Item -Force -LiteralPath $legacyRegistry -Destination $($Context.RegistryPath)
        if (Test-Path -LiteralPath $legacyProfiles) {
            Get-ChildItem -File -LiteralPath $legacyProfiles | Copy-Item -Force -Destination $($Context.ProfilesDir)
        }
        Send-SwitchNotice -Context $Context "Imported profiles from the legacy repository-local store." -ForegroundColor Yellow
    }
}

function Read-Registry([object]$Context) {
    Initialize-Store -Context $Context
    $registry = Get-Content -Raw -LiteralPath $($Context.RegistryPath) | ConvertFrom-Json
    $changed = $false

    foreach ($property in @($registry.profiles.PSObject.Properties)) {
        if (-not (Test-Path -LiteralPath (Get-ProfilePath -Context $Context $property.Name))) {
            $registry.profiles.PSObject.Properties.Remove($property.Name)
            if ($registry.active -eq $property.Name) { $registry.active = $null }
            $changed = $true
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $($Context.ProfilesDir) -File -Filter '*.auth.json' -ErrorAction SilentlyContinue)) {
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

    if ($changed) { Write-Registry -Context $Context $registry }
    return $registry
}

function Write-Registry([object]$Context, [object]$Registry) {
    $temp = "$($Context.RegistryPath).tmp"
    Write-Utf8NoBom $temp ($Registry | ConvertTo-Json -Depth 6)
    Move-Item -Force -LiteralPath $temp -Destination $($Context.RegistryPath)
}

function Assert-ProfileName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$') {
        throw 'Profile names must be 1-40 characters, start with a letter or number, and contain only letters, numbers, dots, underscores, or hyphens.'
    }
}

function Get-ProfilePath([object]$Context, [string]$ProfileName) {
    Assert-ProfileName $ProfileName
    return Join-Path $($Context.ProfilesDir) "$ProfileName.auth.json"
}

function Test-CurrentAuth($Context) {
    return Test-Path -LiteralPath $Context.AuthPath -PathType Leaf
}

function Get-ProfileObservation($Context, [string]$ProfileName) {
    $path = Get-ProfilePath -Context $Context -ProfileName $ProfileName
    return [pscustomobject]@{
        Name=$ProfileName
        Exists=(Test-Path -LiteralPath $path -PathType Leaf)
        AuthenticationChecked=$false
    }
}

function Get-CurrentAuthHash($Context) {
    if (Test-CurrentAuth $Context) { return (Get-FileHash -LiteralPath $Context.AuthPath -Algorithm SHA256).Hash }
    return ''
}

function Set-CurrentAuthFromProfile($Context, [string]$ProfileName) {
    $source = Get-ProfilePath -Context $Context -ProfileName $ProfileName
    New-Item -ItemType Directory -Force -Path $Context.CodexHome | Out-Null
    $temp = "$($Context.AuthPath).switching"
    Copy-Item -LiteralPath $source -Destination $temp -Force
    Move-Item -LiteralPath $temp -Destination $Context.AuthPath -Force
}

function Sync-RefreshedCurrentAuth($Context, [string]$ProfileName, [string]$PreviousHash) {
    $source = Get-ProfilePath -Context $Context -ProfileName $ProfileName
    if ($PreviousHash -and (Get-CurrentAuthHash $Context) -eq $PreviousHash -and
        (Test-SameAuthIdentity $Context.AuthPath $source)) {
        Set-CurrentAuthFromProfile $Context $ProfileName
    }
}

function Suspend-CurrentAuth($Context) {
    if (-not (Test-CurrentAuth $Context)) { return $null }
    $pending = Join-Path $Context.DataRoot ('auth-before-add-' + [guid]::NewGuid().ToString('N') + '.json')
    Move-Item -LiteralPath $Context.AuthPath -Destination $pending
    return $pending
}

function Complete-AuthRegistration($Context, [string]$PendingAuth, [switch]$Rollback) {
    if ($Rollback -and (Test-CurrentAuth $Context)) { Remove-Item -LiteralPath $Context.AuthPath }
    if ($PendingAuth -and (Test-Path -LiteralPath $PendingAuth)) {
        if ($Rollback) {
            Move-Item -LiteralPath $PendingAuth -Destination $Context.AuthPath
            Send-SwitchNotice -Context $Context -Warning 'The new login failed, so the previous Codex login was restored.'
        } else { Remove-Item -LiteralPath $PendingAuth }
    }
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

function Get-MatchingProfileName([object]$Context, [string]$Path, [object]$Registry) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $current = Get-AuthSummary $Path
    if (-not $current -or -not $current.IdentityKey) { return $null }

    $matches = @($Registry.profiles.PSObject.Properties | Where-Object {
        $profileSummary = Get-AuthSummary (Get-ProfilePath -Context $Context $_.Name)
        $profileSummary -and ($profileSummary.IdentityKey -eq $current.IdentityKey)
    } | ForEach-Object { $_.Name })
    if ($Registry.active -and $matches -contains [string]$Registry.active) { return [string]$Registry.active }
    return $matches | Select-Object -First 1
}


function Write-CurrentProfile([object]$Context, [string]$ProfileName, [switch]$SetActive) {
    Assert-ProfileName $ProfileName
    if (-not (Test-Path -LiteralPath $($Context.AuthPath))) { throw "Codex auth file not found: $($Context.AuthPath)" }
    $registry = Read-Registry -Context $Context
    $destination = Get-ProfilePath -Context $Context $ProfileName
    Copy-Item -Force -LiteralPath $($Context.AuthPath) -Destination $destination
    $summary = Get-AuthSummary $destination
    $entry = [pscustomobject]@{
        file = [IO.Path]::GetFileName($destination)
        email = $summary.Email
        updated = (Get-Date).ToString('o')
    }
    $registry.profiles | Add-Member -Force -NotePropertyName $ProfileName -NotePropertyValue $entry
    if ($SetActive) { $registry.active = $ProfileName }
    Write-Registry -Context $Context $registry
    Send-SwitchNotice -Context $Context "Saved: $ProfileName ($($summary.Email))" -ForegroundColor Green
}


function Rename-StoredProfile([object]$Context, [string]$Old, [string]$New) {
    Assert-ProfileName $Old; Assert-ProfileName $New
    $registry = Read-Registry -Context $Context
    if (-not $registry.profiles.PSObject.Properties[$Old]) { throw "Profile not found: $Old" }
    if ($registry.profiles.PSObject.Properties[$New]) { throw "Profile already exists: $New" }
    Move-Item -LiteralPath (Get-ProfilePath -Context $Context $Old) -Destination (Get-ProfilePath -Context $Context $New)
    $entry = $registry.profiles.$Old
    $entry.file = "$New.auth.json"
    $registry.profiles | Add-Member -Force -NotePropertyName $New -NotePropertyValue $entry
    $registry.profiles.PSObject.Properties.Remove($Old)
    if ($registry.active -eq $Old) { $registry.active = $New }
    Write-Registry -Context $Context $registry
    Send-SwitchNotice -Context $Context "Renamed: $Old -> $New" -ForegroundColor Green
}


function Remove-StoredProfile([object]$Context, [string]$ProfileName) {
    Assert-ProfileName $ProfileName
    $registry = Read-Registry -Context $Context
    if (-not $registry.profiles.PSObject.Properties[$ProfileName]) { throw "Profile not found: $ProfileName" }
    $profilePath = Get-ProfilePath -Context $Context $ProfileName
    if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath }
    $registry.profiles.PSObject.Properties.Remove($ProfileName)
    if ($registry.active -eq $ProfileName) { $registry.active = $null }
    Write-Registry -Context $Context $registry
    Send-SwitchNotice -Context $Context "Deleted permanently: $ProfileName" -ForegroundColor Yellow
}

Export-ModuleMember -Function Write-SwitchOperation, Read-SwitchOperation, Enter-SwitchLock, Exit-SwitchLock, Send-SwitchNotice, Write-Utf8NoBom, Get-CredentialStoreSetting, Get-CredentialStoreMode, Set-FileCredentialStore, Initialize-Store, Protect-Store, Import-LegacyStore, Read-Registry, Write-Registry, Assert-ProfileName, Get-ProfilePath, Test-CurrentAuth, Get-ProfileObservation, Get-CurrentAuthHash, Set-CurrentAuthFromProfile, Sync-RefreshedCurrentAuth, Suspend-CurrentAuth, Complete-AuthRegistration, Decode-JwtPayload, Get-AuthSummary, Test-SameAuthIdentity, Get-MatchingProfileName, Write-CurrentProfile, Rename-StoredProfile, Remove-StoredProfile
