@echo off
rem Bootstraps winfiles on a fresh Windows 11 install. Run it from an unelevated
rem terminal, in cmd or PowerShell, before anything else is installed:
rem
rem     .\bootstrap.cmd
rem
rem It gets winget, mise and the repo's tools, then prints the command to run
rem next, `mise exec -- just install <host>`, which applies the configuration.
rem A .cmd file runs whatever the execution policy, which blocks .ps1 scripts on
rem a fresh install, so this only starts scripts\Install-Winfiles.ps1 under
rem Windows PowerShell 5.1 with the policy bypassed for that one process.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Winfiles.ps1" %*
exit /b %ERRORLEVEL%
