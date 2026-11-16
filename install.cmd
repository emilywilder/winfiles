@echo off
rem Installs a host's configuration on a bootstrapped machine. Run it from an
rem unelevated terminal, in cmd or PowerShell, after bootstrap.cmd:
rem
rem     .\install.cmd iris
rem
rem Its arguments go to `just install [host] [user]`; run it again after the
rem restart it asks for. Like bootstrap.cmd, it's the stable way in: what runs
rem behind it can change without changing how it's called. It runs
rem scripts\Invoke-Clean.ps1 under Windows PowerShell 5.1, which reads PATH and
rem the other variables from the registry, so it works in the terminal that ran
rem the bootstrap, and runs just from mise.toml. A .cmd file runs whatever the
rem execution policy, so this bypasses it for that one process.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-Clean.ps1" just install %*
set code=%ERRORLEVEL%
popd
exit /b %code%
