#Requires -Version 7.4

<#
.SYNOPSIS
Applies or tests one entry document in batches, each run at the privilege its resources ask for.

.DESCRIPTION
ConvertTo-FlatConfiguration.ps1 -Batch splits the entry into batches of consecutive resources of one level
(metadata.winget.securityContext: elevated on a document or a resource, or the user's), in an order that keeps every
dependsOn. Each batch then runs as its own dsc process in turn: an elevated one through Invoke-AsAdmin.ps1 and an
unelevated one through Invoke-AsUser.ps1, so a dependsOn can cross from one level to the other, which two entry
documents can't do. Run it from an elevated shell (`just install` does), where elevated batches run as they are and
unelevated ones drop to Medium integrity through gsudo, so the whole run asks for UAC once. From an unelevated shell it
asks at each elevated batch instead.
Restarts are found when `set` runs, not written in any document. Each elevated batch is tested first
(Find-RestartResources.ps1), and a resource that reports it will need a restart (`_restartRequired`) is pulled forward
with what it depends on, as a batch of its own that runs first (ConvertTo-FlatConfiguration.ps1 -First). That batch
goes through Set-RestartStage.ps1, which restarts Windows if one is then pending, and the run stops with exit code 3010
before anything installs. If nothing reports one there is no such batch. After any other elevated batch, a restart that
became pending stops the run the same way, and so does a computer rename still waiting at the end. The first batch that
fails ends the run with its exit code. After the restart, the run is started again, and what was done is found to be.
`test` tests every batch with Test-Winfiles.ps1, even after one fails, and exits 1 if anything isn't in its desired
state or a batch failed. Each batch reports its own "N of M in desired state", under the name of the batch file, and
what differs, and the run ends with one total.
More than one entry document makes one aggregate (the order given: `just install` gives the system document and then
the home one), flattened and batched together.
The batches are kept in ~/.local/state/winfiles/flat, named <entry>.<n>-<level>.dsc.yaml. Flattening happens here, not in
the scripts it runs: they refuse a document that still has Includes.

.PARAMETER Operation
`set` to apply, `test` to report what isn't in its desired state.

.PARAMETER File
The entry document, or several.

.EXAMPLE
./scripts/Invoke-Configuration.ps1 set dsc/vm-quick.system.dsc.yaml
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('set', 'test')][string]$Operation,
    [Parameter(Mandatory, Position = 1, ValueFromRemainingArguments)][string[]]$File
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')

$phase = if ($Operation -eq 'set') { 'apply' } else { 'check' }
Write-WinfilesLog $phase "$Operation $($File -join ' and ') in batches"

function Get-Batch([string]$First) {
    $arguments = @{ Batch = $true }
    if ($First) { $arguments.First = $First }
    try {
        @(& (Join-Path $PSScriptRoot 'ConvertTo-FlatConfiguration.ps1') $File @arguments)
    } catch {
        $names = $File -join ' and '
        $message = "${names}: couldn't make batches of it: $($_.Exception.Message -replace "^$([regex]::Escape($names)): ")"
        Write-Host $message -ForegroundColor Red
        Write-WinfilesLog $phase $message
        exit 1
    }
}

function Invoke-AtLevel([string]$Level, [string]$Script, [string]$Path, [string[]]$More = @()) {
    $as = if ($Level -eq 'elevated') { 'Invoke-AsAdmin.ps1' } else { 'Invoke-AsUser.ps1' }
    $More = @($More | Where-Object { $_ })
    & (Join-Path $PSScriptRoot $as) pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot $Script) $Path @More
}

# Each batch of a test adds its line (resources, then those not in desired state) here, for one total
$totals = Join-Path $HOME ".local\state\winfiles\totals-$([guid]::NewGuid()).txt"

$batches = Get-Batch

# What will need a restart, from testing the elevated batches, which then go first
if ($Operation -eq 'set') {
    $found = foreach ($batch in $batches | Where-Object Level -eq 'elevated') {
        $lines = @(Invoke-AtLevel elevated 'Find-RestartResources.ps1' $batch.Path)
        $code = $LASTEXITCODE
        # What it says besides the resources it found (a failure, mostly) is for the person
        $lines | Where-Object { "$_" -notmatch '^winfiles-restart: ' } | ForEach-Object { Write-Host $_ }
        if ($code) {
            Write-WinfilesLog $phase "looking for what needs a restart in $($batch.Path) failed with exit code $code, so the run stops"
            exit $code
        }
        $lines | ForEach-Object { if ("$_" -match '^winfiles-restart: (.+)$') { $Matches[1] } }
    }
    $found = @($found | Select-Object -Unique)
    if ($found) {
        Write-WinfilesLog $phase "restart needed by: $($found -join ', ')"
        $batches = Get-Batch ($found -join ';')
    }
}
Write-WinfilesLog $phase "$($batches.Count) batches: $(($batches | ForEach-Object { "$($_.Level)$(if ($_.Stage) { "/$($_.Stage)" }) x$($_.Resources)" }) -join ', ')"

$pendingAtStart = Test-BlockingRestartPending
$failed = 0
$exitCode = 0
$number = 0
foreach ($batch in $batches) {
    $number++
    $script = if ($Operation -eq 'test') { 'Test-Winfiles.ps1' } elseif ($batch.Stage -eq 'restart') { 'Set-RestartStage.ps1' } else { 'Set-Winfiles.ps1' }
    Write-WinfilesLog $phase "batch $number of $($batches.Count): $($batch.Level), $($batch.Resources) resources, $script"
    Invoke-AtLevel $batch.Level $script $batch.Path $(if ($Operation -eq 'test') { '-TotalsFile', $totals } else { @() })
    $code = $LASTEXITCODE
    if (-not $code) {
        # The restart batch does this itself. After others, a restart that became pending stops the run the same way
        if ($Operation -eq 'set' -and $batch.Level -eq 'elevated' -and $batch.Stage -ne 'restart' -and -not $pendingAtStart -and (Test-BlockingRestartPending)) {
            Restart-Windows $phase "Batch $number of $($batches.Count) is applied. "
        }
        continue
    }
    $failed++
    if ($Operation -eq 'set') {
        # 3010 is a stop for a restart, not a failure (194 is its low byte, which mise exec leaves of it)
        $why = if ($code -in 3010, 194) { "stopped for a restart (exit code $code)" } else { "ended with exit code $code" }
        Write-WinfilesLog $phase "batch $number ($($batch.Path)) $why, so the run stops"
        exit $code
    }
    $exitCode = 1
}
if ($Operation -eq 'test') {
    $total = 0
    $wrong = 0
    if (Test-Path -LiteralPath $totals) {
        foreach ($line in Get-Content -LiteralPath $totals) {
            $count, $bad = $line -split ' '
            $total += [int]$count
            $wrong += [int]$bad
        }
        Remove-Item -LiteralPath $totals
    }
    if ($wrong) { $exitCode = 1 }
    $message = if ($wrong -or $failed) { "failed: $wrong of $total resources are not in desired state, or dsc failed" } else { "passed: all $total resources are in desired state" }
    Write-Host $message -ForegroundColor $(if ($wrong -or $failed) { 'Red' } else { 'White' })
    Write-WinfilesLog $phase $message
}
# The rename on its own, when nothing before it needed a restart: the install shouldn't finish under the old name
if ($Operation -eq 'set' -and -not $exitCode -and ($batches | Where-Object Level -eq 'elevated') -and (Test-ComputerRenamePending)) {
    Restart-Windows $phase 'The configuration is applied, but the computer is not named yet. '
}
exit $exitCode
