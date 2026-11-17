@rem A stand-in for winget.exe (see fake-winget.ps1). Tests put this folder first on PATH.
@pwsh -NoLogo -NoProfile -NonInteractive -File "%~dp0fake-winget.ps1" %*
@exit /b %ERRORLEVEL%
