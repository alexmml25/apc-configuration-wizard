@echo off
rem ============================================================================
rem  APC Configuration Wizard - one-click launcher
rem  Double-click to start the wizard. It asks for administrator rights, unblocks
rem  the scripts (Windows blocks files copied or downloaded from elsewhere) and
rem  starts APC_ConfigWizard.ps1. If the wizard stops with an error, this window
rem  stays open so the message can be read.
rem ============================================================================
setlocal

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
title APC Configuration Wizard
echo Starting the APC Configuration Wizard from %~dp0
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0APC_ConfigWizard.ps1"
if errorlevel 1 (
    echo.
    echo The wizard stopped with an error - see the messages above.
    pause
)
endlocal
