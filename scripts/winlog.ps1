# Shared by the scripts that report a run's progress, which dot-source it. Runs under Windows PowerShell 5.1 too.
# Write-WinfilesLog appends "<time> [phase] message" to ~/.local/state/winfiles/run.log, and prints nothing: a script
# that has something to tell the person at the console writes it with Write-Host itself, next to this call.
# The file is outside the repo like dsclog.ps1's results, so Copy-RepoToTestVm.ps1 doesn't replace it. It's the one
# record of a whole install across its restarts, read with `just test-vm-log`: a phase's events (bootstrap, features,
# wsl, system, home, check, install, resume) say what started and finished and how it ended. A failure to write the
# file never stops a run.


function Write-WinfilesLog {
    <#
    .SYNOPSIS
    Appends a timed "[phase] message" line to ~/.local/state/winfiles/run.log, and prints nothing.

    .EXAMPLE
    Write-WinfilesLog -Phase install -Message 'started for host iris'
    #>
    [CmdletBinding()]
    param(
        # The part of the run the line belongs to, such as install, apply or check.
        [Parameter(Position = 0)]
        [string]$Phase,

        # What happened.
        [Parameter(Position = 1)]
        [string]$Message
    )

    $line = "[$Phase] $Message"
    try {
        $folder = Join-Path -Path $env:USERPROFILE -ChildPath '.local\state\winfiles'
        [void](New-Item -ItemType Directory -Force -Path $folder -ErrorAction Stop)
        # One writer at a time is the normal case, and a lost line isn't worth stopping an install for
        $entry = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line
        Add-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'run.log') -Value $entry -ErrorAction Stop
    } catch {
        $failure = $_
        Write-Verbose -Message "run.log wasn't written: $($failure.Exception.Message)"
    }
}


function Format-WinfilesDuration {
    <#
    .SYNOPSIS
    Formats a duration for the run log: "3m12s", or "48s" under a minute.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The duration.
        [Parameter(Mandatory, Position = 0)]
        [timespan]$Duration
    )

    if ($Duration.TotalMinutes -ge 1) {
        '{0}m{1:D2}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    } else {
        '{0}s' -f [int][math]::Round($Duration.TotalSeconds)
    }
}
