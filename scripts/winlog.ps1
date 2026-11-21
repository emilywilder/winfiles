# Shared by the scripts that report a run's progress, which dot-source it. Runs under Windows PowerShell 5.1 too.
# Write-WinfilesLog appends "<time> [phase] message" to ~/.local/state/winfiles/run.log, and prints nothing: a script
# that has something to tell the person at the console writes it with Write-Host itself, next to this call.
# The file is outside the repo like dsclog.ps1's results, so Copy-RepoToTestVm.ps1 doesn't replace it. It's the one
# record of a whole install across its restarts, read with `just test-vm-log`: a phase's events (bootstrap, features,
# wsl, system, home, check, install, resume) say what started and finished and how it ended. A failure to write the file
# never stops a run.
function Write-WinfilesLog {
    param(
        [string]$Phase,
        [string]$Message
    )
    $line = "[$Phase] $Message"
    try {
        $folder = Join-Path $env:USERPROFILE '.local\state\winfiles'
        [void](New-Item -ItemType Directory -Force $folder)
        # One writer at a time is the normal case, and a lost line isn't worth stopping an install for
        Add-Content -LiteralPath (Join-Path $folder 'run.log') `
            -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line)
    } catch {}
}

# "3m12s" or "48s"
function Format-WinfilesDuration([timespan]$Duration) {
    if ($Duration.TotalMinutes -ge 1) { '{0}m{1:D2}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds }
    else { '{0}s' -f [int][math]::Round($Duration.TotalSeconds) }
}
