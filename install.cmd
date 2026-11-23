@echo off
rem Installs a host's configuration on a bootstrapped machine. Run it from an
rem unelevated terminal, in cmd or PowerShell, after bootstrap.cmd:
rem
rem     .\install.cmd iris
rem
rem Its arguments go to `winfiles.ps1 install [host] [user]`. When the install
rem stops for a restart, it continues at the next sign-in, once Enter is pressed.
rem Like bootstrap.cmd, it's the stable way in: what runs behind it can change
rem without changing how it's called. It runs scripts\Invoke-Install.ps1 under
rem Windows PowerShell 5.1, which runs scripts\Start-Clean.ps1. That reads PATH
rem from the registry, so it finds mise in the terminal that ran the bootstrap,
rem and starts Invoke-Clean.ps1 under mise's pwsh to run winfiles.ps1. A .cmd
rem file runs whatever the execution policy, so this bypasses it for that one
rem process.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-Install.ps1" %*
set code=%ERRORLEVEL%
popd
exit /b %code%
