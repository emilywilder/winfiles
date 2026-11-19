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
Both documents are tested and applied as flat copies (ConvertTo-FlatConfiguration.ps1), as Set-Winfiles.ps1 does.

.PARAMETER HostName
The host whose system configuration to apply.

.PARAMETER NoFlatten
Give dsc the documents themselves, Includes and all, rather than their flat copies.

.EXAMPLE
gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Set-System.ps1 iris
#>
param([Parameter(Mandatory)][string]$HostName, [switch]$NoFlatten)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')

$restartDocument = "dsc/$HostName.restart.dsc.yaml"
$systemDocument = "dsc/$HostName.system.dsc.yaml"

function Stop-IfFailed([int]$ExitCode) {
    if ($ExitCode) { exit $ExitCode }
}

# What Windows needs a restart for goes first, and a restart that leaves pending stops the run here (Set-RestartStage.ps1)
& (Join-Path $PSScriptRoot 'Set-RestartStage.ps1') $restartDocument -NoFlatten:$NoFlatten
Stop-IfFailed $LASTEXITCODE

& (Join-Path $PSScriptRoot 'Set-Winfiles.ps1') $systemDocument -NoFlatten:$NoFlatten
Stop-IfFailed $LASTEXITCODE

# The rename on its own: the features and WSL were already there, so nothing before the system document restarted
if (Test-ComputerRenamePending) {
    Restart-Windows system 'The system configuration is applied, but the computer is not named yet. '
}
exit 0