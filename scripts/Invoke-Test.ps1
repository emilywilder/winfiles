#Requires -Version 7.4

<#
.SYNOPSIS
Runs the Pester tests in tests/, with the Pester version pinned here.

.DESCRIPTION
Pester is a PowerShell module, which mise can't install, so the pinned version is saved to
~/.cache/winfiles/modules on first use and imported from there, whatever else is on PSModulePath. The surveys'
commands run their Pester files through it too. Exits 1 if any test failed.

.EXAMPLE
./scripts/Invoke-Test.ps1 tests/resources/wingetpackage.Tests.ps1

Runs the tests of Winfiles.WinGet/Package.
#>
[CmdletBinding()]
param(
    # The test files or folders to run, defaulting to tests.
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Path = @()
)

$ErrorActionPreference = 'Stop'
try {
    # Bump by hand, after reading Pester's release notes
    $pesterVersion = '6.2.0'

    $modules = Join-Path -Path $HOME -ChildPath '.cache/winfiles/modules'
    $manifest = Join-Path -Path $modules -ChildPath "Pester/$pesterVersion/Pester.psd1"
    if (-not (Test-Path -Path $manifest)) {
        New-Item -ItemType Directory -Force -Path $modules | Out-Null
        Save-PSResource -Name Pester -Version $pesterVersion -Repository PSGallery -TrustRepository -Path $modules
    }
    Import-Module -Name $manifest

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = if ($Path) { $Path } else { Join-Path -Path $PSScriptRoot -ChildPath '../tests' }
    $configuration.Run.Exit = $true
    $configuration.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $configuration
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
