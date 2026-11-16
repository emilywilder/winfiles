#Requires -Version 7.4

<#
.SYNOPSIS
Applies one DSC configuration, keeping its results in ~/.local/state/winfiles/dsc, and exits with dsc's exit code.

.DESCRIPTION
Those results give each resource's duration. A package that fails to install is logged and doesn't change the exit
code, so run Test-Winfiles.ps1 afterwards. It says when it starts and how it ended, with the time it took and what
the resources left missing. A failure or something left missing is printed; every event, with the phase
("[system] ..."), goes to ~/.local/state/winfiles/run.log.

.EXAMPLE
./scripts/Set-Winfiles.ps1 dsc/emily@iris.home.dsc.yaml
#>
param([string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

# iris.system.dsc.yaml is "system", emily@iris.home.dsc.yaml "home" and features.dsc.yaml "features"
$phase = ((Split-Path $File -Leaf) -replace '\.dsc\.yaml$') -replace '^.*\.'

Write-WinfilesLog $phase "applying $File"
$timer = [Diagnostics.Stopwatch]::StartNew()
$json = Invoke-DscLogged set $File
$exitCode = $LASTEXITCODE
$took = Format-WinfilesDuration $timer.Elapsed

if ($exitCode) {
    $message = "dsc failed with exit code $exitCode after $took"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog $phase $message
} else {
    $resources = @()
    $notDone = @()
    try {
        $resources = @(Get-ResourceResult ($json | ConvertFrom-Json).results)
        $notDone = @($resources | Where-Object { Get-ResourceProblem $_ 'afterState' })
    } catch {}
    if ($notDone) {
        $message = "done in $took, $($resources.Count) resources, $($notDone.Count) not fully applied (just check lists them)"
        Write-Host $message -ForegroundColor Yellow
        Write-WinfilesLog $phase $message
        foreach ($resource in $notDone) {
            $message = "  $($resource.type) '$($resource.name)': $((Get-ResourceProblem $resource 'afterState') -join ', ')"
            Write-Host $message
            Write-WinfilesLog $phase $message
        }
    } else {
        Write-WinfilesLog $phase "done in $took, $($resources.Count) resources"
    }
}
exit $exitCode
