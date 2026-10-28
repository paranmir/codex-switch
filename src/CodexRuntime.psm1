Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ProcessAnalysis.psm1') -DisableNameChecking

function Get-CodexExecutable {
    $cli = Get-Command codex -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cli) { return $cli.Source }
    return $null
}

function Invoke-CodexLogin($Context, [switch]$StatusOnly) {
    $cli = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = if (Test-Path -LiteralPath $Context.CodexHome -PathType Container) { $Context.CodexHome } else { $Context.ScriptRoot }
    $info.EnvironmentVariables['CODEX_HOME'] = $Context.CodexHome
    $info.EnvironmentVariables.Remove('OPENAI_API_KEY')
    $info.EnvironmentVariables.Remove('CODEX_API_KEY')
    if ([IO.Path]::GetExtension($cli.Source) -ieq '.exe') {
        $info.FileName = $cli.Source
        $info.Arguments = if ($StatusOnly) { 'login status' } else { 'login -c cli_auth_credentials_store=\"file\"' }
    } else {
        $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $info.EnvironmentVariables['CODEX_SWITCH_CLI'] = $cli.Source
        $launcher = if ($StatusOnly) { '& $env:CODEX_SWITCH_CLI login status; exit $LASTEXITCODE' } else { '& $env:CODEX_SWITCH_CLI login -c ''cli_auth_credentials_store="file"''; exit $LASTEXITCODE' }
        $info.Arguments = '-NoLogo -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $process.WaitForExit()
        if (-not $StatusOnly -and ($process.ExitCode -ne 0 -or -not (Test-CurrentAuth $Context))) { throw 'Codex login did not complete.' }
    } finally { $process.Dispose() }
}

function Get-SwitchProcessSnapshot([object]$Context) {
    return @(& $Context.ReadProcesses)
}

function Get-CodexClientProcesses([object]$Context) {
    if ($Context.SkipClientCheck) { return @() }
    return @(Get-CodexProcessInventory @(Get-SwitchProcessSnapshot -Context $Context))
}

function Get-CodexClientDescription([object]$Client) {
    $description = "$($Client.ProcessName) (PID: $($Client.Id))"
    if ($Client.ParentName) {
        $description += "; parent: $($Client.ParentName) (PID: $($Client.ParentId))"
    } elseif ($Client.ParentId) {
        $description += "; parent PID: $($Client.ParentId) (exited or unavailable)"
    }
    if ($Client.Path) { $description += " - $($Client.Path)" }
    return $description
}

function Assert-CodexClientsStopped([object]$Context) {
    $running = @(Get-CodexClientProcesses -Context $Context)
    if ($running.Count -eq 0) { return }
    $details = ($running | Sort-Object Id | ForEach-Object { Get-CodexClientDescription $_ }) -join "`n  "
    throw "Codex clients are still running:`n  $details`nClose the listed apps or their Codex extension completely, then retry. Existing processes can keep the old login and write it back to auth.json."
}

function Invoke-CodexAuthRequest($Process, [int]$Id, [string]$Method, $Params) {
    $Process.StandardInput.WriteLine((@{ id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Depth 6 -Compress))
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ($true) {
        $read = $Process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(0, [int]($deadline - [datetime]::UtcNow).TotalMilliseconds)
        if (-not $read.Wait($remaining)) { throw 'Codex authentication check timed out. Check connectivity and retry.' }
        if ($null -eq $read.Result) { throw 'Codex authentication check exited before responding. Check your Codex installation.' }
        $message = $read.Result | ConvertFrom-Json
        if (-not $message.PSObject.Properties['id'] -or $message.id -ne $Id) { continue }
        if ($message.PSObject.Properties['error']) {
            # Do not relay upstream bodies, which may contain sensitive values.
            throw "Codex could not complete $Method (RPC code $($message.error.code)). Check connectivity or sign in again if the saved login has expired."
        }
        return $message.result
    }
}

function Confirm-CodexProfileAuth([object]$Context, [string]$ProfilePath, [bool]$RefreshToken = $true) {
    $cli = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
    $stage = Join-Path $($Context.DataRoot) ('auth-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $stagedAuth = Join-Path $stage 'auth.json'
    Copy-Item -LiteralPath $ProfilePath -Destination $stagedAuth
    Write-Utf8NoBom (Join-Path $stage 'config.toml') "cli_auth_credentials_store = `"file`"`n"
    $process = [Diagnostics.Process]::new()
    $started = $false
    $preserved = $false
    try {
        $info = $process.StartInfo
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.WorkingDirectory = $stage
        $info.EnvironmentVariables['CODEX_HOME'] = $stage
        $info.EnvironmentVariables.Remove('OPENAI_API_KEY')
        $info.EnvironmentVariables.Remove('CODEX_API_KEY')
        if ([IO.Path]::GetExtension($cli.Source) -ieq '.exe') {
            $info.FileName = $cli.Source
            $info.Arguments = 'app-server'
        } else {
            # Support npm command wrappers and PowerShell launchers without
            # interpolating paths or credentials into shell source.
            $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $info.EnvironmentVariables['CODEX_SWITCH_CLI'] = $cli.Source
            $launcher = '& $env:CODEX_SWITCH_CLI app-server'
            $info.Arguments = '-NoLogo -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
        }
        $started = $process.Start()
        $stderr = $process.StandardError.ReadToEndAsync()
        $null = Invoke-CodexAuthRequest $process 0 'initialize' @{clientInfo=@{name='codex_switch'; version='1.0'}}
        $process.StandardInput.WriteLine('{"method":"initialized"}')
        $account = Invoke-CodexAuthRequest $process 1 'account/read' @{refreshToken=$RefreshToken}
        if (-not $account.account) {
            throw 'The saved login could not be refreshed. Sign in to this account once and save it again; switching was not applied.'
        }
        if ($account.account.type -eq 'chatgpt') {
            $null = Invoke-CodexAuthRequest $process 2 'account/rateLimits/read' @{}
        }
    } finally {
        if ($started) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(3000)) { $process.Kill(); $process.WaitForExit() }
        }
        $process.Dispose()
        # Refresh tokens rotate. Preserve any refreshed file even if a later
        # network check failed, otherwise a retry would reuse the old token.
        if (Test-SameAuthIdentity $ProfilePath $stagedAuth) {
            $temp = "$ProfilePath.tmp"
            Copy-Item -LiteralPath $stagedAuth -Destination $temp -Force
            Move-Item -LiteralPath $temp -Destination $ProfilePath -Force
            $preserved = $true
        }
        if ($preserved) {
            $resolvedStage = [IO.Path]::GetFullPath($stage)
            $resolvedRoot = [IO.Path]::GetFullPath($($Context.DataRoot)).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($resolvedStage.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolvedStage) -like 'auth-check-*') {
                Remove-Item -LiteralPath $resolvedStage -Recurse -Force
            }
        } else {
            throw "Codex authentication could not be preserved safely. Recovery files were retained at: $stage"
        }
    }
}

Export-ModuleMember -Function Get-CodexExecutable, Invoke-CodexLogin, Get-SwitchProcessSnapshot, Get-CodexClientProcesses, Get-CodexClientDescription, Assert-CodexClientsStopped, Invoke-CodexAuthRequest, Confirm-CodexProfileAuth
