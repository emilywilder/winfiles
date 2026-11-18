#Requires -Version 5.1

<#
.SYNOPSIS
Continues `install.cmd` after a restart: scripts/Invoke-Install.ps1 sets this up to start at the next sign-in, through a per-user RunOnce entry.

.DESCRIPTION
Runs in a window that stays open, so the result can be read. install.cmd runs as a child process for the same
reason: its exit ends only the child. Invoke-Install.ps1 registers the entry again if the run stops for another
restart. A restart still pending ends things here, before the UAC prompt, so restarts don't keep asking.
Otherwise it waits for Enter before going on, since a sign-in can happen with nobody there (the test VM signs in by
itself), and a UAC prompt left unanswered is cancelled, which ends the install.

.PARAMETER Arguments
What install.cmd was run with, passed on to it unchanged.

.PARAMETER RebootPendingKey
The registry key whose existence means a servicing restart is pending (restart.ps1 reads it). For the tests.

.PARAMETER SourceHost
The host whose reachability is checked before the install. For the tests.

.PARAMETER SourcePort
The port checked on SourceHost. For the tests.

.PARAMETER WaitSeconds
How long to wait for SourceHost before going ahead anyway. For the tests.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Resume-Winfiles.ps1 iris
#>
# No positional binding, or the first argument would go to $RebootPendingKey
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments,
    [string]$RebootPendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    [string]$SourceHost = 'cdn.winget.microsoft.com',
    [int]$SourcePort = 443,
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')
$script:ServicingKey = $RebootPendingKey

Write-Host 'Windows restarted. The winfiles install can continue.'
Write-WinfilesLog resume "resumed after sign-in: install.cmd $Arguments"

# RunOnce starts this in C:\Windows\System32. The window stays open (-NoExit), so leave it in the repo
Set-Location (Split-Path $PSScriptRoot)

if (Test-BlockingRestartPending) {
    Write-Warning 'Windows still has a restart pending. Restart, then run install.cmd again.'
    Write-WinfilesLog resume 'stopped before install.cmd: Windows still has a restart pending. Restart, then run install.cmd again'
    return
}

# Sign-in doesn't mean someone is there: the test VM signs in by itself (New-TestVm.ps1 -Unattended), and a UAC
# prompt nobody answers is cancelled, which ends the install (2026-11-17). So wait for the person first
Write-Host 'Press Enter to continue. It asks for UAC once, then runs by itself.' -ForegroundColor Green
$null = Read-Host
Write-WinfilesLog resume 'continuing: Enter pressed'

# Wi-Fi can still be connecting at sign-in, and the install's packages need winget's source.
# After the wait it goes ahead anyway: this check can fail where winget works, behind a proxy for one
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while (-not (Test-NetConnection $SourceHost -Port $SourcePort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    if ((Get-Date) -ge $deadline) {
        Write-Warning "Can't reach winget's source. Trying anyway."
        Write-WinfilesLog resume "can't reach winget's source (${SourceHost}:$SourcePort) after ${WaitSeconds}s, trying anyway"
        break
    }
    Start-Sleep -Seconds 5
}

& (Join-Path (Split-Path $PSScriptRoot) 'install.cmd') @Arguments
$exitCode = $LASTEXITCODE
Write-WinfilesLog resume "install.cmd exited with code $exitCode"
if ($exitCode) {
    Write-Warning "install.cmd exited with code $exitCode."
} else {
    Write-Host 'The winfiles install finished.'
}
