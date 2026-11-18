@rem A stand-in for gsudo.exe (see fake-gsudo.ps1). A test passes this file as the gsudo to run.
@pwsh -NoLogo -NoProfile -NonInteractive -File "%~dp0fake-gsudo.ps1" %*
@exit /b %ERRORLEVEL%
