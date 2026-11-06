#Requires -Version 7.4
<#
.SYNOPSIS
Runs the Pester tests in tests/, with the Pester version pinned here.

.DESCRIPTION
Pester is a PowerShell module, which mise can't install, so the pinned version is saved to
~/.cache/winfiles/modules on first use and imported from there, whatever else is on PSModulePath. Arguments are
paths to test, defaulting to tests/resources. Exits 1 if any test failed.

.EXAMPLE
./scripts/Invoke-Tests.ps1 tests/resources/wingetpackagelist.Tests.ps1
#>
$ErrorActionPreference = 'Stop'

# Bump by hand, after reading Pester's release notes
$pesterVersion = '6.2.0'

$modules = Join-Path $HOME '.cache/winfiles/modules'
$manifest = Join-Path $modules "Pester/$pesterVersion/Pester.psd1"
if (-not (Test-Path $manifest)) {
    New-Item -ItemType Directory -Force $modules | Out-Null
    Save-PSResource -Name Pester -Version $pesterVersion -Repository PSGallery -TrustRepository -Path $modules
}
Import-Module $manifest

$paths = if ($args) { $args } else { Join-Path $PSScriptRoot '../tests/resources' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = $paths
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $configuration
