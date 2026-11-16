@echo off
rem Installs a host's configuration on a bootstrapped machine. Run it from an
rem unelevated terminal, in cmd or PowerShell, after bootstrap.cmd:
rem
rem     .\install.cmd iris
rem
rem Its arguments go to `just install [host] [user]`. When the install stops for a
rem restart, it continues by itself at the next sign-in. Like bootstrap.cmd, it's the stable way in: what runs
rem behind it can change without changing how it's called. It runs
rem scripts\Invoke-Install.ps1 under Windows PowerShell 5.1, which runs
rem scripts\Start-Clean.ps1. That reads PATH from the registry, so it finds mise in
rem the terminal that ran the bootstrap, and starts Invoke-Clean.ps1 under mise's
rem pwsh to run just from mise.toml. A .cmd file runs whatever the execution
rem policy, so this bypasses it for that one process.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-Install.ps1" %*
set code=%ERRORLEVEL%
popd
exit /b %code%
