$testRepository = Split-Path -Parent $PSScriptRoot
foreach ($moduleName in @('SwitchContext','ProfileStore','CodexRuntime','AccountService','ConsoleUI')) {
    Import-Module (Join-Path $testRepository "src/$moduleName.psm1") -DisableNameChecking
}
Import-Module (Join-Path $testRepository 'src/ProcessAnalysis.psm1') -DisableNameChecking

function New-TestContext {
    New-SwitchContext -ScriptRoot $testRepository -Report ${function:Write-ConsoleNotice} `
        -SkipClientCheck:($env:CODEX_SWITCH_TEST_SKIP_APP_CHECK -eq '1') `
        -ReadProcesses {
            Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate,CommandLine -ErrorAction Stop
        }
}

function Invoke-TestCommand {
    param([Parameter(Position=0)][string]$Command, [Parameter(Position=1)][string]$Name, [Parameter(Position=2)][string]$NewName, [switch]$Json)
    $invocationContext = New-TestContext
    Invoke-CodexSwitchCommand -Context $invocationContext -Command $Command -Name $Name -NewName $NewName -Json:$Json -Manual:($Command -eq 'switch')
}
