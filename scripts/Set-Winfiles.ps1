#Requires -Version 7.4
<#
.SYNOPSIS
Applies one DSC configuration, keeping its results in ~/.local/state/winfiles/dsc, and exits with dsc's exit code.

.DESCRIPTION
Those results give each resource's duration. A package that fails to install is logged and doesn't change the exit
code, so run Test-Winfiles.ps1 afterwards.

.EXAMPLE
./scripts/Set-Winfiles.ps1 dsc/emily@iris.home.dsc.yaml
#>
param([string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')

Invoke-DscLogged set $File | Out-Null
exit $LASTEXITCODE
