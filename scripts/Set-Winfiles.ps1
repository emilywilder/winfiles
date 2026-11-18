#Requires -Version 7.4

<#
.SYNOPSIS
Applies one DSC configuration, keeping its results in ~/.local/state/winfiles/dsc, and exits with dsc's exit code.

.DESCRIPTION
It applies a flat copy of the document, from ConvertTo-FlatConfiguration.ps1, with each Include replaced by the
resources of the document it includes, kept in ~/.local/state/winfiles/flat under the same name. So one dsc process
runs everything, and its progress bar names each resource rather than each Include. Test-Winfiles.ps1 still tests
the document itself, Includes and all.
Those results give each resource's duration. A winget package that fails to install stops the configuration, and
dsc exits non-zero; a Scoop app that fails is logged and left missing without changing the exit code, so run
Test-Winfiles.ps1 afterwards. It says when it starts and how it ended, with the time it took and what
the resources left missing. A failure or something left missing is printed; every event, with the phase
("[system] ..."), goes to ~/.local/state/winfiles/run.log.

.EXAMPLE
./scripts/Set-Winfiles.ps1 dsc/emily@iris.home.dsc.yaml
#>
param([string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

# iris.system.dsc.yaml is "system", emily@iris.home.dsc.yaml "home" and iris.restart.dsc.yaml "restart"
$phase = ((Split-Path $File -Leaf) -replace '\.dsc\.yaml$') -replace '^.*\.'

Write-WinfilesLog $phase "applying $File"
$timer = [Diagnostics.Stopwatch]::StartNew()
# Same file name, so the kept result is named after the document as before. USERPROFILE rather than $HOME, as in
# winlog.ps1: Set-System.ps1's tests run this in their own process, where $HOME can't be pointed elsewhere
$flat = Join-Path $env:USERPROFILE ".local\state\winfiles\flat\$(Split-Path $File -Leaf)"
try {
    & (Join-Path $PSScriptRoot 'ConvertTo-FlatConfiguration.ps1') $File $flat
} catch {
    # Its messages start with the document already
    $message = "${File}: couldn't flatten it: $($_.Exception.Message -replace "^$([regex]::Escape($File)): ")"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog $phase $message
    exit 1
}
Write-WinfilesLog $phase "flattened to $flat"
$json = Invoke-DscLogged set $flat
$exitCode = $LASTEXITCODE
$took = Format-WinfilesDuration $timer.Elapsed

if ($exitCode) {
    # Named, because features and system fail through the same script in one gsudo call, and their recipes have no exit message
    $message = "${File}: dsc failed with exit code $exitCode after $took"
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
