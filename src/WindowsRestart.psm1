Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-WindowsRestart {
    if (-not ('CodexSwitch.RestartNative' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'WindowsRestart.cs')
    }
    if (-not ('CodexSwitch.FallbackNative' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'FallbackRestart.cs')
    }
}

function Get-NativeRestartEvidence([int]$ProcessId) {
    Initialize-WindowsRestart
    return [CodexSwitch.RestartNative]::Inspect($ProcessId)
}

function Start-NativeRestartSession([object[]]$Targets) {
    Initialize-WindowsRestart
    $identities = @($Targets | ForEach-Object { [CodexSwitch.UniqueProcess]::From($_.Id, $_.StartTime) })
    return [CodexSwitch.RestartNative]::Begin([CodexSwitch.UniqueProcess[]]$identities)
}

function Get-NativeRestartMembers($Session) {
    Initialize-WindowsRestart
    return @([CodexSwitch.RestartNative]::List([uint32]$Session) | ForEach-Object {
        [pscustomobject]@{ Id=[int]$_.Process.Id; Restartable=$_.Restartable; Type=$_.AppType; Status=$_.Status }
    })
}

function Stop-NativeRestartTargets($Session) {
    return [CodexSwitch.RestartNative]::Shutdown([uint32]$Session)
}

function Restart-NativeTargets($Session) {
    return [CodexSwitch.RestartNative]::Restart([uint32]$Session)
}

function Close-NativeRestartSession($Session) {
    [CodexSwitch.RestartNative]::End([uint32]$Session)
}

function New-WindowsRestartBackend {
    # One OS backend for any application; no brand-specific adapters.
    [pscustomobject]@{
        Inspect = ${function:Get-NativeRestartEvidence}
        Begin = ${function:Start-NativeRestartSession}
        Members = ${function:Get-NativeRestartMembers}
        Shutdown = ${function:Stop-NativeRestartTargets}
        Restart = ${function:Restart-NativeTargets}
        End = ${function:Close-NativeRestartSession}
        Capture = { param($Target, $Process)
            Initialize-WindowsRestart
            [CodexSwitch.FallbackNative]::Capture($Target.Id, $Target.StartTime, $Process.ExecutablePath, $Process.CommandLine, ($Target.Kind -eq 'console'))
        }
        Alive = { param($Target) [CodexSwitch.FallbackNative]::Alive($Target.Id, $Target.StartTime) }
        Close = { param($Target) [CodexSwitch.FallbackNative]::Close($Target.Id, $Target.StartTime, ($Target.Kind -eq 'console')) }
        Launch = { param($Recipe) [CodexSwitch.FallbackNative]::Launch($Recipe) }
    }
}

Export-ModuleMember -Function New-WindowsRestartBackend, Get-NativeRestartEvidence
