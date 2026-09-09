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

    $fakeBin = Join-Path $testRoot 'fake-bin'
    $fakeLoginAuth = Join-Path $testRoot 'next-login.auth.json'
    $fakeCallLog = Join-Path $testRoot 'codex-calls.log'
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    [IO.File]::WriteAllText($fakeLoginAuth, (New-TestAuth 'account-c' 'c@example.test'), [Text.UTF8Encoding]::new($false))
    $fakeCodex = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AllArgs)
$Action = $AllArgs | Select-Object -First 1
$Subaction = $AllArgs | Select-Object -Skip 1 -First 1
$authPath = Join-Path $env:CODEX_HOME 'auth.json'
Add-Content -LiteralPath $env:CODEX_TEST_CALL_LOG -Value ($AllArgs -join ' ')
if ($Action -eq 'app-server') {
    while ($null -ne ($line = [Console]::ReadLine())) {
        $request = $line | ConvertFrom-Json
        if ($request.method -eq 'initialized') { continue }
        Add-Content -LiteralPath $env:CODEX_TEST_CALL_LOG -Value $request.method
        $result = @{}
        if ($request.method -eq 'account/read') {
            $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
            if ($auth.tokens.refresh_token -eq 'invalid-test-token') {
                $result = @{ account=$null; requiresOpenaiAuth=$true }
            } else {
                $auth.tokens.refresh_token = $auth.tokens.refresh_token + '-rotated'
                [IO.File]::WriteAllText($authPath, ($auth | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
                $result = @{ account=@{type='chatgpt'}; requiresOpenaiAuth=$true }
            }
        }
        if ($request.method -eq 'account/rateLimits/read' -and $env:CODEX_TEST_NETWORK_FAILURE -eq '1') {
            [Console]::WriteLine((@{ id=$request.id; error=@{code=-32603; message='Network failed; secret-token-must-not-leak'} } | ConvertTo-Json -Depth 5 -Compress))
        } else {
            [Console]::WriteLine((@{ id=$request.id; result=$result } | ConvertTo-Json -Depth 5 -Compress))
        }
    }
    exit 0
}
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
    [IO.File]::WriteAllText((Join-Path $fakeBin 'fake-codex.ps1'), $fakeCodex, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'codex.cmd'),
        ('@echo off' + "`r`n" + '"' + [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName + '" -NoLogo -NoProfile -File "%~dp0fake-codex.ps1" %*' + "`r`nexit /b %errorlevel%`r`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $env:CODEX_TEST_LOGIN_AUTH = $fakeLoginAuth
    $env:CODEX_TEST_CALL_LOG = $fakeCallLog
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH

    Write-TestAuth 'account-a' 'a@example.test'
    & $scriptPath save alpha *> $null
    Write-TestAuth 'account-b' 'b@example.test'
    & $scriptPath save beta *> $null

    $betaPath = Join-Path $env:CODEX_SWITCH_HOME 'profiles\beta.auth.json'
    $betaHash = (Get-FileHash -LiteralPath $betaPath -Algorithm SHA256).Hash

    # Simulate Codex Desktop restoring account A while the registry still says beta.
    Write-TestAuth 'account-a' 'a@example.test'
    $authPath = Join-Path $env:CODEX_HOME 'auth.json'
    $freshAuth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
    $freshAuth.tokens.refresh_token = 'newer-test-refresh-token'
    [IO.File]::WriteAllText($authPath, ($freshAuth | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $freshAlphaHash = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash
    $whoami = (& $scriptPath whoami 3>&1 6>&1 | Out-String)
    Assert-True ($whoami -match 'differs from saved active profile') 'whoami should report a registry/auth mismatch'
    Assert-True ($whoami -match 'Profile: alpha') 'whoami should identify the actual matching profile despite a stale registry'
    $list = (& $scriptPath list 6>&1 | Out-String)
    Assert-True ($list -match '(?m)^\* alpha\s') 'list should mark the actual account as current'
    Assert-True ($list -notmatch '(?m)^\* beta\s') 'list must not mark the stale registry account as current'

    $switchOutput = (& $scriptPath switch alpha 3>&1 | Out-String)
    Assert-True ($switchOutput -match 'was not written over') 'switch should warn instead of overwriting the recorded active profile'
    Assert-True (((Get-FileHash -LiteralPath $betaPath -Algorithm SHA256).Hash) -eq $betaHash) 'mismatched active profile must remain unchanged'
    Assert-True ((Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json).tokens.refresh_token -eq 'newer-test-refresh-token-rotated') 'switching to the current account must use the newly rotated credentials'
    Assert-True (((Get-FileHash -LiteralPath (Join-Path $env:CODEX_SWITCH_HOME 'profiles\alpha.auth.json') -Algorithm SHA256).Hash) -eq (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash) 'matching profile should receive refreshed credentials even with a stale active name'

    & $scriptPath save alpha-copy *> $null
    $doctor = (& $scriptPath doctor 3>&1 | Out-String)
    Assert-True ($doctor -match 'same Codex account') 'doctor should report duplicate account profiles'

    # Adding from an account that already exists under any profile must reuse it,
    # even when the registry's active name is stale. It must not create recovered-*.
    & $scriptPath add gamma *> $null
    $codexCalls = @(Get-Content -LiteralPath $fakeCallLog)
    Assert-True (-not ($codexCalls -match '^logout(?:\s|$)')) 'add must not call codex logout and invalidate the profile it just saved'
    Assert-True ([bool]($codexCalls -match '^login(?:\s|$)')) 'add should start a new Codex login'
    $config = Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml')
    Assert-True ($config -match '(?m)^cli_auth_credentials_store\s*=\s*"file"') 'add should enforce file-based credential storage'
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

    # A login changed outside the switcher must be preserved before switching away.
    Write-TestAuth 'account-unsaved' 'unsaved@example.test'
    $unsavedHash = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash
    & $scriptPath switch gamma *> $null
    $recovered = @(Get-ChildItem -LiteralPath (Join-Path $env:CODEX_SWITCH_HOME 'profiles') -Filter 'recovered-*.auth.json')
    Assert-True ($recovered.Count -eq 1) 'switch should preserve an otherwise unsaved login once'
    Assert-True (((Get-FileHash -LiteralPath $recovered[0].FullName -Algorithm SHA256).Hash) -eq $unsavedHash) 'recovery must retain the complete unsaved login'

    # Config edits must replace ephemeral mode and respect TOML table boundaries.
    $configPath = Join-Path $env:CODEX_HOME 'config.toml'
    foreach ($mode in @('file','keyring','auto','ephemeral')) {
        [IO.File]::WriteAllText($configPath, "cli_auth_credentials_store = `"$mode`"`r`nmodel = `"test-model`"`r`n", [Text.UTF8Encoding]::new($false))
        & $scriptPath setup *> $null
        $config = Get-Content -Raw -LiteralPath $configPath
        Assert-True ([regex]::Matches($config, '(?m)^cli_auth_credentials_store\s*=').Count -eq 1) 'setup must not create duplicate root keys'
        Assert-True ($config -match '(?m)^cli_auth_credentials_store = "file"\r?$') 'setup should select file mode'
        Assert-True ($config -match '(?m)^model = "test-model"\r?$') 'setup must preserve adjacent config settings'
    }
    $tableConfig = "[profiles.example]`r`ncli_auth_credentials_store = `"file`"`r`n"
    [IO.File]::WriteAllText($configPath, $tableConfig, [Text.UTF8Encoding]::new($false))
    & $scriptPath setup *> $null
    $config = Get-Content -Raw -LiteralPath $configPath
    Assert-True ($config.StartsWith('cli_auth_credentials_store = "file"')) 'a table-local setting must not prevent adding a root setting'
    Assert-True ($config.EndsWith($tableConfig)) 'setup must preserve existing TOML tables'

    # Exercise switch's guard with Desktop absent and a CLI or IDE server present.
    . $scriptPath help *> $null

    # Expired/revoked logins must fail before changing the active account.
    $invalidPath = Get-ProfilePath 'invalid'
    $invalidAuth = New-TestAuth 'account-invalid' 'invalid@example.test' | ConvertFrom-Json
    $invalidAuth.tokens.refresh_token = 'invalid-test-token'
    Write-Utf8NoBom $invalidPath ($invalidAuth | ConvertTo-Json -Depth 4)
    $null = Read-Registry
    $beforeInvalid = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash
    $failed = $false
    try { Switch-Profile 'invalid' *> $null } catch { $failed = $_.Exception.Message -match 'saved login could not be refreshed' }
    Assert-True $failed 'invalid refresh tokens must not be reported as successful switches'
    Assert-True ((Read-Registry).active -eq 'gamma') 'invalid target must not become active'
    Assert-True ((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash -eq $beforeInvalid) 'invalid target must not replace the working login'

    # If validation fails after rotation, keep the rotated profile for a retry.
    $env:CODEX_TEST_NETWORK_FAILURE = '1'
    $alphaPath = Get-ProfilePath 'alpha'
    $beforeRotation = (Get-Content -Raw -LiteralPath $alphaPath | ConvertFrom-Json).tokens.refresh_token
    $failed = $false
    try { Switch-Profile 'alpha' *> $null } catch {
        $failed = $_.Exception.Message -match 'RPC code'
        Assert-True ($_.Exception.Message -notmatch 'secret-token') 'upstream response bodies must not leak into errors'
    }
    Assert-True $failed 'network failures must not be reported as successful switches'
    Assert-True ((Get-Content -Raw -LiteralPath $alphaPath | ConvertFrom-Json).tokens.refresh_token -eq ($beforeRotation + '-rotated')) 'rotated profile credentials must survive a later network failure'
    Assert-True ((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash -eq $beforeInvalid) 'network failure must leave another active account intact'
    try { Switch-Profile 'gamma' *> $null } catch { }
    Assert-True ((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Get-ProfilePath 'gamma') -Algorithm SHA256).Hash) 'same-account rotation must also reach the live auth file on a later failure'
    $env:CODEX_TEST_NETWORK_FAILURE = $null
    Switch-Profile 'alpha' *> $null
    Switch-Profile 'gamma' *> $null
    Assert-True ((Read-Registry).active -eq 'gamma') 'a round trip must work using the updated credentials'
    Assert-True (@(Get-ChildItem -LiteralPath $DataRoot -Directory -Filter 'auth-check-*').Count -eq 0) 'completed checks must clean up their isolated homes'

    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = $null
    function Get-CimInstance {
        param([string]$ClassName, [string[]]$Property, [string]$ErrorAction)
        return $script:mockProcesses
    }
    $protectedPaths = @($authPath, $configPath, $RegistryPath, (Get-ProfilePath 'gamma'))
    $beforeGuard = @($protectedPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $parentProcess = [pscustomobject]@{ ProcessId=54321; ParentProcessId=0; Name='EditorHost.exe'; ExecutablePath='C:\AnyEditor\EditorHost.exe'; CreationDate=[datetime]'2026-01-01' }
    foreach ($clientPath in @('C:\Tools\Codex\codex.exe', 'C:\AnyEditor\extensions\codex.exe', 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe')) {
        $childProcess = [pscustomobject]@{ ProcessId=12345; ParentProcessId=54321; Name=[IO.Path]::GetFileName($clientPath); ExecutablePath=$clientPath; CreationDate=[datetime]'2026-01-02' }
        $script:mockProcesses = @($parentProcess, $childProcess)
        $blocked = $false
        try { Switch-Profile 'gamma' *> $null } catch {
            $blocked = $_.Exception.Message -match 'Codex clients are still running'
            Assert-True ($_.Exception.Message.Contains($clientPath)) 'the error should identify the remaining client executable'
            Assert-True ($_.Exception.Message -match 'parent: EditorHost.exe \(PID: 54321\)') 'the error should identify the actual parent without relying on editor-specific paths'
        }
        Assert-True $blocked "switch must refuse to change credentials while $clientPath is running"
    }
    $afterGuard = @($protectedPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-True (($beforeGuard -join ',') -eq ($afterGuard -join ',')) 'blocked switches must not modify credentials, profiles, registry, or config'
    $parentProcess.CreationDate = [datetime]'2026-01-03'
    $description = Get-CodexClientDescription @(Get-CodexClientProcesses)[0]
    Assert-True ($description -notmatch 'EditorHost.exe') 'a reused parent PID must not identify an unrelated process as the owner'
    $script:mockProcesses = @($childProcess)
    $description = Get-CodexClientDescription @(Get-CodexClientProcesses)[0]
    Assert-True ($description -match 'parent PID: 54321 \(exited or unavailable\)') 'a remaining client should still be reported when its parent has exited'
    $script:mockProcesses = @($parentProcess)
    Assert-CodexClientsStopped
    $script:mockProcesses = @()
    Assert-CodexClientsStopped
    Remove-Item -LiteralPath 'Function:\Get-CimInstance'

    Write-Host 'All Codex Switch tests passed.' -ForegroundColor Green
} finally {
    $env:PATH = $originalPath
    $env:OS = $originalOS
    $env:CODEX_SWITCH_TEST_SKIP_APP_CHECK = $originalSkipAppCheck
    $env:CODEX_TEST_LOGIN_AUTH = $null
    $env:CODEX_TEST_CALL_LOG = $null
    $env:CODEX_TEST_NETWORK_FAILURE = $null
    $env:CODEX_HOME = $null
    $env:CODEX_SWITCH_HOME = $null
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        ([IO.Path]::GetFileName($resolvedTestRoot) -like 'codex-switch-test-*')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
