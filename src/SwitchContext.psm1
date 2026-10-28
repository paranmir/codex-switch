Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsRestart.psm1') -DisableNameChecking
# Composition root: environment is resolved once, never from business functions.

function New-SwitchContext {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptRoot,
        [string]$CodexHome = $env:CODEX_HOME,
        [string]$DataRoot = $env:CODEX_SWITCH_HOME,
        [scriptblock]$ReadProcesses = {
            Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate,CommandLine -ErrorAction Stop
        },
        [scriptblock]$Report = { param($Message, $ForegroundColor, $Warning) },
        [bool]$SkipClientCheck = $false,
        [bool]$IsWindows = ($env:OS -eq 'Windows_NT'),
        [object]$RestartBackend = (New-WindowsRestartBackend),
        [int]$CoordinatorId = $PID,
        [ValidateRange(0,60)][int]$ExitTimeoutSeconds = 10
    )
    if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
    if (-not $DataRoot) {
        $DataRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CodexSwitch' } else { Join-Path $env:USERPROFILE '.codex-switch' }
    }
    [pscustomobject]@{
        ScriptRoot = $ScriptRoot
        CodexHome = $CodexHome
        DataRoot = $DataRoot
        ProfilesDir = Join-Path $DataRoot 'profiles'
        RegistryPath = Join-Path $DataRoot 'profiles.json'
        AuthPath = Join-Path $CodexHome 'auth.json'
        ConfigPath = Join-Path $CodexHome 'config.toml'
        ReadProcesses = $ReadProcesses
        Report = $Report
        SkipClientCheck = $SkipClientCheck
        IsWindows = $IsWindows
        RestartBackend = $RestartBackend
        CoordinatorId = $CoordinatorId
        ExitTimeoutSeconds = $ExitTimeoutSeconds
    }
}
Export-ModuleMember -Function New-SwitchContext
