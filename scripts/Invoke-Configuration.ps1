#Requires -Version 7.4

<#
.SYNOPSIS
Applies or tests one entry document in batches, each run at the privilege its resources ask for.

.DESCRIPTION
ConvertTo-FlatConfiguration.ps1 -Batch splits the entry into batches of consecutive resources of one level
(metadata.winget.securityContext: elevated, or the user's), in an order that keeps every dependsOn. Each batch then runs
as its own dsc process in turn: an elevated one through Invoke-AsAdmin.ps1 and an unelevated one through
Invoke-AsUser.ps1, so a dependsOn can cross from one level to the other, which two entry documents can't do. Run it
from an elevated shell (`just install` does), where elevated batches run as they are and unelevated ones drop to
Medium integrity through gsudo, so the whole run asks for UAC once. From an unelevated shell it asks at each elevated
batch instead.
`set` applies each batch with Set-Winfiles.ps1, except one of the `restart` stage (metadata.winfiles.stage: restart),
which goes through Set-RestartStage.ps1, so what Windows needs a restart for is applied first and the run stops for
the restart before anything installs, with exit code 3010. The first batch that fails ends the run with its exit code.
`test` tests every batch with Test-Winfiles.ps1, even after one fails, and exits 1 if any did. Each batch reports its
own "N of M in desired state", under the name of the batch file.
The batches are kept in ~/.local/state/winfiles/flat, named <entry>.<n>-<level>.dsc.yaml. They are always flat, so there
is no -NoFlatten here.

.PARAMETER Operation
`set` to apply, `test` to report what isn't in its desired state.

.PARAMETER File
The entry document.

.EXAMPLE
./scripts/Invoke-Configuration.ps1 set dsc/emily@iris.dsc.yaml
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('set', 'test')][string]$Operation,
    [Parameter(Mandatory, Position = 1)][string]$File
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')

$phase = if ($Operation -eq 'set') { 'apply' } else { 'check' }
Write-WinfilesLog $phase "$Operation $File in batches"
try {
    $batches = @(& (Join-Path $PSScriptRoot 'ConvertTo-FlatConfiguration.ps1') $File -Batch)
} catch {
    $message = "${File}: couldn't make batches of it: $($_.Exception.Message -replace "^$([regex]::Escape($File)): ")"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog $phase $message
    exit 1
}
Write-WinfilesLog $phase "$($batches.Count) batches: $(($batches | ForEach-Object { "$($_.Level)$(if ($_.Stage) { "/$($_.Stage)" }) x$($_.Resources)" }) -join ', ')"

$failed = 0
$exitCode = 0
$number = 0
foreach ($batch in $batches) {
    $number++
    $as = if ($batch.Level -eq 'elevated') { 'Invoke-AsAdmin.ps1' } else { 'Invoke-AsUser.ps1' }
    $script = if ($Operation -eq 'test') { 'Test-Winfiles.ps1' } elseif ($batch.Stage -eq 'restart') { 'Set-RestartStage.ps1' } else { 'Set-Winfiles.ps1' }
    Write-WinfilesLog $phase "batch $number of $($batches.Count): $($batch.Level), $($batch.Resources) resources, $script"
    & (Join-Path $PSScriptRoot $as) pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot $script) $batch.Path -NoFlatten
    $code = $LASTEXITCODE
    if (-not $code) { continue }
    $failed++
    if ($Operation -eq 'set') {
        Write-WinfilesLog $phase "batch $number ($($batch.Path)) ended with exit code $code, so the run stops"
        exit $code
    }
    $exitCode = 1
}
if ($failed) {
    $message = "$failed of $($batches.Count) batches failed"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog $phase $message
}
exit $exitCode
