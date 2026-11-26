@echo off
rem Installs a host's configuration on a bootstrapped machine. Run it from an
rem unelevated terminal, in cmd or PowerShell, after bootstrap.cmd:
rem
rem     .\install.cmd iris
rem
rem Its arguments go to `winfiles.ps1 switch [host] [user] --restart`: a fresh
rem install restarts Windows itself when it needs to, and continues at the next
rem sign-in, once Enter is pressed. `winfiles.ps1 switch` without --restart
rem stops for the restart instead, for you to restart and run it again.
rem Like bootstrap.cmd, it's the stable way in: what runs behind it can change
rem without changing how it's called. It runs scripts\Start-Winfiles.ps1 under
rem Windows PowerShell 5.1. That reads PATH from the registry, so it finds mise in
rem the terminal that ran the bootstrap, and starts Invoke-Clean.ps1 under mise's
rem pwsh to run winfiles.ps1. A .cmd file runs whatever the execution policy, so
rem this bypasses it for that one process.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Winfiles.ps1" switch --restart %*
set code=%ERRORLEVEL%
popd
exit /b %code%
