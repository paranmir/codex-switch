. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Import-Module (Join-Path $testRepository 'src/RestartService.psm1') -DisableNameChecking
Import-Module (Join-Path $testRepository 'src/RestartPlan.psm1') -DisableNameChecking
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$testRoot=Join-Path $env:TEMP ('codex-restart-test-'+[guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function New-Process([int]$Id, [int]$Parent, [string]$Name, [string]$Command='') {
    [pscustomobject]@{ProcessId=$Id;ParentProcessId=$Parent;Name=$Name;ExecutablePath="C:\Fake\$Name";CommandLine=$Command;CreationDate=([datetime]'2026-01-01').AddSeconds($Id)}
}
function New-Scenario([bool]$Native=$false, [bool]$Second=$false) {
    $processes=@((New-Process 10 0 'AnyEditor.exe'),(New-Process 11 10 'codex.exe' 'codex.exe app-server'))
    if ($Second) { $processes+=@((New-Process 20 0 'OtherEditor.exe'),(New-Process 21 20 'codex-acp.exe')) }
    $state=@{Processes=$processes;Events=[Collections.Generic.List[string]]::new();Alive=@{};Evidence=@{};NativeIds=@();Cancel=0;Tray=0;FailCapture=0;FailSwitch=$false;FailBegin=$false;FailShutdown=$false;FailNativeRestart=$false;FailLaunch=0;Changed=$false;Restarted=$false}
    foreach ($process in $processes) {
        $id=[int]$process.ProcessId; $state.Alive[$id]=$true
        $state.Evidence[$id]=[pscustomobject]@{Id=$id;StartTime=$process.CreationDate.ToUniversalTime().ToFileTimeUtc();HasWindow=$id -in @(10,20);SameUser=$true;SameSession=$true;Elevated=$false;Registered=$Native -and $id -eq 10;Flags=0;Error=$null}
    }
    $backend=[pscustomobject]@{
        Inspect={param($Id) $state.Evidence[$Id]}.GetNewClosure()
        Capture={param($Target,$Process) $state.Events.Add("capture:$($Target.Id)"); if ($state.FailCapture -eq $Target.Id) {throw 'capture failed'}; [pscustomobject]@{Id=$Target.Id;Secret='do-not-serialize'}}.GetNewClosure()
        Alive={param($Target) [bool]$state.Alive[$Target.Id]}.GetNewClosure()
        Close={param($Target)
            $state.Events.Add("close:$($Target.Id)")
            if ($state.Cancel -eq $Target.Id) {return}
            if ($state.Tray -eq $Target.Id -and $Target.Kind -eq 'window') {$state.Evidence[$Target.Id].HasWindow=$false; return}
            $state.Alive[$Target.Id]=$false
            foreach ($p in $state.Processes) {if ($p.ParentProcessId -eq $Target.Id) {$state.Alive[[int]$p.ProcessId]=$false}}
        }.GetNewClosure()
        Launch={param($Recipe) $state.Events.Add("launch:$($Recipe.Id)"); if ($state.FailLaunch -eq $Recipe.Id) {throw 'launch failed'}; 1000+$Recipe.Id}.GetNewClosure()
        Begin={param($Targets) $state.Events.Add('begin'); if ($state.FailBegin) {throw 'native unavailable'}; $state.NativeIds=@($Targets | ForEach-Object Id); 42}.GetNewClosure()
        Members={param($Session) foreach ($id in $state.NativeIds) {[pscustomobject]@{Id=$id;Restartable=$true;Type=1;Status=if ($state.Restarted) {8} elseif ($state.Alive[$id]) {1} else {2}}}}.GetNewClosure()
        Shutdown={param($Session)
            $state.Events.Add('native-close')
            foreach ($id in $state.NativeIds) {$state.Alive[$id]=$false; foreach ($p in $state.Processes) {if ($p.ParentProcessId -eq $id) {$state.Alive[[int]$p.ProcessId]=$false}}}
            if ($state.FailShutdown) {5} else {0}
        }.GetNewClosure()
        Restart={param($Session) $state.Events.Add('native-restart'); if ($state.FailNativeRestart) {5} else {$state.Restarted=$true; 0}}.GetNewClosure()
        End={param($Session) $state.Events.Add('end')}.GetNewClosure()
    }
    $context=New-SwitchContext -ScriptRoot $testRepository -CodexHome (Join-Path $testRoot 'home') -DataRoot (Join-Path $testRoot ([guid]::NewGuid().ToString('N'))) -IsWindows:$false -CoordinatorId 999 -ExitTimeoutSeconds 0 -RestartBackend $backend -ReadProcesses { @($state.Processes | Where-Object { $state.Alive[[int]$_.ProcessId] }) }.GetNewClosure()
    Initialize-Store $context
    Write-Utf8NoBom (Get-ProfilePath $context 'work') '{}'
    $context | Add-Member TestState $state
    [pscustomobject]@{Context=$context;State=$state}
}
# Replace only the account operation inside this test's module instance. The
# real account validation/rollback path has its own fake-Codex regression suite.
$service=Get-Module RestartService
& $service { function script:Switch-Profile($Context,[string]$ProfileName) {
    $Context.TestState.Events.Add('switch')
    if ($Context.TestState.FailSwitch) {throw 'test validation failed'}
    $Context.TestState.Changed=$true
} }
try {
    $s=New-Scenario
    $plan=Get-AutomaticSwitchPlan $s.Context work
    Assert-True ($plan.CanAutoRestart -and $plan.RestartTargets[0].Mechanism -eq 'close-and-relaunch') 'unregistered arbitrary editor must use fallback'
    $result=Invoke-AutomaticAccountSwitch $s.Context work
    Assert-True ($result.AppsRestarted -and ($s.State.Events -join ',') -eq 'capture:10,close:10,switch,launch:10') 'fallback must capture, close, switch and reopen in order'
    Assert-True ($result.WindowCount -eq 1 -and $result.ConsoleCount -eq 0) 'GUI-only restart must not report new CLI consoles'
    $journal=Read-SwitchOperation $s.Context
    Assert-True ($journal.Stage -eq 'completed' -and $journal.AccountChanged) 'success status must be persisted'
    Assert-True (-not $journal.ClientAuthenticationVerified -and -not $result.ClientAuthenticationVerified) 'file switch and process launch must not claim in-app account verification'
    Assert-True (($journal | ConvertTo-Json -Depth 8) -notmatch 'do-not-serialize|Arguments|CommandLine') 'journal must omit launch recipes'

    # Zed's current registry entry is a Node ACP process, which can outlive its
    # inner app-server. It must still select the GUI owner, never a new console.
    $s=New-Scenario
    $s.State.Processes[0].Name='Zed.exe'
    $s.State.Processes[1].Name='node.exe'
    $s.State.Processes[1].CommandLine='node.exe C:\Packages\@agentclientprotocol\codex-acp\dist\index.js'
    $plan=Get-AutomaticSwitchPlan $s.Context work
    Assert-True ($plan.Clients.Count -eq 1 -and $plan.Clients[0].Mode -eq 'acp' -and $plan.RestartTargets[0].Id -eq 10 -and $plan.RestartTargets[0].Kind -eq 'window') 'current ACP wrapper must select owning editor even without inner Codex'
    Invoke-AutomaticAccountSwitch $s.Context work | Out-Null
    Assert-True ($s.State.Events -contains 'close:10' -and $s.State.Events -contains 'launch:10' -and $s.State.Events -notcontains 'launch:11') 'ACP must reopen its owning editor instead of detaching the stdio server'

    # VS Code extensions communicate over private stdio. Even with an
    # intermediate shell, the server must not be launched into a new console.
    $s=New-Scenario
    $s.State.Processes[0].Name='Code.exe'
    $extensionHost=New-Process 12 10 'Code.exe'
    $extensionHost.CreationDate=$s.State.Processes[0].CreationDate.AddMilliseconds(100)
    $bridge=New-Process 13 12 'cmd.exe'
    $bridge.CreationDate=$s.State.Processes[0].CreationDate.AddMilliseconds(200)
    foreach ($p in @($extensionHost,$bridge)) {
        $s.State.Processes+=@($p)
        $s.State.Alive[[int]$p.ProcessId]=$true
        $s.State.Evidence[[int]$p.ProcessId]=[pscustomobject]@{Id=$p.ProcessId;StartTime=$p.CreationDate.ToUniversalTime().ToFileTimeUtc();HasWindow=$false;SameUser=$true;SameSession=$true;Elevated=$false;Registered=$false;Flags=0;Error=$null}
    }
    $s.State.Processes[1].ParentProcessId=13
    $s.State.Processes[1].CommandLine='codex.exe -c features.code_mode_host=true app-server --analytics-default-enabled'
    $plan=Get-AutomaticSwitchPlan $s.Context work
    Assert-True ($plan.CanAutoRestart -and $plan.Clients[0].Mode -eq 'app-server' -and $plan.RestartTargets[0].Id -eq 10 -and $plan.RestartTargets[0].Kind -eq 'window') 'VS Code app-server must restart through the owning window across hidden extension-host and shell ancestors'
    $s.State.Processes[1].CommandLine='codex.exe'
    $plan=Get-AutomaticSwitchPlan $s.Context work
    Assert-True ($plan.RestartTargets[0].Id -eq 11 -and $plan.RestartTargets[0].Kind -eq 'console') 'interactive CLI under the same editor must preserve its shell instead'

    $s=New-Scenario
    $s.State.Tray=10
    Invoke-AutomaticAccountSwitch $s.Context work | Out-Null
    Assert-True (@($s.State.Events | Where-Object {$_ -eq 'close:10'}).Count -eq 2 -and $s.State.Changed -and $s.State.Events -contains 'launch:10') 'closed-window background app must be terminated and relaunched'

    $s=New-Scenario $true $true
    Invoke-AutomaticAccountSwitch $s.Context work | Out-Null
    Assert-True (($s.State.Events -join ',') -eq 'capture:10,capture:20,begin,native-close,close:20,switch,native-restart,end,launch:20') 'mixed native and fallback order'

    $s=New-Scenario $true
    $s.State.FailBegin=$true
    Invoke-AutomaticAccountSwitch $s.Context work | Out-Null
    Assert-True ($s.State.Events -contains 'close:10' -and $s.State.Events -contains 'launch:10') 'unavailable native service must downgrade to fallback'

    $s=New-Scenario $true
    $s.State.FailNativeRestart=$true
    Invoke-AutomaticAccountSwitch $s.Context work | Out-Null
    Assert-True ($s.State.Events -contains 'native-restart' -and $s.State.Events -contains 'launch:10') 'confirmed native restart failure must relaunch stopped app'

    $s=New-Scenario $true
    $s.State.FailShutdown=$true
    $failed=$false
    try {Invoke-AutomaticAccountSwitch $s.Context work | Out-Null} catch {$failed=$true}
    Assert-True ($failed -and -not $s.State.Changed -and $s.State.Events -contains 'native-restart') 'partial native close must always restart without switching'

    $s=New-Scenario $false $true
    $s.State.Cancel=20
    $failed=$false
    try {Invoke-AutomaticAccountSwitch $s.Context work | Out-Null} catch {$failed=$true}
    Assert-True ($failed -and -not $s.State.Changed -and $s.State.Events -contains 'launch:10' -and $s.State.Events -notcontains 'launch:20') 'cancel must restore closed apps without duplicating live app'

    $s=New-Scenario
    $s.State.FailSwitch=$true
    $failed=$false
    try {Invoke-AutomaticAccountSwitch $s.Context work | Out-Null} catch {$failed=$true}
    Assert-True ($failed -and $s.State.Events -contains 'launch:10') 'validation failure must reopen applications'

    $s=New-Scenario
    $s.State.FailCapture=10
    $failed=$false
    try {Invoke-AutomaticAccountSwitch $s.Context work | Out-Null} catch {$failed=$true}
    Assert-True ($failed -and $s.State.Events -notcontains 'close:10') 'capture failure must happen before shutdown'

    $s=New-Scenario
    $s.State.FailLaunch=10
    $failed=$false
    try {Invoke-AutomaticAccountSwitch $s.Context work | Out-Null} catch {$failed=$true}
    Assert-True ($failed -and (Read-SwitchOperation $s.Context).AccountChanged -and (Read-SwitchOperation $s.Context).Stage -eq 'failed') 'launch failure must report account already changed'

    $s=New-Scenario
    $s.Context.CoordinatorId=11
    Assert-True (-not (Get-AutomaticSwitchPlan $s.Context work).CanAutoRestart) 'coordinator owner must not close itself'
    $s.Context.CoordinatorId=999
    $s.State.Evidence[10].StartTime+=100000
    Assert-True (-not (Get-AutomaticSwitchPlan $s.Context work).CanAutoRestart) 'PID identity mismatch must block before close'

    $s=New-Scenario
    $s.State.Processes[1].CommandLine='codex.exe'
    $s.State.Processes[0].Name='pwsh.exe'
    $s.State.Evidence[10].HasWindow=$false
    $plan=Get-AutomaticSwitchPlan $s.Context work
    Assert-True ($plan.CanAutoRestart -and $plan.RestartTargets[0].Id -eq 11 -and $plan.RestartTargets[0].Kind -eq 'console') 'CLI must preserve its parent shell'
    $result=Invoke-AutomaticAccountSwitch $s.Context work
    Assert-True ($s.State.Alive[10] -and $s.State.Events -contains 'launch:11') 'CLI restart must not close parent'
    Assert-True ($result.WindowCount -eq 0 -and $result.ConsoleCount -eq 1) 'CLI restart must report the new console count'
    $s=New-Scenario
    $s.State.Processes[1].CommandLine='codex.exe exec "perform work"'
    $s.State.Processes[0].Name='pwsh.exe'
    $s.State.Evidence[10].HasWindow=$false
    Assert-True (-not (Get-AutomaticSwitchPlan $s.Context work).CanAutoRestart) 'one-shot commands must not be replayed on restart'
    Write-Host 'All automatic restart tests passed.' -ForegroundColor Green
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'codex-restart-test-*') {Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
