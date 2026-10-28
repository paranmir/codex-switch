[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu','whoami','list','add','save','switch','rename','remove','delete','files','setup','doctor','plan','status','help')]
    [string]$Command = 'menu',
    [Parameter(Position = 1)]
    [string]$Name,
    [Parameter(Position = 2)]
    [string]$NewName,
    [switch]$Json,
    [switch]$Manual
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/SwitchContext.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src/ConsoleUI.psm1') -DisableNameChecking

try {
    $context = New-SwitchContext -ScriptRoot $PSScriptRoot -Report ${function:Write-ConsoleNotice}
    Invoke-CodexSwitchCommand -Context $context -Command $Command -Name $Name -NewName $NewName -Json:$Json -Manual:$Manual
} catch {
    if ($Command -in @('plan','status') -and $Json) {
        @{ SchemaVersion=1; ReadOnly=$true; Status='inspection-failed'; CanAutoRestart=$false } | ConvertTo-Json -Compress
    } else {
        Write-Host "`nCould not complete the command: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
