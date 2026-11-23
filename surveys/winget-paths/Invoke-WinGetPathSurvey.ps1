#Requires -Version 7.4

<#
.SYNOPSIS
Runs the winget-paths survey: its installs unelevated, then elevated, or in the one context given (test VM only).

.DESCRIPTION
Sets WINFILES_WINGET_PATHS_CONTEXT, which winget-paths.Tests.ps1 reads, and runs that file through
scripts/Invoke-Test.ps1, which pins Pester: the survey borrows winfiles' scripts, but isn't one of its commands. A
context with failures stops the run before the next context. Start it
unelevated, under mise exec for dsc, from the VM's desktop, and answer the UAC prompts. See README.md.

.EXAMPLE
mise exec -- pwsh -NoProfile -File winget-paths/Invoke-WinGetPathSurvey.ps1 -Context elevated

From surveys/: runs every path with its installs elevated, through UAC.
#>
[CmdletBinding()]
param(
    # The contexts the installs run in, in order. By default, unelevated then elevated.
    [ValidateSet('unelevated', 'elevated')]
    [string[]]$Context = @('unelevated', 'elevated')
)

$ErrorActionPreference = 'Stop'
try {
    $runner = Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\Invoke-Test.ps1'
    $suite = Join-Path -Path $PSScriptRoot -ChildPath 'winget-paths.Tests.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $code = 0
    # Each context in a pwsh of its own, so the second starts with a fresh Pester
    foreach ($each in $Context) {
        $env:WINFILES_WINGET_PATHS_CONTEXT = $each
        & $pwsh -NoLogo -NoProfile -File $runner -Path $suite
        $code = $LASTEXITCODE
        if ($code) {
            break
        }
    }
    exit $code
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
