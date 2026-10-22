@echo off
setlocal

cls
title Basetune UI
echo Starting Basetune UI...

where pwsh >nul 2>nul
if %errorlevel% neq 0 (
    echo PowerShell 7+ is required!
    timeout /t 5 /nobreak >nul
    exit /b 1
)

start /min "" pwsh -NoLogo -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0BasetuneUI.ps1"
timeout /t 1 /nobreak > nul
exit /b
