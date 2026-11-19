#Requires -Version 7.4

<#
.SYNOPSIS
Applies the configuration of what Windows needs a restart for, and stops for the restart if one is then pending.

.DESCRIPTION
Meant for an elevated shell, before anything installs: Invoke-Configuration.ps1 runs it on the first batch, which holds
what reported it will need a restart (`_restartRequired`) and what that depends on, such as WSL with the optional
features. The document is tested first, and each resource reports a restart it will need as `_restartRequired`,
so what's about to need one is known before anything is applied. What differs is applied next. If Windows then has a
restart pending (restart.ps1 reads it from the machine, not from what DSC reported), it restarts by itself, after 30
seconds for Ctrl+C, when this run made the restart pending, and otherwise only asks, since it may be Windows Update's.
Either way it exits with 3010, and install.cmd continues after the restart. Otherwise it exits 0, or with dsc's exit
code when the test or the apply fails (Set-Winfiles.ps1 prints that).

.PARAMETER File
The document to test and apply, which has to be flat (a batch of Invoke-Configuration.ps1).

.EXAMPLE
gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Set-RestartStage.ps1 <batch document>
#>
param([Parameter(Mandatory)][string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')

# Tested before anything is applied, so a run knows what will need a restart (the resources say so from `test`)
Write-WinfilesLog apply "testing $File for what needs a restart"
$document = Get-RunDocument $File apply
if (-not $document) { exit 1 }
$json = Invoke-DscLogged test $document
if ($LASTEXITCODE) {
    $message = "${File}: dsc failed with exit code $LASTEXITCODE"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog apply $message
    exit $LASTEXITCODE
}
$results = ($json | ConvertFrom-Json).results
$differing = @(Get-ResourceResult $results | Where-Object { -not $_.result.inDesiredState })
$expected = @(Get-RestartReport $results)
if ($expected) {
    $message = "a restart will be needed by: $(($expected | ForEach-Object { "$($_.Type) '$($_.Name)'" }) -join ', ')"
    Write-Host $message
    Write-WinfilesLog apply $message
}

# A restart already pending before anything is applied isn't this run's, whatever it is (Windows Update's, say)
$pendingBefore = Test-BlockingRestartPending
if ($differing) {
    & (Join-Path $PSScriptRoot 'Set-Winfiles.ps1') $File
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

# The gate. What the machine says decides, since a restart can be pending without DSC having reported it
if (Test-BlockingRestartPending) {
    $done = if ($differing) { 'Applied ' + (($differing | ForEach-Object { "$($_.Type) '$($_.Name)'" }) -join ', ') + '. ' } else { '' }
    # Only a restart this run caused is started for the person: otherwise it may be Windows Update's, and open work
    if ($differing -and -not $pendingBefore) { Restart-Windows apply $done }
    Exit-RestartPending apply $done
}
exit 0
