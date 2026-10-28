Set-StrictMode -Version Latest

# Read-only process discovery. Never serialize command lines: they may contain
# credentials, user prompts, or unrelated private application arguments.
function Get-ProcessField($Process, [string]$Name) {
    $property = $Process.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-CodexProcessKind($Process) {
    $name = [string](Get-ProcessField $Process 'Name')
    $path = [string](Get-ProcessField $Process 'ExecutablePath')
    if ($name -ieq 'ChatGPT.exe' -and
        (-not $path -or $path -match '[\\/]WindowsApps[\\/]OpenAI\.(Codex|ChatGPT)_')) { return 'desktop' }
    if ($name -ieq 'codex.exe') { return 'codex' }
    if ($name -match '^(codex-acp|codex-acp-adapter|codex-acp-(x64|arm64)-windows)\.exe$') { return 'acp' }
    if ($name -match '^node(?:\.exe)?$') {
        $line = [string](Get-ProcessField $Process 'CommandLine')
        # Only recognize the entry script, not a package name in arbitrary args.
        # Other runtimes/custom wrappers remain outside discovery coverage.
        if ($line -match '^\s*(?:"[^"]*node(?:\.exe)?"|\S*node(?:\.exe)?)\s+(?:"[^"\r\n]*[\\/]@(zed-industries|agentclientprotocol)[\\/]codex-acp[\\/][^"\r\n]+"|[^\s"]*[\\/]@(zed-industries|agentclientprotocol)[\\/]codex-acp[\\/][^\s"]+)(?:\s|$)') { return 'acp' }
        if ($line -match '^\s*(?:"[^"]*node(?:\.exe)?"|\S*node(?:\.exe)?)\s+(?:"[^"\r\n]*[\\/]@openai[\\/]codex[\\/]bin[\\/]codex\.js"|[^\s"]*[\\/]@openai[\\/]codex[\\/]bin[\\/]codex\.js)(?:\s|$)') { return 'codex-wrapper' }
    }
    return $null
}

function Get-ProcessAncestry($Process, [hashtable]$ById) {
    $chain = @($Process)
    $seen = @{}
    $seen[[int]$Process.ProcessId] = $true
    $current = $Process
    $state = 'complete'
    while ([int]$current.ParentProcessId -ne 0) {
        $parentId = [int]$current.ParentProcessId
        if ($seen.ContainsKey($parentId)) { $state = 'cycle'; break }
        $parent = $ById[$parentId]
        if (-not $parent) { $state = 'parent-unavailable'; break }
        $created = Get-ProcessField $current 'CreationDate'
        $parentCreated = Get-ProcessField $parent 'CreationDate'
        if (-not $created -or -not $parentCreated) { $state = 'creation-time-unavailable'; break }
        if ($parentCreated -gt $created) { $state = 'parent-pid-reused'; break }
        $chain += $parent
        $seen[$parentId] = $true
        $current = $parent
    }
    return [pscustomobject]@{ Chain = $chain; State = $state }
}

function Get-CodexProcessInventory([object[]]$Processes) {
    $byId = @{}
    foreach ($process in $Processes) { $byId[[int]$process.ProcessId] = $process }
    foreach ($process in $Processes) {
        $kind = Get-CodexProcessKind $process
        if (-not $kind) { continue }
        $ancestry = Get-ProcessAncestry $process $byId
        $parent = if ($ancestry.Chain.Count -gt 1) { $ancestry.Chain[1] } else { $null }
        $hostProcess = $null
        $environment = 'unknown'
        # Prefer the nearest application boundary. Never attribute an editor
        # launched by another editor/terminal to its more distant launcher.
        foreach ($ancestor in $ancestry.Chain) {
            $ancestorName = [string]$ancestor.Name
            if ((Get-CodexProcessKind $ancestor) -eq 'desktop') { $environment = 'desktop'; $hostProcess = $ancestor; break }
            if ($ancestorName -match '^(Code|Code - Insiders)\.exe$') { $environment = 'vscode'; $hostProcess = $ancestor; break }
            if ($ancestorName -ieq 'Zed.exe') { $environment = 'zed'; $hostProcess = $ancestor; break }
            if ($ancestorName -ieq 'Orca.exe') { $environment = 'orca'; $hostProcess = $ancestor; break }
            if ($ancestorName -match '^(WindowsTerminal|wezterm-gui|alacritty|mintty)\.exe$') { $environment = 'terminal'; $hostProcess = $ancestor; break }
        }
        $hasAcp = @($ancestry.Chain | Where-Object { (Get-CodexProcessKind $_) -eq 'acp' }).Count -gt 0
        $serverInvocation = [string](Get-ProcessField $process 'CommandLine') -match '(?:^|\s)"?app-server"?(?:\s|$)'
        $mode = if ($environment -eq 'desktop') { 'desktop' } elseif ($hasAcp) { 'acp' } elseif ($serverInvocation) { 'app-server' } else { 'unknown' }
        # A shell ancestor does not prove CLI mode: an editor can spawn its
        # agent through PowerShell/cmd as well. Do not invent a resume recipe.
        [pscustomobject]@{
            Id = [int]$process.ProcessId
            ProcessName = [string]$process.Name
            Path = [string](Get-ProcessField $process 'ExecutablePath')
            ParentId = [int]$process.ParentProcessId
            ParentName = if ($parent) { [string]$parent.Name } else { '' }
            Kind = $kind
            Environment = $environment
            Mode = $mode
            HostId = if ($hostProcess) { [int]$hostProcess.ProcessId } else { $null }
            HostName = if ($hostProcess) { [string]$hostProcess.Name } else { $null }
            AncestryState = $ancestry.State
            Ancestry = @($ancestry.Chain | ForEach-Object {
                [pscustomobject]@{ Id = [int]$_.ProcessId; Name = [string]$_.Name }
            })
            RestartSupport = 'unverified'
            NextStep = 'Verify original execution context, native session restore, and a successful request using the selected account.'
        }
    }
}

function Get-CodexProcessRelations([object[]]$Processes, [object[]]$Clients) {
    # Generic process relationships, independent of editor/terminal brand. These
    # are context for future recovery planning, NEVER a list of processes to kill.
    $byId = @{}
    $roles = @{}
    $clientIds = @{}
    foreach ($process in $Processes) { $byId[[int]$process.ProcessId] = $process }
    foreach ($client in $Clients) {
        $clientIds[$client.Id] = $true
        foreach ($ancestor in $client.Ancestry) { $roles[$ancestor.Id] = 'ancestor-context' }
    }
    foreach ($process in $Processes) {
        if ($roles.ContainsKey([int]$process.ProcessId)) { continue }
        $ancestry = Get-ProcessAncestry $process $byId
        foreach ($ancestor in $ancestry.Chain) {
            if ($clientIds.ContainsKey([int]$ancestor.ProcessId)) {
                $roles[[int]$process.ProcessId] = 'descendant-context'
                break
            }
        }
    }
    foreach ($client in $Clients) { $roles[$client.Id] = 'codex-runtime' }
    foreach ($processId in @($roles.Keys | Sort-Object)) {
        $process = $byId[$processId]
        $ancestry = Get-ProcessAncestry $process $byId
        [pscustomobject]@{
            Id = $processId
            Name = [string]$process.Name
            CreatedAt = Get-ProcessField $process 'CreationDate'
            VerifiedParentId = if ($ancestry.Chain.Count -gt 1) { [int]$ancestry.Chain[1].ProcessId } else { $null }
            Role = $roles[$processId]
        }
    }
}

# Functional core: callers supply observations; this module performs no I/O.
function New-SwitchPlan([object[]]$Processes, [object]$TargetProfile = $null) {
    $target = $TargetProfile
    $clients = @(Get-CodexProcessInventory $processes)
    $status = if ($clients.Count) { 'restart-unverified' } else { 'no-known-clients-detected' }
    if ($target -and -not $target.Exists) { $status = 'profile-not-found' }
    return [pscustomobject]@{
        SchemaVersion = 1
        ReadOnly = $true
        TargetProfile = $target
        Status = $status
        CanAutoRestart = $false
        Clients = $clients
        RelatedProcesses = @(Get-CodexProcessRelations $processes $clients)
        RecoveryRequirements = @(
            'Original execution context (workspace, terminal/tab, launch options) is known or natively restorable.'
            'Unsaved edits and the previous conversation can be restored through the owning application.'
            'Normal shutdown, relaunch, and use of the selected account have been verified.'
        )
        Coverage = @(
            'Local Windows process snapshot only; process names and ancestry are hints, not proof of the credential store used.'
            'All detected Codex instances are included, regardless of the owning application. Environment labels do not define support.'
            'Related ancestors and descendants are context only, not shutdown targets or proof of an authentication connection.'
            'Remote/WSL/container agents, renamed binaries, and arbitrary wrappers may not be detected.'
            'A snapshot can change immediately. No credentials, command lines, or session databases are read into the report.'
            'An inventory alone does not establish restoration support; zero detected clients is not an automatic-switch guarantee.'
        )
    }
}

Export-ModuleMember -Function New-SwitchPlan, Get-CodexProcessInventory, Get-CodexProcessKind, Get-ProcessAncestry, Get-CodexProcessRelations
