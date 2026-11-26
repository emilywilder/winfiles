@echo off
rem Installs a host's configuration on a bootstrapped machine. Run it from an
rem unelevated terminal, in cmd or PowerShell, after bootstrap.cmd:
rem
rem     .\install.cmd iris
rem
rem Its arguments go to `winfiles.ps1 switch [host] [user] --restart`: a fresh
rem install restarts Windows itself when it needs to, and continues at the next
rem sign-in, once Enter is pressed. `.\winfiles.cmd switch` without --restart
rem stops for the restart instead, for you to restart and run it again.
rem Like bootstrap.cmd, it's the stable way in: what runs behind it can change
rem without changing how it's called. It runs winfiles.cmd, which finds mise
rem and runs winfiles.ps1 in a clean environment.
call "%~dp0winfiles.cmd" switch --restart %*
exit /b %ERRORLEVEL%
