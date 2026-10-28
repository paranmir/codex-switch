Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ProcessAnalysis.psm1') -DisableNameChecking

function New-RestartPlan($Plan, [object[]]$Processes, [hashtable]$Evidence, [int]$CoordinatorId) {
    $byId = @{}
    foreach ($process in $Processes) { $byId[[int]$process.ProcessId] = $process }
    $selfAncestors = @($CoordinatorId)
    if ($byId.ContainsKey($CoordinatorId)) { $selfAncestors = @((Get-ProcessAncestry $byId[$CoordinatorId] $byId).Chain | ForEach-Object { [int]$_.ProcessId }) }
    $targets = @{}
    $blockers = @()
    foreach ($client in $Plan.Clients) {
        $owner = $null; $reason = $null; $kind = 'window'
        $runtime = $Evidence[[int]$client.Id]
        $hosted = $client.Mode -in @('acp','desktop','app-server')
        foreach ($ancestor in $client.Ancestry) {
            # Preserve the interactive shell; ACP instead needs its owning app.
            if (-not $hosted -and $ancestor.Name -match '^(pwsh|powershell|cmd|bash|wsl|wslhost)\.exe$') {
                $owner=$runtime; $kind='console'; break
            }
            if ($ancestor.Name -match '^(explorer|services|wininit|winlogon|svchost)\.exe$') { break }
            $observation = $Evidence[[int]$ancestor.Id]
            if (-not $observation -or $observation.Error) { $reason='process-inspection-unavailable'; break }
            if (Get-CodexProcessKind $byId[[int]$ancestor.Id]) { $runtime=$observation }
            if ($observation.HasWindow) { $owner=$observation; break }
        }
        if (-not $reason -and -not $owner) {
            if ($hosted) { $reason='stdio-agent-owner-unavailable' }
            else { $owner=$runtime; $kind='console' }
        }
        if ($owner) {
            if (-not $owner.SameUser -or -not $owner.SameSession -or $owner.Elevated) { $reason='different-user-session-or-elevation' }
            elseif ($selfAncestors -contains [int]$owner.Id) { $reason='switch-is-running-inside-target-application' }
            elseif (-not $byId[[int]$owner.Id].CreationDate -or
                [Math]::Abs(([datetime]$byId[[int]$owner.Id].CreationDate).ToUniversalTime().ToFileTimeUtc() - [long]$owner.StartTime) -gt 10000) { $reason='process-identity-changed' }
            elseif ($kind -eq 'console' -and [string]$byId[[int]$owner.Id].CommandLine -match '(?:^|\s)"?(exec|review)"?(?:\s|$)') { $reason='noninteractive-command-cannot-be-replayed' }
        }
        if ($reason) {
            $blockers += [pscustomobject]@{ ClientId=$client.Id; OwnerId=if ($owner) { $owner.Id } else { $null }; Reason=$reason }
        } else {
            $mechanism = if ($owner.Registered -and ($owner.Flags -band 4) -eq 0 -and $kind -eq 'window') { 'windows-restart-manager' } else { 'close-and-relaunch' }
            $targets[[int]$owner.Id] = [pscustomobject]@{
                Id=[int]$owner.Id; Name=[string]$byId[[int]$owner.Id].Name
                StartTime=[long]$owner.StartTime; Mechanism=$mechanism; Kind=$kind
            }
        }
    }
    foreach ($target in @($targets.Values)) {
        $ancestors=@((Get-ProcessAncestry $byId[$target.Id] $byId).Chain | Select-Object -Skip 1)
        foreach ($ancestor in $ancestors) {
            if ($targets.ContainsKey([int]$ancestor.ProcessId) -and $targets[[int]$ancestor.ProcessId].Kind -eq 'window') {
                $targets.Remove($target.Id); break
            }
        }
    }
    $canRestart=$Plan.Clients.Count -gt 0 -and $blockers.Count -eq 0
    $status=if ($blockers.Count) { 'automatic-restart-blocked' } elseif ($canRestart) { 'automatic-restart-available' } else { 'no-known-clients-detected' }
    if ($Plan.TargetProfile -and -not $Plan.TargetProfile.Exists) { $status='profile-not-found'; $canRestart=$false }
    $Plan.Status=$status; $Plan.CanAutoRestart=$canRestart
    $Plan | Add-Member -NotePropertyName RestartTargets -NotePropertyValue @($targets.Values | Sort-Object Id)
    $Plan | Add-Member -NotePropertyName Blockers -NotePropertyValue $blockers
    $Plan | Add-Member -NotePropertyName WorkspaceRestoreVerified -NotePropertyValue $false
    $Plan.RecoveryRequirements=@('Launch information is captured before closing fallback targets.', 'GUI applications must accept normal close; CLI execution is interrupted.', 'Workspace and conversation restoration depend on each application.')
    $Plan.Coverage=@($Plan.Coverage) + @(
        'Registered window applications use Windows Restart Manager first; other applications close and relaunch with their original executable, arguments and working directory.'
        'CLI restarts open a new console. Re-execution in the existing terminal tab is not implemented.'
        'Replacing auth.json does not establish a live account change. Hosted ACP/app-server processes restart through their GUI owner; their in-app account is not verified by this plan.'
        'Launch recipes remain in memory; original process environment variables and in-memory conversations are not restored.'
        'Running switch inside an application that must close is blocked; launch codexSwitch.cmd separately.'
    )
    return $Plan
}
Export-ModuleMember -Function New-RestartPlan
