$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-switch.ps1'
$testRoot = Join-Path $env:TEMP ("codex-switch-test-" + [guid]::NewGuid().ToString('N'))
$env:CODEX_HOME = Join-Path $testRoot 'codex-home'
$env:CODEX_SWITCH_HOME = Join-Path $testRoot 'switch-home'
$originalPath = $env:PATH
$originalOS = $env:OS
$originalSkipAppCheck = $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK

function ConvertTo-Base64Url([string]$Text) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-TestAuth([string]$AccountId, [string]$Email) {
    $header = ConvertTo-Base64Url '{"alg":"none"}'
    $payload = ConvertTo-Base64Url (@{ sub = "user-$AccountId"; email = $Email } | ConvertTo-Json -Compress)
    return @{
        auth_mode = 'chatgpt'
        tokens = @{
            id_token = "$header.$payload.signature"
            access_token = 'test-access-token'
            refresh_token = 'test-refresh-token'
            account_id = $AccountId
        }
    } | ConvertTo-Json -Depth 4
}

function Write-TestAuth([string]$AccountId, [string]$Email) {
    New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $env:CODEX_HOME 'auth.json'),
        (New-TestAuth $AccountId $Email),
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
    # Keep doctor from invoking the machine's real Codex CLI.
    $env:PATH = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    # ACL behavior is machine-specific and outside these profile-integrity tests.
    $env:OS = 'CodexSwitchTest'
    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = '1'

    Write-TestAuth 'account-a' 'a@example.test'
    & $scriptPath save alpha *> $null
    Write-TestAuth 'account-b' 'b@example.test'
    & $scriptPath save beta *> $null

    $betaPath = Join-Path $env:CODEX_SWITCH_HOME 'profiles\beta.auth.json'
    $betaHash = (Get-FileHash -LiteralPath $betaPath -Algorithm SHA256).Hash

    # Simulate Codex Desktop restoring account A while the registry still says beta.
    Write-TestAuth 'account-a' 'a@example.test'
    $whoami = (& $scriptPath whoami 6>&1 | Out-String)
    Assert-True ($whoami -match 'differs from saved active profile') 'whoami should report a registry/auth mismatch'

    $switchOutput = (& $scriptPath switch alpha 3>&1 | Out-String)
    Assert-True ($switchOutput -match 'was not written over') 'switch should warn instead of overwriting the recorded active profile'
    Assert-True (((Get-FileHash -LiteralPath $betaPath -Algorithm SHA256).Hash) -eq $betaHash) 'mismatched active profile must remain unchanged'

    & $scriptPath save alpha-copy *> $null
    $doctor = (& $scriptPath doctor 3>&1 | Out-String)
    Assert-True ($doctor -match 'same Codex account') 'doctor should report duplicate account profiles'

    # Adding from an account that already exists under any profile must reuse it,
    # even when the registry's active name is stale. It must not create recovered-*.
    $fakeBin = Join-Path $testRoot 'fake-bin'
    $fakeLoginAuth = Join-Path $testRoot 'next-login.auth.json'
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    [IO.File]::WriteAllText($fakeLoginAuth, (New-TestAuth 'account-c' 'c@example.test'), [Text.UTF8Encoding]::new($false))
    $fakeCodex = @'
param([Parameter(Position = 0)][string]$Action, [Parameter(Position = 1)][string]$Subaction)
$authPath = Join-Path $env:CODEX_HOME 'auth.json'
if ($Action -eq 'logout') {
    if (Test-Path -LiteralPath $authPath) { Remove-Item -LiteralPath $authPath }
    exit 0
}
if ($Action -eq 'login') {
    if ($Subaction -eq 'status') { exit 0 }
    Copy-Item -Force -LiteralPath $env:CODEX_TEST_LOGIN_AUTH -Destination $authPath
    exit 0
}
exit 1
'@
    [IO.File]::WriteAllText((Join-Path $fakeBin 'codex.ps1'), $fakeCodex, [Text.UTF8Encoding]::new($false))
    $env:CODEX_TEST_LOGIN_AUTH = $fakeLoginAuth
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH
    & $scriptPath add gamma *> $null
    $registry = Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_SWITCH_HOME 'profiles.json') | ConvertFrom-Json
    $recoveredNames = @($registry.profiles.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $_ -like 'recovered-*' })
    Assert-True ($recoveredNames.Count -eq 0) 'add should reuse a matching profile instead of creating recovered-*'

    # Deleting a profile file in the data folder must update the registry on the next command.
    $alphaCopyPath = Join-Path $env:CODEX_SWITCH_HOME 'profiles\alpha-copy.auth.json'
    Remove-Item -LiteralPath $alphaCopyPath
    & $scriptPath list *> $null
    $registry = Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_SWITCH_HOME 'profiles.json') | ConvertFrom-Json
    Assert-True (-not $registry.profiles.PSObject.Properties['alpha-copy']) 'manual profile-file deletion should be reflected in the registry'

    & $scriptPath delete beta *> $null
    $registry = Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_SWITCH_HOME 'profiles.json') | ConvertFrom-Json
    Assert-True (-not $registry.profiles.PSObject.Properties['beta']) 'delete alias should remove the profile from the registry'
    Assert-True (-not (Test-Path -LiteralPath $betaPath)) 'delete alias should remove the profile file'

    Write-Host 'All Codex Switch tests passed.' -ForegroundColor Green
} finally {
    $env:PATH = $originalPath
    $env:OS = $originalOS
    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = $originalSkipAppCheck
    $env:CODEX_TEST_LOGIN_AUTH = $null
    $env:CODEX_HOME = $null
    $env:CODEX_SWITCH_HOME = $null
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        ([IO.Path]::GetFileName($resolvedTestRoot) -like 'codex-switch-test-*')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
