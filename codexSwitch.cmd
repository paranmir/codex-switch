@echo off
where pwsh.exe >nul 2>nul
if %errorlevel% equ 0 (
  pwsh.exe -NoLogo -NoProfile -File "%~dp0codex-switch.ps1" %*
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" %*
)
