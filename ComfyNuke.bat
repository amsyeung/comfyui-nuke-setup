@echo off
rem Double-click entry point. Runs comfynuke.ps1 without changing the system execution policy.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0comfynuke.ps1" %*
if errorlevel 1 pause
