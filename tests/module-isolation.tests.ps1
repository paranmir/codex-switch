. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('codex-switch-isolation-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-FakeCurrentAuth($Context, [string]$Identity) {
    New-Item -ItemType Directory -Path $Context.CodexHome -Force | Out-Null
    $auth = @{ auth_mode='chatgpt'; tokens=@{ id_token='invalid-test-payload'; account_id=$Identity; access_token='fake-access'; refresh_token='fake-refresh' } }
    Write-Utf8NoBom $Context.AuthPath ($auth | ConvertTo-Json -Depth 4)
}

try {
    $first = New-SwitchContext -ScriptRoot $testRepository -CodexHome (Join-Path $testRoot 'first-home') -DataRoot (Join-Path $testRoot 'first-store') -IsWindows:$false -ReadProcesses { @() }
    $second = New-SwitchContext -ScriptRoot $testRepository -CodexHome (Join-Path $testRoot 'second-home') -DataRoot (Join-Path $testRoot 'second-store') -IsWindows:$false -ReadProcesses { @() }
    # The real entry point creates a context but help must not initialize a store.
    Invoke-CodexSwitchCommand -Context $first -Command help *> $null
    Invoke-CodexSwitchCommand -Context $second -Command plan -Json | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $testRoot)) 'constructing contexts, help and plan must not write state'

    Write-FakeCurrentAuth $first 'first-account'
    Write-FakeCurrentAuth $second 'second-account'
    Save-Current -Context $first -ProfileName account -SetActive
    Save-Current -Context $second -ProfileName account -SetActive
    Assert-True ((Get-AccountView $first).Summary.IdentityKey -eq 'account:first-account') 'first context must retain its own account'
    Assert-True ((Get-AccountView $second).Summary.IdentityKey -eq 'account:second-account') 'second context must not inherit the first context paths'
    $secondHash = (Get-FileHash -LiteralPath (Get-ProfilePath $second account)).Hash
    Rename-Profile -Context $first -Old account -New renamed
    Assert-True ((Read-Registry $first).active -eq 'renamed') 'renaming an active profile must update its registry'
    Assert-True ((Read-Registry $second).active -eq 'account') 'renaming one context must not affect another'
    Assert-True ((Get-FileHash -LiteralPath (Get-ProfilePath $second account)).Hash -eq $secondHash) 'another context credential file must remain unchanged'
    Remove-Profile -Context $first -ProfileName renamed
    Assert-True (@(Get-ProfileViews $first).Count -eq 0) 'delete should remove the first context profile'
    Assert-True (@(Get-ProfileViews $second).Count -eq 1) 'delete must leave the second context intact'

    # Process discovery is injected per operation context, without replacing
    # globally named functions or requiring the CLI script to be dot-sourced.
    $first.ReadProcesses = { [pscustomobject]@{ ProcessId=321; ParentProcessId=0; Name='codex.exe'; ExecutablePath='C:\Fake\codex.exe'; CreationDate=[datetime]'2026-01-01'; CommandLine='' } }
    $blocked = $false
    try { Save-Current -Context $first -ProfileName blocked } catch { $blocked = $_.Exception.Message -match 'still running' }
    Assert-True $blocked 'a context with active clients must block credential mutations'
    Save-Current -Context $second -ProfileName another
    Assert-True (@(Get-ProfileViews $second).Count -eq 2) 'another context must continue to use its independent discovery provider'
    $blocked = $false
    try { Get-ProfilePath $second '..\outside' | Out-Null } catch { $blocked = $true }
    Assert-True $blocked 'repository boundary must reject profile path traversal'
    Write-Host 'All module isolation tests passed.' -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'codex-switch-isolation-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
