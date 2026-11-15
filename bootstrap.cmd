@echo off
rem Bootstraps winfiles on a fresh Windows 11 install. Run it from an unelevated
rem terminal, in cmd or PowerShell, before anything else is installed:
rem
rem     .\bootstrap.cmd iris
rem
rem The argument is the host configuration (-HostName); without it the computer
rem name is used. A .cmd file runs whatever the execution policy, which blocks
rem .ps1 scripts on a fresh install, so this only starts
rem scripts\Install-Winfiles.ps1 under Windows PowerShell 5.1 with the policy
rem bypassed for that one process. Run it again after the restart it asks for.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Winfiles.ps1" %*
exit /b %ERRORLEVEL%
