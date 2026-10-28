param([ValidateSet('x64','x86')][string]$Platform='x64')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src/WindowsRestart.psm1') -DisableNameChecking
$backend=New-WindowsRestartBackend
$testRoot=Join-Path $env:TEMP ('codex-native-test-'+[guid]::NewGuid().ToString('N'))
$session=$null
function Assert-True([bool]$Condition,[string]$Message) {if (-not $Condition) {throw "Assertion failed: $Message"}}
function Wait-For([scriptblock]$Check) {
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while (-not (& $Check)) {if ([datetime]::UtcNow -ge $deadline) {throw 'Fixture wait timed out'}; Start-Sleep -Milliseconds 100}
}
function Start-Fixture([string]$Arguments) {
    $info=[Diagnostics.ProcessStartInfo]::new($executable,$Arguments)
    $info.UseShellExecute=$false; $info.WorkingDirectory=$workdir; $info.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($info)
    $fixtureId=$p.Id; $p.Dispose()
    Wait-For { $e=& $backend.Inspect $fixtureId; $e.HasWindow }
    $e=& $backend.Inspect $fixtureId
    [pscustomobject]@{Id=$fixtureId;StartTime=$e.StartTime;Kind='window'}
}
try {
    $workdir=Join-Path $testRoot 'workspace with spaces'
    New-Item -ItemType Directory -Path $workdir -Force | Out-Null
    $executable=Join-Path $testRoot 'RestartFixture.exe'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    & $compiler /nologo /target:winexe "/platform:$Platform" /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$executable" (Join-Path $PSScriptRoot 'fixtures/RestartFixture.cs')
    Assert-True ($LASTEXITCODE -eq 0) 'fixture must compile'
    # Literal shell-looking arguments must remain literal; no shell replay.
    $target=Start-Fixture 'fallback "two words" "$(not-a-command)" "`literal`"'
    $observed=Get-CimInstance Win32_Process -Filter "ProcessId=$($target.Id)"
    $recipe=& $backend.Capture $target $observed
    Assert-True ($recipe.WorkingDirectory.TrimEnd('\') -eq $workdir) 'capture original cwd'
    Assert-True ($recipe.Arguments -eq 'fallback "two words" "$(not-a-command)" "`literal`"') 'preserve arguments verbatim'
    $stale=[pscustomobject]@{Id=$target.Id;StartTime=$target.StartTime+1;Kind='window'}
    $rejected=$false
    try {& $backend.Close $stale} catch {$rejected=$true}
    Assert-True ($rejected -and (& $backend.Alive $target)) 'stale identity must not terminate process'
    & $backend.Close $target
    Wait-For {-not (& $backend.Alive $target)}
    $reopened=& $backend.Launch $recipe
    Wait-For {Test-Path -LiteralPath (Join-Path $testRoot "$reopened.started")}
    $lines=@(Get-Content -LiteralPath (Join-Path $testRoot "$reopened.started"))
    Assert-True ($lines[0] -eq $workdir -and $lines[1] -eq 'fallback|two words|$(not-a-command)|`literal`') 'real reopen must retain cwd and literal args'

    $recipe.Arguments='isolated-output'
    $isolated=& $backend.Launch $recipe
    $stdioPath=Join-Path $testRoot "$isolated.stdio"
    Wait-For {Test-Path -LiteralPath $stdioPath}
    $stdio=@(Get-Content -LiteralPath $stdioPath)
    Assert-True ($stdio[3] -eq '0' -and $stdio[1] -eq '0' -and $stdio[2] -eq '0') 'normal Shell launch must not inherit the Switch console or stdout/stderr pipes'

    $target=Start-Fixture 'cancel'
    & $backend.Close $target
    Start-Sleep -Milliseconds 300
    Assert-True (& $backend.Alive $target) 'canceled GUI close must leave process alive'

    $target=Start-Fixture 'tray'
    & $backend.Close $target
    Wait-For {-not (& $backend.Inspect $target.Id).HasWindow}
    Assert-True (& $backend.Alive $target) 'tray fixture must remain in background after normal close'
    $target.Kind='console'
    & $backend.Close $target
    Wait-For {-not (& $backend.Alive $target)}

    $target=Start-Fixture 'registered'
    Assert-True ((& $backend.Inspect $target.Id).Registered) 'fixture registration must be detected'
    $session=& $backend.Begin @($target)
    $members=@(& $backend.Members $session)
    Assert-True ($members.Count -eq 1 -and $members[0].Restartable) 'native scope must contain only fixture'
    $shutdownCode=& $backend.Shutdown $session
    Assert-True ($shutdownCode -eq 0) 'native normal shutdown must succeed'
    Wait-For {-not (& $backend.Alive $target)}
    $restartCode=& $backend.Restart $session
    Assert-True ($restartCode -eq 0) 'native restart must succeed'
    $members=@(& $backend.Members $session)
    Assert-True (($members[0].Status -band 8) -ne 0) 'Windows must confirm restart'
    & $backend.End $session; $session=$null
    Write-Host 'All Windows native restart tests passed.' -ForegroundColor Green
} finally {
    if ($null -ne $session) {try {& $backend.Restart $session | Out-Null} finally {& $backend.End $session}}
    # Only this test's executable in its verified temp folder can be terminated.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'codex-native-test-*') {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='RestartFixture.exe'")) {
            if ($process.ExecutablePath -eq (Join-Path $resolved 'RestartFixture.exe')) {
                $e=& $backend.Inspect ([int]$process.ProcessId)
                [CodexSwitch.FallbackNative]::Close([int]$process.ProcessId,$e.StartTime,$true)
            }
        }
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
