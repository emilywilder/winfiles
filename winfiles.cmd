@echo off
rem Runs any winfiles.ps1 command, from cmd or PowerShell, on a machine where
rem winfiles.ps1 can't run yet: after bootstrap.cmd, before the configuration
rem has installed its own pwsh. For example:
rem
rem     .\winfiles.cmd switch vm-quick
rem
rem Its arguments are winfiles.ps1's. It runs scripts\Start-Winfiles.ps1 under
rem Windows PowerShell 5.1, which reads PATH from the registry, so it finds mise
rem in the terminal that ran the bootstrap, and starts Invoke-Clean.ps1 under
rem mise's pwsh to run winfiles.ps1 in a clean environment. A .cmd file runs
rem whatever the execution policy, so this bypasses it for that one process.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Winfiles.ps1" %*
set code=%ERRORLEVEL%
popd
exit /b %code%
