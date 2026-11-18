#Requires -Version 7.4

<#
.SYNOPSIS
Applies a host's system configuration from an elevated shell, restarting Windows at most once, before anything installs.

.DESCRIPTION
`just system` runs this in its one gsudo call. dsc/<host>.restart.dsc.yaml holds what Windows needs a restart for:
the host's optional features, WSL and the computer's name. It's tested first, and each resource reports a restart it
will need as `_restartRequired`, so what's about to need one is known before anything is applied. What differs is
applied next. If Windows then has a restart pending (restart.ps1 reads it from the machine, not from what DSC
reported), the run stops here and restarts: installers refuse to run while one is pending, and this one restart
covers the features, WSL and the rename together. It restarts by itself, after 30 seconds for Ctrl+C, when this run
made the restart pending, and otherwise only asks, since it may be Windows Update's. Either way it exits with 3010,
and install.cmd continues after the restart. Only then does it apply dsc/<host>.system.dsc.yaml, which includes
WSL and the name again as no-ops, so `just check` tests them. If only a computer rename is still waiting after that
(the features and WSL were already done), it restarts then, the same way, rather than let the install finish under the
old name.
A failure of either document is printed by Set-Winfiles.ps1, and ends the run with its exit code.

.PARAMETER HostName
The host whose system configuration to apply.

.EXAMPLE
gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Set-System.ps1 iris
#>
param([Parameter(Mandatory)][string]$HostName)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')

$restartDocument = "dsc/$HostName.restart.dsc.yaml"
$systemDocument = "dsc/$HostName.system.dsc.yaml"

function Stop-IfFailed([int]$ExitCode) {
    if ($ExitCode) { exit $ExitCode }
}

# Tested before anything is applied, so a run knows what will need a restart (the resources say so from `test`)
Write-WinfilesLog system "testing $restartDocument for what needs a restart"
$json = Invoke-DscLogged test $restartDocument
if ($LASTEXITCODE) {
    $message = "${restartDocument}: dsc failed with exit code $LASTEXITCODE"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog system $message
    exit $LASTEXITCODE
}
$results = ($json | ConvertFrom-Json).results
$differing = @(Get-ResourceResult $results | Where-Object { -not $_.result.inDesiredState })
$expected = @(Get-RestartReport $results)
if ($expected) {
    $message = "a restart will be needed by: $(($expected | ForEach-Object { "$($_.Type) '$($_.Name)'" }) -join ', ')"
    Write-Host $message
    Write-WinfilesLog system $message
}

# A restart already pending before anything is applied isn't this run's, whatever it is (Windows Update's, say)
$pendingBefore = Test-BlockingRestartPending
if ($differing) {
    & (Join-Path $PSScriptRoot 'Set-Winfiles.ps1') $restartDocument
    Stop-IfFailed $LASTEXITCODE
}

# The gate. What the machine says decides, since a restart can be pending without DSC having reported it
if (Test-BlockingRestartPending) {
    $done = if ($differing) { 'Applied ' + (($differing | ForEach-Object { "$($_.Type) '$($_.Name)'" }) -join ', ') + '. ' } else { '' }
    # Only a restart this run caused is started for the person: otherwise it may be Windows Update's, and open work
    if ($differing -and -not $pendingBefore) { Restart-Windows system $done }
    Exit-RestartPending system $done
}

& (Join-Path $PSScriptRoot 'Set-Winfiles.ps1') $systemDocument
Stop-IfFailed $LASTEXITCODE

# The rename on its own: the features and WSL were already there, so nothing before the system document restarted
if (Test-ComputerRenamePending) {
    Restart-Windows system 'The system configuration is applied, but the computer is not named yet. '
}
exit 0