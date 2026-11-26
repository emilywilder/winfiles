#Requires -Version 7.4

<#
.SYNOPSIS
Applies or tests one entry document in batches, each run at the privilege its resources ask for.

.DESCRIPTION
ConvertTo-FlatConfiguration.ps1 -Batch splits the entry into batches of consecutive resources of one level
(metadata.winget.securityContext: elevated on a document or a resource, or the user's), in an order that keeps
every dependsOn. Each batch then runs as its own dsc process in turn: an elevated one through Invoke-AsAdmin.ps1
and an unelevated one through Invoke-AsUser.ps1, so a dependsOn can cross from one level to the other, which two
entry documents can't do. Run it from an elevated shell (`winfiles.ps1 switch` does), where elevated batches run
as they are and unelevated ones drop to Medium integrity through gsudo, so the whole run asks for UAC once. From an
unelevated shell it asks at each elevated batch instead.
Restarts are found when `set` runs, not written in any document. Each elevated batch is tested first
(Find-RestartResource.ps1), and a resource that reports it will need a restart (`_restartRequired`) is pulled
forward with what it depends on, as a batch of its own that runs first (ConvertTo-FlatConfiguration.ps1 -First).
That batch goes through Set-RestartStage.ps1, and if a restart is then pending the run stops with exit code 3010
before anything installs, saying how many batches and resources are left for after the restart. It restarts Windows
itself only for `switch --restart` (scripts/restart.ps1). If nothing reports one there is no such batch. After any
other elevated batch, a restart that became pending stops the run the same way, and so does a computer rename still
waiting at the end. The first batch that fails ends the run with its exit code. After the restart, the run is
started again, and what was done is found to be. `test` tests every batch with Test-Winfiles.ps1, even after one
fails, and exits 1 if anything isn't in its desired state or a batch failed. Each batch reports its own "N of M in
desired state", under the name of the batch file, and what differs, and the run ends with one total.
More than one entry document makes one aggregate (the order given: `winfiles.ps1 switch` gives the system document
and then the home one), flattened and batched together.
The batches are kept in ~/.local/state/winfiles/flat, named <entry>.<n>-<level>.dsc.yaml. Flattening happens here,
not in the scripts it runs: they refuse a document that still has Includes.

.EXAMPLE
./scripts/Invoke-Configuration.ps1 set dsc/vm-quick.system.dsc.yaml

Applies vm-quick's system configuration in batches.
#>
[CmdletBinding()]
param(
    # `set` to apply, `test` to report what isn't in its desired state.
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('set', 'test')]
    [string]$Operation,

    # The entry document, or several.
    [Parameter(Mandatory, Position = 1, ValueFromRemainingArguments)]
    [string[]]$File
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'restart.ps1')

    $phase = if ($Operation -eq 'set') { 'apply' } else { 'check' }
    Write-WinfilesLog -Phase $phase -Message "$Operation $($File -join ' and ') in batches"


    function Get-Batch {
        <#
        .SYNOPSIS
        Flattens the entries into batches, or stops the run, saying why, when that fails.
        #>
        [CmdletBinding()]
        [OutputType([array])]
        param(
            # What to pull forward into a first batch, as ConvertTo-FlatConfiguration.ps1's -First takes it.
            [string]$First
        )

        $arguments = @{ Batch = $true }
        if ($First) {
            $arguments.First = $First
        }
        try {
            $convert = Join-Path -Path $PSScriptRoot -ChildPath 'ConvertTo-FlatConfiguration.ps1'
            @(& $convert -File $File @arguments)
        } catch {
            $failure = $_
            $names = $File -join ' and '
            $reason = $failure.Exception.Message -replace "^$([regex]::Escape($names)): "
            $message = "${names}: couldn't make batches of it: $reason"
            Write-Host -Object $message -ForegroundColor Red
            Write-WinfilesLog -Phase $phase -Message $message
            exit 1
        }
    }


    function Invoke-AtLevel {
        <#
        .SYNOPSIS
        Runs one of the scripts on a batch, elevated or unelevated as the batch's level asks.
        #>
        [CmdletBinding()]
        param(
            # The batch's level.
            [Parameter(Mandatory, Position = 0)]
            [ValidateSet('elevated', 'user')]
            [string]$Level,

            # The script in scripts/ to run.
            [Parameter(Mandatory, Position = 1)]
            [string]$Script,

            # The batch's document.
            [Parameter(Mandatory, Position = 2)]
            [string]$Path,

            # More arguments for the script.
            [Parameter(Position = 3)]
            [AllowEmptyCollection()]
            [string[]]$More = @()
        )

        $as = if ($Level -eq 'elevated') { 'Invoke-AsAdmin.ps1' } else { 'Invoke-AsUser.ps1' }
        $More = @($More | Where-Object -FilterScript { $_ })
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $Script
        & (Join-Path -Path $PSScriptRoot -ChildPath $as) pwsh -NoLogo -NoProfile -File $scriptPath $Path @More
    }


    function Write-LeftForRestart {
        <#
        .SYNOPSIS
        Says what a run that stops for a restart leaves for its next run: the batches after the one it stopped at.
        #>
        [CmdletBinding()]
        param(
            # How many batches the run has been through, the one it stopped at included.
            [Parameter(Mandatory)]
            [int]$Through
        )

        $left = @($batches | Select-Object -Skip $Through)
        if ($left) {
            $sum = @{}
            foreach ($level in 'elevated', 'user') {
                $sum[$level] = [int](($left | Where-Object -Property Level -EQ -Value $level |
                            Measure-Object -Property Resources -Sum).Sum)
            }
            $message = ("Left for after the restart: $($left.Count) of $($batches.Count) batches, " +
                "$($sum.elevated + $sum.user) resources ($($sum.elevated) elevated, $($sum.user) unelevated).")
            Write-Host -Object $message
            Write-WinfilesLog -Phase $phase -Message $message
        }
    }


    # Each batch of a test adds its line (resources, then those not in desired state) here, for one total
    $totals = Join-Path -Path $HOME -ChildPath ".local\state\winfiles\totals-$([guid]::NewGuid()).txt"

    $batches = Get-Batch

    # What will need a restart, from testing the elevated batches, which then go first
    if ($Operation -eq 'set') {
        $found = foreach ($batch in $batches | Where-Object -Property Level -EQ -Value 'elevated') {
            $lines = @(Invoke-AtLevel -Level elevated -Script 'Find-RestartResource.ps1' -Path $batch.Path)
            $code = $LASTEXITCODE
            # What it says besides the resources it found (a failure, mostly) is for the person
            $lines |
                Where-Object -FilterScript { "$_" -notmatch '^winfiles-restart: ' } |
                ForEach-Object -Process { Write-Host -Object $_ }
            if ($code) {
                Write-WinfilesLog -Phase $phase -Message ("looking for what needs a restart in $($batch.Path) " +
                    "failed with exit code $code, so the run stops")
                exit $code
            }
            $lines | ForEach-Object -Process {
                if ("$_" -match '^winfiles-restart: (.+)$') {
                    $Matches[1]
                }
            }
        }
        $found = @($found | Select-Object -Unique)
        if ($found) {
            Write-WinfilesLog -Phase $phase -Message "restart needed by: $($found -join ', ')"
            $batches = Get-Batch -First ($found -join ';')
        }
    }
    $summary = $batches | ForEach-Object -Process {
        "$($_.Level)$(if ($_.Stage) { "/$($_.Stage)" }) x$($_.Resources)"
    }
    Write-WinfilesLog -Phase $phase -Message "$($batches.Count) batches: $($summary -join ', ')"

    $pendingAtStart = Test-BlockingRestartPending
    $failed = 0
    $exitCode = 0
    $number = 0
    foreach ($batch in $batches) {
        $number++
        $script = if ($Operation -eq 'test') {
            'Test-Winfiles.ps1'
        } elseif ($batch.Stage -eq 'restart') {
            'Set-RestartStage.ps1'
        } else {
            'Set-Winfiles.ps1'
        }
        Write-WinfilesLog -Phase $phase -Message ("batch $number of $($batches.Count): $($batch.Level), " +
            "$($batch.Resources) resources, $script")
        $more = if ($Operation -eq 'test') { '-TotalsFile', $totals } else { @() }
        Invoke-AtLevel -Level $batch.Level -Script $script -Path $batch.Path -More $more
        $code = $LASTEXITCODE
        if (-not $code) {
            # The restart batch does this itself. After others, a restart that became pending stops the run the
            # same way
            $restartNow = ($Operation -eq 'set' -and $batch.Level -eq 'elevated' -and
                $batch.Stage -ne 'restart' -and -not $pendingAtStart -and (Test-BlockingRestartPending))
            if ($restartNow) {
                Write-LeftForRestart -Through $number
                Restart-Windows -Phase $phase -Done "Batch $number of $($batches.Count) is applied. "
            }
            continue
        }
        $failed++
        if ($Operation -eq 'set') {
            # 3010 is a stop for a restart, not a failure (194 is its low byte, which mise exec leaves of it)
            $restart = $code -in 3010, 194
            $why = if ($restart) {
                "stopped for a restart (exit code $code)"
            } else {
                "ended with exit code $code"
            }
            Write-WinfilesLog -Phase $phase -Message "batch $number ($($batch.Path)) $why, so the run stops"
            if ($restart) {
                Write-LeftForRestart -Through $number
            }
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
        if ($wrong) {
            $exitCode = 1
        }
        if ($wrong -or $failed) {
            $message = "failed: $wrong of $total resources are not in desired state, or dsc failed"
            Write-Host -Object $message -ForegroundColor Red
        } else {
            $message = "passed: all $total resources are in desired state"
            Write-Host -Object $message -ForegroundColor White
        }
        Write-WinfilesLog -Phase $phase -Message $message
    }
    # The rename on its own, when nothing before it needed a restart: the install shouldn't finish under the old
    # name
    $elevated = $batches | Where-Object -Property Level -EQ -Value 'elevated'
    if ($Operation -eq 'set' -and -not $exitCode -and $elevated -and (Test-ComputerRenamePending)) {
        Restart-Windows -Phase $phase -Done 'The configuration is applied, but the computer is not named yet. '
    }
    exit $exitCode
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
