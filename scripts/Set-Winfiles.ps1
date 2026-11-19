#Requires -Version 7.4

<#
.SYNOPSIS
Applies one DSC configuration, keeping its results in ~/.local/state/winfiles/dsc, and exits with dsc's exit code.

.DESCRIPTION
It applies the document it is given, which has to be flat: Invoke-Configuration.ps1 flattens an entry into batches
(ConvertTo-FlatConfiguration.ps1) and runs this on each, so one dsc process runs every resource of a batch and its
progress bar names each resource rather than each Include. A document with an Include is refused, naming what to run.
Those results give each resource's duration. A winget package that fails to install stops the configuration, and
dsc exits non-zero; a Scoop app that fails is logged and left missing without changing the exit code, so run
Test-Winfiles.ps1 afterwards. It says when it starts and how it ended, with the time it took and what
the resources left missing. A failure or something left missing is printed; every event, with the phase
("[system] ..."), goes to ~/.local/state/winfiles/run.log.

.EXAMPLE
./scripts/Set-Winfiles.ps1 ~/.local/state/winfiles/flat/emily@iris.home.dsc.yaml
#>
param([string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

# iris.system.dsc.yaml is "system" and emily@iris.home.dsc.yaml "home"; a batch of Invoke-Configuration.ps1
# (iris.system.2-user.dsc.yaml) is "apply", the phase that script logs under
$phase = ((Split-Path $File -Leaf) -replace '\.dsc\.yaml$') -replace '^.*\.'
if ($phase -match '^\d+-(elevated|user)$') { $phase = 'apply' }

Write-WinfilesLog $phase "applying $File"
$timer = [Diagnostics.Stopwatch]::StartNew()
$document = Get-RunDocument $File $phase
if (-not $document) { exit 1 }
$json = Invoke-DscLogged set $document
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
