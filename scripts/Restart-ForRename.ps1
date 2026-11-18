#Requires -Version 5.1

<#
.SYNOPSIS
    Restarts Windows when the computer's new name is waiting for a restart, and exits 3010.

.DESCRIPTION
    Winfiles/ComputerName counts a rename as done once Windows has the new name pending, since a restart is the
    only thing that makes it active, so the run's own checks pass before the name is live. `just system` runs this
    after dsc-set-system, so a clean install doesn't finish with the old name.
    The pending name is HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName and the active one is
    ...\ActiveComputerName; they differ (ignoring case) while a rename waits. Nothing else is looked at: another
    pending restart is wsl-install's to report.
    Restarts the way Install-Wsl.ps1 does: after 30 seconds for Ctrl+C, without -Force, and exits 3010 so
    `just install` stops before `home`; install.cmd continues after the restart. Where the restart fails, only
    warns, and still exits 3010. Exits 0 when no rename is waiting.
    Trade-off: this copies Install-Wsl.ps1's restart, to keep the full run working. Revisit when the restart
    helpers share one script (docs/restart-points.md, on feat/restart-points).

.EXAMPLE
    ./scripts/Restart-ForRename.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
$active = (Get-ItemProperty "$key\ActiveComputerName").ComputerName
$pending = (Get-ItemProperty "$key\ComputerName").ComputerName
if ($active -ieq $pending) {
    Write-WinfilesLog restart "the computer is named $active, no rename waiting"
    exit 0
}

Write-Warning "The computer will be named '$pending' after a restart; it's still '$active'. Restarting in 30 seconds, or press Ctrl+C to restart later. install.cmd then continues after you sign in and press Enter; after any other install command, run it again."
Write-WinfilesLog restart "install stopped: restarting Windows in 30 seconds for the rename from $active to $pending. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again"
Start-Sleep -Seconds 30
try {
    # No -Force: an app holding unsaved work can still stop the restart
    Restart-Computer
} catch {
    Write-Warning "Restarting failed ($_). Restart Windows."
}
exit 3010
