@rem A stand-in for dsc.exe (see fake-dsc.ps1). Tests copy this folder and put the copy first on PATH.
@pwsh -NoLogo -NoProfile -NonInteractive -File "%~dp0fake-dsc.ps1" %*
@exit /b %ERRORLEVEL%
