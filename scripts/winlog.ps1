# Shared by the scripts that report a run's progress, which dot-source it. Runs under Windows PowerShell 5.1 too.
# Write-WinfilesLog prints "[phase] message" and appends "<time> [phase] message" to ~/.local/state/winfiles/run.log,
# outside the repo like dsclog.ps1's results, so Copy-RepoToTestVm.ps1 doesn't replace it. It's the one record of a
# whole install across its restarts: a phase's events (bootstrap, features, wsl, system, home, check, install) say
# what started and finished and how it ended. A failure to write the file never stops a run.
# -Continuation is for a detail under the line before it: the console shows the message as it is, the file keeps
# its phase. -Warning prints in yellow and -Failure in red.
function Write-WinfilesLog {
    param(
        [string]$Phase,
        [string]$Message,
        [switch]$Continuation,
        [switch]$Warning,
        [switch]$Failure
    )
    $line = "[$Phase] $Message"
    $colors = @{}
    if ($Warning) { $colors = @{ ForegroundColor = 'Yellow' } }
    if ($Failure) { $colors = @{ ForegroundColor = 'Red' } }
    Write-Host $(if ($Continuation) { $Message } else { $line }) @colors
    try {
        $folder = Join-Path $env:USERPROFILE '.local\state\winfiles'
        [void](New-Item -ItemType Directory -Force $folder)
        # One writer at a time is the normal case, and a lost line isn't worth stopping an install for
        Add-Content -LiteralPath (Join-Path $folder 'run.log') -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line)
    } catch {}
}

# "3m12s" or "48s"
function Format-WinfilesDuration([timespan]$Duration) {
    if ($Duration.TotalMinutes -ge 1) { '{0}m{1:D2}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds }
    else { '{0}s' -f [int][math]::Round($Duration.TotalSeconds) }
}
