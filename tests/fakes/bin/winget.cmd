@rem A stand-in for winget.exe, for Get-ManualInstaller.ps1: appends its arguments to calls.txt in the folder named by
@rem WINFILES_FAKE_WINGET_CLI and exits with the code in exitcode.txt there, 0 without it. It downloads nothing.
@echo %*>> "%WINFILES_FAKE_WINGET_CLI%\calls.txt"
@if exist "%WINFILES_FAKE_WINGET_CLI%\exitcode.txt" (
    @set /p WINFILES_FAKE_EXIT=<"%WINFILES_FAKE_WINGET_CLI%\exitcode.txt"
) else (
    @set WINFILES_FAKE_EXIT=0
)
@exit /b %WINFILES_FAKE_EXIT%
