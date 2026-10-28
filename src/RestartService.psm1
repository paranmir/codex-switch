Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AccountService.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CodexRuntime.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProcessAnalysis.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RestartPlan.psm1') -DisableNameChecking

function Get-AutomaticSwitchPlan($Context, [string]$ProfileName) {
    $target = if ($ProfileName) { Get-ProfileObservation $Context $ProfileName } else { $null }
    $processes = @(Get-SwitchProcessSnapshot $Context)
    $plan = New-SwitchPlan $processes $target
    $evidence = @{}
    foreach ($client in $plan.Clients) {
        foreach ($ancestor in $client.Ancestry) {
            if (-not $evidence.ContainsKey([int]$ancestor.Id)) {
                try { $evidence[[int]$ancestor.Id] = & $Context.RestartBackend.Inspect ([int]$ancestor.Id) }
                catch { $evidence[[int]$ancestor.Id] = [pscustomobject]@{ Error='native-inspection-failed'; HasWindow=$false } }
            }
            $observed = $evidence[[int]$ancestor.Id]
            if (-not $observed -or $observed.Error -or $observed.HasWindow) { break }
        }
    }
    return New-RestartPlan $plan $processes $evidence $Context.CoordinatorId
}

function Assert-RestartPlanStable($Before, $After) {
    $beforeTargets = @($Before.RestartTargets | ForEach-Object { "$($_.Id):$($_.StartTime):$($_.Mechanism)" }) -join ','
    $afterTargets = @($After.RestartTargets | ForEach-Object { "$($_.Id):$($_.StartTime):$($_.Mechanism)" }) -join ','
    $beforeClients = @($Before.RelatedProcesses | Where-Object Role -eq 'codex-runtime' | Sort-Object Id | ForEach-Object { "$($_.Id):$($_.CreatedAt.ToUniversalTime().Ticks)" }) -join ','
    $afterClients = @($After.RelatedProcesses | Where-Object Role -eq 'codex-runtime' | Sort-Object Id | ForEach-Object { "$($_.Id):$($_.CreatedAt.ToUniversalTime().Ticks)" }) -join ','
    if (-not $After.CanAutoRestart -or $beforeTargets -ne $afterTargets -or $beforeClients -ne $afterClients) {
        throw 'Processes changed during preparation. Nothing was shut down; run switch again.'
    }
}

function Assert-RestartSessionMembers($Plan, [object[]]$Members) {
    $ids = @($Plan.RestartTargets | ForEach-Object Id)
    if ($Members.Count -ne $ids.Count) { throw 'Windows reported a different shutdown scope. Nothing was shut down.' }
    foreach ($member in $Members) {
        if ($ids -notcontains $member.Id -or -not $member.Restartable -or $member.Type -ne 1) {
            throw 'Windows did not confirm every target as a restartable window application. Nothing was shut down.'
        }
    }
}

function Invoke-AutomaticAccountSwitch($Context, [string]$ProfileName) {
    Assert-ProfileName $ProfileName
    $plan = Get-AutomaticSwitchPlan $Context $ProfileName
    if ($plan.Status -eq 'profile-not-found') { throw "Profile not found: $ProfileName" }
    if ($plan.Clients.Count -eq 0) {
        Switch-Profile $Context $ProfileName -AutomaticRestart
        return [pscustomobject]@{ Status='switched'; Profile=$ProfileName; AppsRestarted=$false; WindowCount=0; ConsoleCount=0; WorkspaceRestoreVerified=$false; ClientAuthenticationVerified=$false }
    }
    if (-not $plan.CanAutoRestart) {
        $details = ($plan.Blockers | ForEach-Object { "PID $($_.ClientId): $($_.Reason)" }) -join '; '
        throw "Automatic switching cannot restart these processes: $details. No applications were closed."
    }
    Initialize-Store $Context
    $operation = [pscustomobject]@{
        SchemaVersion=1; Id=[guid]::NewGuid().ToString('N'); Target=$ProfileName
        Stage='prepared'; ShutdownAttempted=$false; AccountChanged=$false
        ClientAuthenticationVerified=$false
        RestartAttempted=$false; RestartCode=$null; Failure=$null
        UpdatedAt=[datetime]::UtcNow.ToString('o')
        Targets=@($plan.RestartTargets | Select-Object Id,Name,StartTime,Mechanism,Kind)
    }
    $session = $null
    $failure = $null
    $nativeAttempted = $false
    $fallbackAttempted = @()
    $recipes = @{}
    $nativeTargets = @($plan.RestartTargets | Where-Object Mechanism -eq 'windows-restart-manager')
    $fallbackTargets = @($plan.RestartTargets | Where-Object Mechanism -eq 'close-and-relaunch')
    try {
        $fresh = Get-AutomaticSwitchPlan $Context $ProfileName
        Assert-RestartPlanStable $plan $fresh
        $snapshot = @(Get-SwitchProcessSnapshot $Context)
        foreach ($target in $plan.RestartTargets) {
            $process = $snapshot | Where-Object ProcessId -eq $target.Id | Select-Object -First 1
            try { $recipes[$target.Id] = & $Context.RestartBackend.Capture $target $process }
            catch {
                if ($target.Mechanism -eq 'close-and-relaunch') { throw "Could not capture launch information for PID $($target.Id). Nothing was closed." }
            }
        }
        if ($nativeTargets.Count) {
            try {
                $session = & $Context.RestartBackend.Begin $nativeTargets
                Assert-RestartSessionMembers ([pscustomobject]@{RestartTargets=$nativeTargets}) @(& $Context.RestartBackend.Members $session)
            } catch {
                if ($null -ne $session) { & $Context.RestartBackend.End $session; $session=$null }
                foreach ($target in $nativeTargets) {
                    if (-not $recipes.ContainsKey($target.Id)) { throw 'Native restart is unavailable and fallback launch information could not be captured. Nothing was closed.' }
                }
                $fallbackTargets += $nativeTargets
                $nativeTargets = @()
                foreach ($target in $operation.Targets) { $target.Mechanism='close-and-relaunch' }
            }
        }
        # Reinspect after session registration to catch PID reuse and new clients.
        Assert-RestartPlanStable $plan (Get-AutomaticSwitchPlan $Context $ProfileName)
        Write-SwitchOperation $Context $operation
        Send-SwitchNotice -Context $Context 'Closing applications for account switching...' -ForegroundColor Cyan
        $operation.Stage='shutting-down'; $operation.ShutdownAttempted=$true
        Write-SwitchOperation $Context $operation
        if ($null -ne $session) {
            $nativeAttempted=$true
            $code = & $Context.RestartBackend.Shutdown $session
            if ($code -ne 0) { throw "Normal shutdown failed (Windows code $code). The account was not switched." }
        }
        foreach ($target in $fallbackTargets) {
            $fallbackAttempted += $target
            if ($target.Kind -eq 'console') {
                # Stop recognized Codex children as well as the launcher. Never
                # terminate unrelated tool processes or the parent shell.
                foreach ($client in @($plan.Clients | Sort-Object { $_.Ancestry.Count } -Descending)) {
                    if ($client.Id -eq $target.Id -or @($client.Ancestry | Where-Object Id -eq $target.Id).Count -eq 0) { continue }
                    $evidence = & $Context.RestartBackend.Inspect $client.Id
                    $original = $snapshot | Where-Object ProcessId -eq $client.Id | Select-Object -First 1
                    if ($evidence.Error -or [Math]::Abs(([datetime]$original.CreationDate).ToUniversalTime().ToFileTimeUtc()-[long]$evidence.StartTime) -gt 10000) { throw 'A Codex child identity changed before shutdown.' }
                    & $Context.RestartBackend.Close ([pscustomobject]@{Id=$client.Id;StartTime=$evidence.StartTime;Kind='console'})
                }
            }
            if (& $Context.RestartBackend.Alive $target) { & $Context.RestartBackend.Close $target }
        }
        # Give windows time to save and exit. An app that accepted close but
        # remains in the tray can then be terminated without killing its editor.
        $deadline = [datetime]::UtcNow.AddSeconds($Context.ExitTimeoutSeconds)
        $backgroundSweepDone=$false
        do {
            $remaining = @(Get-CodexProcessInventory @(Get-SwitchProcessSnapshot $Context))
            $openTargets = @($plan.RestartTargets | Where-Object { & $Context.RestartBackend.Alive $_ })
            if ($remaining.Count -eq 0 -and $openTargets.Count -eq 0) { break }
            if ([datetime]::UtcNow -ge $deadline) {
                if (-not $backgroundSweepDone) {
                    $backgroundSweepDone=$true
                    foreach ($target in $fallbackTargets) {
                        if ($target.Kind -ne 'window' -or -not (& $Context.RestartBackend.Alive $target)) { continue }
                        $observed=& $Context.RestartBackend.Inspect $target.Id
                        if ($observed.Error -or $observed.HasWindow -or $observed.StartTime -ne $target.StartTime) { continue }
                        # Only original, identified Codex runtimes in this owner
                        # are eligible; unrelated descendant tool jobs are not.
                        foreach ($client in @($plan.Clients | Sort-Object { $_.Ancestry.Count } -Descending)) {
                            if ($client.Id -eq $target.Id -or @($client.Ancestry | Where-Object Id -eq $target.Id).Count -eq 0) { continue }
                            $original=$snapshot | Where-Object ProcessId -eq $client.Id | Select-Object -First 1
                            $child=& $Context.RestartBackend.Inspect $client.Id
                            if ($child -and -not $child.Error -and [Math]::Abs(([datetime]$original.CreationDate).ToUniversalTime().ToFileTimeUtc()-[long]$child.StartTime) -le 10000) {
                                $identity=[pscustomobject]@{Id=$client.Id;StartTime=$child.StartTime;Kind='console'}
                                if (& $Context.RestartBackend.Alive $identity) { & $Context.RestartBackend.Close $identity }
                            }
                        }
                        & $Context.RestartBackend.Close ([pscustomobject]@{Id=$target.Id;StartTime=$target.StartTime;Kind='console'})
                    }
                    $deadline=[datetime]::UtcNow.AddSeconds(2)
                    continue
                }
                throw 'An application canceled close or Codex processes remain. The account was not switched.'
            }
            Start-Sleep -Milliseconds 200
        } while ($true)
        $operation.Stage='switching'; Write-SwitchOperation $Context $operation
        Switch-Profile $Context $ProfileName -AutomaticRestart
        $operation.AccountChanged=$true
        $operation.Stage='account-switched'; Write-SwitchOperation $Context $operation
    } catch {
        $failure=$_.Exception.Message
        # Store only a stage marker, not arbitrary exception text or tokens.
        $operation.Failure='operation-failed'
    } finally {
        if ($null -ne $session) {
            try {
                if ($nativeAttempted) {
                    $operation.RestartAttempted=$true
                    $operation.Stage='restarting'
                    try { Write-SwitchOperation $Context $operation } catch { }
                    # Microsoft requires restarting even after partial shutdown.
                    try { $operation.RestartCode = & $Context.RestartBackend.Restart $session }
                    catch { $operation.RestartCode=-1 }
                    $members = @(& $Context.RestartBackend.Members $session)
                    foreach ($target in $nativeTargets) {
                        try {
                            $member = $members | Where-Object Id -eq $target.Id | Select-Object -First 1
                            if ($member -and ($member.Status -band 8) -ne 0) { continue }
                            if (& $Context.RestartBackend.Alive $target) { continue }
                            if ($member -and ($member.Status -band 2) -ne 0 -and $recipes.ContainsKey($target.Id)) {
                                & $Context.RestartBackend.Launch $recipes[$target.Id] | Out-Null
                            } else { $failure = "$failure Could not confirm restart of PID $($target.Id)." }
                        } catch { $failure="$failure Could not relaunch PID $($target.Id)." }
                    }
                }
            } catch { $failure = "$failure Application restart verification failed." }
            finally { try { & $Context.RestartBackend.End $session } catch { $failure="$failure Could not end the restart session." } }
        }
        foreach ($target in $fallbackAttempted) {
            try {
                # A canceled close leaves the original alive: never open a duplicate.
                if (-not (& $Context.RestartBackend.Alive $target)) {
                    $operation.RestartAttempted=$true
                    & $Context.RestartBackend.Launch $recipes[$target.Id] | Out-Null
                }
            } catch { $failure="$failure Could not relaunch PID $($target.Id)." }
        }
        $operation.Stage = if ($failure) { 'failed' } else { 'completed' }
        if ($failure -and -not $operation.Failure) { $operation.Failure='restart-failed' }
        try { Write-SwitchOperation $Context $operation } catch { $failure = "$failure Could not save operation status." }
    }
    if ($failure) {
        $accountState = if ($operation.AccountChanged) { "Account switched to '$ProfileName'." } else { 'Account switch did not complete; inspect whoami for the on-disk state.' }
        throw "$accountState $failure"
    }
    return [pscustomobject]@{ Status='switched-and-restarted'; Profile=$ProfileName; AppsRestarted=$true;
        WindowCount=@($plan.RestartTargets | Where-Object Kind -eq 'window').Count;
        ConsoleCount=@($plan.RestartTargets | Where-Object Kind -eq 'console').Count;
        WorkspaceRestoreVerified=$false; ClientAuthenticationVerified=$false }
}

Export-ModuleMember -Function Get-AutomaticSwitchPlan, Invoke-AutomaticAccountSwitch
