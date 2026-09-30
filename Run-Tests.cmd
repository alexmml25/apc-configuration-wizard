@echo off
rem ============================================================================
rem  APC Configuration Wizard - run the automated tests
rem  Double-click to run tests\Run-Tests.ps1. Safe on the APC VM: the tests use a
rem  temporary folder and never touch installed files, services or databases.
rem ============================================================================
setlocal
cd /d "%~dp0"
title APC Configuration Wizard - tests
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Run-Tests.ps1"
echo.
pause
endlocal
