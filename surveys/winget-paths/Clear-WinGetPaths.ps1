#Requires -Version 7.4

<#
.SYNOPSIS
Uninstalls every package the winget-paths survey installs, in a test VM, so its next run starts clean.

.DESCRIPTION
The survey runs it unelevated before each path and at the end; run it by hand from the VM's desktop, unelevated, after
an interrupted run. It uninstalls the per-user packages itself, since
winget refuses to uninstall a per-user package from an elevated process (0x8A15007D, 2026-11-17), then starts itself
elevated through a UAC prompt for what's left: machine-wide packages, and Microsoft.UI.Xaml.2.6, which winget reports
uninstalled but keeps listing when unelevated (2026-11-17). Exits 1, naming them, if any package is still installed.
Refuses to run elevated, and on anything but a Hyper-V guest.

.EXAMPLE
mise exec -- pwsh -NoProfile -File ./surveys/winget-paths/Clear-WinGetPaths.ps1
#>
param(
    # Set when it starts itself elevated for the second pass
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinGetPaths.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\winlog.ps1')

Assert-TestVm
$isElevated = Test-Elevated
if ($isElevated -and -not $Elevated) {
    Write-Host 'Run this unelevated: winget won''t uninstall per-user packages elevated. It asks for UAC itself.'
    exit 1
}
$context = if ($isElevated) { 'elevated' } else { 'unelevated' }

# Uninstalls each id winget lists in one of -Scopes, and waits up to 30s for it to go: some uninstallers return first
function Remove-Listed([string[]]$Scopes) {
    foreach ($id in Get-WinGetPathId) {
        $scope = Get-InstalledScope $id
        if ($scope -notin $Scopes) { continue }
        $output = winget uninstall --id $id --exact --source winget --scope $scope --silent --accept-source-agreements --disable-interactivity 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-InstalledScope $id) -eq $scope -and $clock.Elapsed.TotalSeconds -lt 30) { Start-Sleep 3 }
        }
        $last = ($output | Where-Object { "$_".Trim() } | Select-Object -Last 1)
        Write-WinfilesLog winget-paths "clear $context ${id} ($scope): exit $exitCode, $last"
    }
}

if ($Elevated) {
    # Everything still listed: machine-wide packages, and MSIX ones such as UI.Xaml, which elevated winget does remove
    Remove-Listed user, machine
    exit 0
}

Remove-Listed user
$left = @(Get-WinGetPathId | Where-Object { Get-InstalledScope $_ })
if ($left) {
    Write-Host "Asking for elevation to uninstall $($left -join ', ')"
    $pwsh = (Get-Process -Id $PID).Path
    try {
        Start-Process $pwsh -Verb RunAs -Wait -ArgumentList '-NoLogo', '-NoProfile', '-File', "`"$PSCommandPath`"", '-Elevated'
    } catch {
        Write-Host "The elevated pass didn't run: $($_.Exception.Message)"
    }
}

$left = @(Get-WinGetPathId | ForEach-Object { $scope = Get-InstalledScope $_; if ($scope) { "$_ ($scope)" } })
if ($left) {
    Write-WinfilesLog winget-paths "clear left installed: $($left -join ', ')"
    Write-Host "Still installed: $($left -join ', '). See the clear lines in run.log (just test-vm-log)."
    exit 1
}
Write-WinfilesLog winget-paths 'clear: none of the suite''s packages are installed'
Write-Host 'None of the suite''s packages are installed.'
