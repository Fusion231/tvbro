@echo off
setlocal
rem Prefer Windows PowerShell modules when launched from a PowerShell 7 terminal.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%PSModulePath%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-all.ps1" %*
set "releaseExit=%errorlevel%"
if "%~1"=="" pause
endlocal & exit /b %releaseExit%
