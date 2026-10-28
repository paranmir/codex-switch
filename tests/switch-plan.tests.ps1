. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('codex-switch-plan-test-' + [guid]::NewGuid().ToString('N'))
$oldCodexHome = $env:CODEX_HOME
$oldSwitchHome = $env:CODEX_SWITCH_HOME
$oldSkip = $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK
$env:CODEX_HOME = Join-Path $testRoot 'codex'
$env:CODEX_SWITCH_HOME = Join-Path $testRoot 'profiles'
$script:mockProcesses = @()
$script:queryFailed = $false

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Get-CimInstance {
    param($ClassName, $Property, $ErrorAction)
    if ($script:queryFailed) { throw 'Process inventory unavailable' }
    return $script:mockProcesses
}
function New-ProcessRow([int]$Id, [int]$Parent, [string]$Name, [string]$Line = '') {
    [pscustomobject]@{
        ProcessId=$Id; ParentProcessId=$Parent; Name=$Name
        ExecutablePath="C:\TestApps\$Name"; CreationDate=[datetime]'2026-01-01'
        CommandLine=$Line
    }
}

try {
    # Load through the actual read-only entry point; unlike help, plan must not
    # initialize the store, even when its profile/data directories do not exist.
    $context = New-TestContext
    $output = Invoke-TestCommand plan -Json
    $plan = $output | ConvertFrom-Json
    Assert-True (-not (Test-Path -LiteralPath $testRoot)) 'plan must not create any store or config directories'
    Assert-True ($plan.Status -eq 'no-known-clients-detected') 'empty inventory must be reported without claiming complete coverage'
    Assert-True (-not $plan.CanAutoRestart) 'empty inventory must not imply automatic restart support'

    $zed = New-ProcessRow 10 0 'Zed.exe'
    $shell = New-ProcessRow 11 10 'pwsh.exe'
    $acp = New-ProcessRow 12 11 'codex-acp.exe'
    $codex = New-ProcessRow 13 12 'codex.exe' 'codex.exe --token secret-do-not-output'
    $script:mockProcesses = @($zed, $shell, $acp, $codex)
    $plan = Get-StandaloneSwitchPlan -Context $context
    Assert-True ($plan.Clients.Count -eq 2) 'detect ACP and its Codex child without treating the editor as a Codex client'
    $client = @($plan.Clients | Where-Object Id -eq 13)[0]
    Assert-True ($client.Environment -eq 'zed' -and $client.Mode -eq 'acp') 'follow shell and ACP ancestors to Zed'
    Assert-True ($client.HostId -eq 10 -and $client.Ancestry.Count -eq 4) 'retain the verified process chain'
    Assert-True ($client.RestartSupport -eq 'unverified') 'ACP recognition is not proof of conversation restoration'
    Assert-True ((($plan | ConvertTo-Json -Depth 8) -notmatch 'secret-do-not-output|CommandLine')) 'reports must omit command lines and their secrets'

    # Do not confuse an integrated terminal/launcher with a verified ACP session.
    $codex.ParentProcessId = 11
    $plan = Get-StandaloneSwitchPlan -Context $context
    $client = @($plan.Clients | Where-Object Id -eq 13)[0]
    Assert-True ($client.Environment -eq 'zed' -and $client.Mode -eq 'unknown') 'a shell under Zed alone must not imply ACP or CLI mode'

    $terminal = New-ProcessRow 20 0 'WindowsTerminal.exe'
    $editor = New-ProcessRow 21 20 'Code.exe'
    $intermediate = New-ProcessRow 22 21 'node.exe'
    $codex.ParentProcessId = 22
    $script:mockProcesses = @($terminal, $editor, $intermediate, $codex)
    $client = (Get-StandaloneSwitchPlan -Context $context).Clients[0]
    Assert-True ($client.Environment -eq 'vscode' -and $client.HostId -eq 21) 'nearest editor must take precedence over the terminal that launched it'
    $codex.CommandLine = 'codex.exe -c features.code_mode_host=true app-server --analytics-default-enabled'
    $client = (Get-StandaloneSwitchPlan -Context $context).Clients[0]
    Assert-True ($client.Environment -eq 'vscode' -and $client.Mode -eq 'app-server') 'identify the VS Code extension server invocation explicitly'
    $codex.CommandLine = 'codex.exe'
    $codex.ParentProcessId = 20
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[0].Environment -eq 'terminal') 'identify a known terminal ancestor'
    $editor.Name = 'Orca.exe'
    $codex.ParentProcessId = 21
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[0].Environment -eq 'orca') 'classify Orca without claiming a verified integration'

    # PID reuse/missing parents/cycles cannot be interpreted as reliable ownership.
    $editor.CreationDate = [datetime]'2026-01-02'
    $client = (Get-StandaloneSwitchPlan -Context $context).Clients[0]
    Assert-True ($client.Environment -eq 'unknown' -and $client.AncestryState -eq 'parent-pid-reused') 'reject a newer parent with a reused PID'
    $editor.CreationDate = $null
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[0].AncestryState -eq 'creation-time-unavailable') 'do not trust an ancestor without its creation time'
    $script:mockProcesses = @($codex)
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[0].AncestryState -eq 'parent-unavailable') 'report orphaned clients'
    $codex.ParentProcessId = 13
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[0].AncestryState -eq 'cycle') 'stop at cyclic ancestry'

    $wrapper = New-ProcessRow 30 0 'node.exe' '"C:\Program Files\node.exe" "C:\Packages\@zed-industries\codex-acp\dist\index.js" --token secret-wrapper'
    Assert-True ((Get-CodexProcessKind $wrapper) -eq 'acp') 'recognize the ACP node entry script'
    $wrapper.CommandLine = '"C:\Program Files\node.exe" "C:\Packages\@agentclientprotocol\codex-acp\dist\index.js"'
    Assert-True ((Get-CodexProcessKind $wrapper) -eq 'acp') 'recognize the current ACP registry package used by Zed'
    $wrapper.CommandLine = 'node.exe C:/Packages/@agentclientprotocol/codex-acp/dist/index.js'
    Assert-True ((Get-CodexProcessKind $wrapper) -eq 'acp') 'recognize unquoted current ACP paths with forward slashes'
    $wrapper.CommandLine = 'node.exe other.js "C:\Packages\@agentclientprotocol\codex-acp\dist\index.js"'
    Assert-True (-not (Get-CodexProcessKind $wrapper)) 'an ACP package in arbitrary arguments is not the entry script'
    foreach ($binary in @('codex-acp-x64-windows.exe','codex-acp-arm64-windows.exe')) {
        Assert-True ((Get-CodexProcessKind (New-ProcessRow 33 0 $binary)) -eq 'acp') 'recognize published standalone ACP binary names'
    }
    $wrapper.CommandLine = 'node.exe C:\Packages\@openai\codex\bin\codex.js'
    Assert-True ((Get-CodexProcessKind $wrapper) -eq 'codex-wrapper') 'recognize the npm Codex launcher'
    $wrapper.CommandLine = 'node.exe other.js "C:\Packages\@openai\codex\bin\codex.js"'
    Assert-True (-not (Get-CodexProcessKind $wrapper)) 'a package name in another program argument is not a Codex process'
    $unrelated = New-ProcessRow 31 0 'ChatGPT.exe'
    Assert-True (-not (Get-CodexProcessKind $unrelated)) 'exclude known non-OpenAI paths for ChatGPT-named apps'
    $desktop = New-ProcessRow 32 0 'ChatGPT.exe'
    $desktop.ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe'
    $codex.ParentProcessId = 32
    $script:mockProcesses = @($desktop, $codex)
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients[1].Environment -eq 'desktop') 'identify Desktop through its package path and ancestry'

    # Scope is every detected Codex instance, not a list of supported app names.
    $customHost = New-ProcessRow 40 0 'AnyFutureEditor.exe'
    $customBridge = New-ProcessRow 41 40 'VendorBridge.exe'
    $codex.ParentProcessId = 41
    $toolChild = New-ProcessRow 42 13 'AnyTool.exe'
    $unrelatedSibling = New-ProcessRow 43 40 'OtherEditorTask.exe'
    $script:mockProcesses = @($customHost, $customBridge, $codex, $toolChild, $unrelatedSibling)
    $plan = Get-StandaloneSwitchPlan -Context $context
    Assert-True ($plan.Clients.Count -eq 1 -and $plan.Clients[0].Environment -eq 'unknown') 'include runtimes launched by unrecognized applications'
    Assert-True ($plan.RelatedProcesses.Count -eq 4) 'include verified ancestors and descendants without unrelated siblings'
    Assert-True (@($plan.RelatedProcesses | Where-Object { $_.Id -eq 40 -and $_.Role -eq 'ancestor-context' }).Count -eq 1) 'retain unknown owning apps as context'
    Assert-True (@($plan.RelatedProcesses | Where-Object { $_.Id -eq 42 -and $_.Role -eq 'descendant-context' }).Count -eq 1) 'include arbitrary Codex child tools as context, not restart targets'
    Assert-True ($plan.RecoveryRequirements.Count -gt 0 -and -not $plan.CanAutoRestart) 'unknown and known hosts share the same recovery requirements'

    # A profile existence check must not read auth or initialize/migrate a registry.
    New-Item -ItemType Directory -Path $context.ProfilesDir -Force | Out-Null
    $profilePath = Join-Path $context.ProfilesDir 'example.auth.json'
    [IO.File]::WriteAllText($profilePath, 'deliberately not valid authentication JSON')
    $hash = (Get-FileHash -LiteralPath $profilePath).Hash
    $plan = Get-StandaloneSwitchPlan -Context $context 'example'
    Assert-True ($plan.TargetProfile.Exists -and -not $plan.TargetProfile.AuthenticationChecked) 'only check existence of a selected profile'
    Assert-True ((Get-FileHash -LiteralPath $profilePath).Hash -eq $hash) 'plan must not modify the selected auth file'
    Assert-True (-not (Test-Path -LiteralPath $context.RegistryPath)) 'plan must not reconcile or create the registry'
    Assert-True ((Get-StandaloneSwitchPlan -Context $context 'missing').Status -eq 'profile-not-found') 'report missing targets'
    $blocked = $false
    try { Get-StandaloneSwitchPlan -Context $context '..\outside' | Out-Null } catch { $blocked = $true }
    Assert-True $blocked 'reject profile path traversal'

    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = '1'
    Assert-True ((Get-StandaloneSwitchPlan -Context $context).Clients.Count -eq 1) 'plan must not hide clients through the legacy test-only guard bypass'
    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = $null
    $script:mockProcesses = @($acp)
    $blocked = $false
    try { Assert-CodexClientsStopped -Context $context } catch { $blocked = $true }
    Assert-True $blocked 'the existing switch guard must include standalone ACP processes'
    $script:queryFailed = $true
    # The functional core runs even when OS discovery is unavailable. Supply
    # observations explicitly; neither environment nor profile-store state is read.
    $observations = @($customHost, $customBridge, $codex, $toolChild)
    $before = $observations | ConvertTo-Json -Depth 5 -Compress
    $targetObservation = [pscustomobject]@{ Name='observed-profile'; Exists=$true; AuthenticationChecked=$false }
    $purePlan = New-SwitchPlan -Processes $observations -TargetProfile $targetObservation
    Assert-True ($purePlan.Clients.Count -eq 1) 'pure planner must work without querying Windows'
    Assert-True ($purePlan.TargetProfile.Name -eq 'observed-profile') 'pure planner must use supplied target observation without accessing a profile file'
    Assert-True (($observations | ConvertTo-Json -Depth 5 -Compress) -eq $before) 'planning must not mutate the process snapshot'
    $repeat = New-SwitchPlan -Processes $observations -TargetProfile $targetObservation
    Assert-True (($repeat | ConvertTo-Json -Depth 8 -Compress) -eq ($purePlan | ConvertTo-Json -Depth 8 -Compress)) 'same observations must produce the same plan'
    $blocked = $false
    try { Get-StandaloneSwitchPlan -Context $context | Out-Null } catch { $blocked = $true }
    Assert-True $blocked 'failed discovery must not produce an empty/safe plan'

    Write-Host 'All switch plan tests passed.' -ForegroundColor Green
} finally {
    $env:CODEX_HOME = $oldCodexHome
    $env:CODEX_SWITCH_HOME = $oldSwitchHome
    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = $oldSkip
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'codex-switch-plan-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
