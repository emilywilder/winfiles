#Requires -Version 5.1

<#
.SYNOPSIS
Runs `just install` through Start-Clean.ps1, with a RunOnce entry waiting to continue it at the next sign-in if it
stops for a restart.

.DESCRIPTION
install.cmd runs this under Windows PowerShell 5.1, so it keeps to 5.1's syntax. The install itself goes through
Start-Clean.ps1, which finds mise from the registry's PATH and starts Invoke-Clean.ps1 under mise's pwsh, since
Invoke-Clean.ps1 needs pwsh 7.3 or later.
Before the run it writes a per-user RunOnce value, `winfiles`, that starts scripts/Resume-Winfiles.ps1 with the same
arguments at the next sign-in. It's written first because writing it afterwards would race the shutdown that
Invoke-Configuration.ps1 starts. After the run it's removed unless the run stopped for a restart: 3010, or 194 through
`mise exec`, which cuts an exit code to its low byte. Windows deletes a RunOnce value before running it, and the
resumed run writes it again if it stops for another restart, so declining UAC or any failure ends the chain.
Exits with the install's exit code.

.PARAMETER Arguments
What `just install` takes: the host, then the user.

.PARAMETER RunOnceKey
The registry key that holds the entry. For the tests.

.EXAMPLE
./scripts/Invoke-Install.ps1 iris
#>
# No positional binding, or the first argument would go to $RunOnceKey
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments,
    [string]$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')

$resume = 'cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit ' +
    "-File `"$PSScriptRoot\Resume-Winfiles.ps1`""
foreach ($argument in $Arguments) { $resume += " `"$argument`"" }

# RunOnce's documented limit. Only the resume depends on it, so the install still goes ahead
$registered = $resume.Length -le 260
if (-not $registered) {
    Write-Warning "The repo's path is too long for a RunOnce entry, so run install.cmd again after any restart."
    Write-WinfilesLog resume ("not registered: the RunOnce entry would be $($resume.Length) characters, over 260, " +
        'so run install.cmd again after any restart')
} else {
    # Not New-Item -Force, which would empty a key that exists
    if (-not (Test-Path $RunOnceKey)) { New-Item $RunOnceKey | Out-Null }
    # No `!` on the name: Windows deletes the value before running it, so a resume that fails isn't retried at every
    # sign-in
    New-ItemProperty $RunOnceKey -Name winfiles -Value $resume -Force | Out-Null
    Write-WinfilesLog resume ('registered the RunOnce entry, which continues the install at the next sign-in ' +
        'if it stops for a restart')
}

# A child process, because Start-Clean.ps1 ends with `exit` and changes its own PATH
$shell = (Get-Process -Id $PID).Path
& $shell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Start-Clean.ps1" just install @Arguments
$exitCode = $LASTEXITCODE

if ($exitCode -notin 194, 3010) {
    Remove-ItemProperty $RunOnceKey -Name winfiles -ErrorAction Ignore
    if ($registered) {
        Write-WinfilesLog resume "removed the RunOnce entry: the install ended with exit code $exitCode"
    }
} elseif ($registered) {
    Write-WinfilesLog resume "kept the RunOnce entry: the install stopped for a restart (exit code $exitCode)"
}
exit $exitCode
