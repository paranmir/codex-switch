[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu','whoami','list','add','save','switch','rename','remove','files','doctor','help')]
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

function Initialize-Store {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $ProfilesDir | Out-Null
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        Set-Content -LiteralPath $RegistryPath -Value "{`n  `"active`": null,`n  `"profiles`": {}`n}" -Encoding utf8NoBOM
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
    return Get-Content -Raw -LiteralPath $RegistryPath | ConvertFrom-Json
}

function Write-Registry([object]$Registry) {
    $temp = "$RegistryPath.tmp"
    $Registry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
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
    $suffix = if ($accountId.Length -gt 8) { $accountId.Substring($accountId.Length - 8) } else { $accountId }
    return [pscustomobject]@{ Email = $email; AccountSuffix = $suffix; AuthMode = [string]$auth.auth_mode }
}

function Save-Current([string]$ProfileName, [switch]$SetActive) {
    Assert-ProfileName $ProfileName
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

function Show-WhoAmI {
    $registry = Read-Registry
    $summary = Get-AuthSummary $AuthPath
    if (-not $summary) { Write-Host 'Codex is not currently logged in.' -ForegroundColor Yellow; return }
    $active = if ($registry.active) { [string]$registry.active } else { '(not assigned)' }
    Write-Host "Profile: $active"
    Write-Host "Account: $($summary.Email)"
    Write-Host "Method:  $($summary.AuthMode)"
    if ($summary.AccountSuffix) { Write-Host "ID tail: …$($summary.AccountSuffix)" }
}

function Show-List {
    $registry = Read-Registry
    $names = @($registry.profiles.PSObject.Properties.Name | Sort-Object)
    if ($names.Count -eq 0) { Write-Host 'No saved profiles.'; return }
    foreach ($profileName in $names) {
        $entry = $registry.profiles.$profileName
        $mark = if ($registry.active -eq $profileName) { '*' } else { ' ' }
        Write-Host "$mark $profileName`t$($entry.email)"
    }
}

function Switch-Profile([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    $registry = Read-Registry
    $property = $registry.profiles.PSObject.Properties[$ProfileName]
    if (-not $property) { throw "Profile not found: $ProfileName" }
    if ($registry.active -and (Test-Path -LiteralPath $AuthPath)) {
        Save-Current ([string]$registry.active)
        $registry = Read-Registry
    }
    $source = Get-ProfilePath $ProfileName
    if (-not (Test-Path -LiteralPath $source)) { throw "Profile file not found: $source" }
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $temp = "$AuthPath.switching"
    Copy-Item -Force -LiteralPath $source -Destination $temp
    Move-Item -Force -LiteralPath $temp -Destination $AuthPath
    $registry.active = $ProfileName
    Write-Registry $registry
    Write-Host "Switched to: $ProfileName" -ForegroundColor Green
    Show-WhoAmI
    Write-Host 'Restart open Codex Desktop/CLI sessions to ensure the new account is used.' -ForegroundColor Yellow
}

function Add-Account([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    $registry = Read-Registry
    if ($registry.active -and (Test-Path -LiteralPath $AuthPath)) {
        Save-Current ([string]$registry.active)
    } elseif (Test-Path -LiteralPath $AuthPath) {
        $backupName = 'previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Save-Current $backupName -SetActive
        Write-Host "The current login was preserved as: $backupName" -ForegroundColor Yellow
    }
    Write-Host 'Sign in to the Codex account you want to add in the browser.' -ForegroundColor Cyan
    & codex logout
    & codex login
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $AuthPath)) { throw 'Codex login did not complete.' }
    Save-Current $ProfileName -SetActive
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
    Remove-Item -LiteralPath (Get-ProfilePath $ProfileName)
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
  codexSwitch remove <name>
  codexSwitch files                  Open the profile data directory
  codexSwitch doctor                 Check installation, paths, and login
  codexSwitch                        Interactive menu
'@ | Write-Host
}

function Show-Doctor {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    Write-Host "Codex executable: $(if ($codex) { $codex.Source } else { 'NOT FOUND' })"
    Write-Host "CODEX_HOME:       $CodexHome"
    Write-Host "Auth file:        $AuthPath ($(if (Test-Path -LiteralPath $AuthPath) { 'found' } else { 'not found' }))"
    Write-Host "Profile data:     $DataRoot"
    Write-Host "Registry:         $RegistryPath"
    if ($codex) { & codex login status }
}

function Start-Menu {
    while ($true) {
        Write-Host "`n=== Codex Switch ===" -ForegroundColor Cyan
        Show-WhoAmI
        Write-Host '1. Show current account'
        Write-Host '2. Rename a profile'
        Write-Host '3. List profiles / open data folder'
        Write-Host '4. Switch account'
        Write-Host '5. Add an account'
        Write-Host '0. Exit'
        switch (Read-Host 'Choose') {
            '1' { Show-WhoAmI }
            '2' { Rename-Profile (Read-Host 'Current name') (Read-Host 'New name') }
            '3' { Show-List; if ((Read-Host 'Open the profile folder? (y/N)') -match '^[Yy]') { Start-Process explorer.exe $ProfilesDir } }
            '4' { Show-List; Switch-Profile (Read-Host 'Profile name') }
            '5' { Add-Account (Read-Host 'New profile name') }
            '0' { return }
            default { Write-Host 'Invalid choice.' -ForegroundColor Yellow }
        }
    }
}

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
    'files'  { Start-Process explorer.exe $ProfilesDir; Write-Host $ProfilesDir }
    'doctor' { Show-Doctor }
    'help'   { Show-Help }
}
