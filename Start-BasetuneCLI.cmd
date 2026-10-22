@echo off
setlocal

cls
title Basetune CLI
echo Starting Basetune CLI...

where pwsh >nul 2>nul
if %errorlevel% neq 0 (
    echo PowerShell 7+ is required!
    timeout /t 5 /nobreak >nul
    exit /b 1
)

start "Basetune CLI" pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BasetuneCLI.ps1"
timeout /t 1 /nobreak > nul
exit /b