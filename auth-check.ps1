# Validate through the installed Codex protocol, so Codex owns OAuth and refresh.
# Tokens travel only through local files/pipes and are never printed.
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

function Confirm-CodexProfileAuth([string]$ProfilePath, [bool]$RefreshToken = $true) {
    $cli = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
    $stage = Join-Path $DataRoot ('auth-check-' + [guid]::NewGuid().ToString('N'))
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
            $resolvedRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($resolvedStage.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolvedStage) -like 'auth-check-*') {
                Remove-Item -LiteralPath $resolvedStage -Recurse -Force
            }
        } else {
            throw "Codex authentication could not be preserved safely. Recovery files were retained at: $stage"
        }
    }
}
