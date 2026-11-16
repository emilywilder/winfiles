#Requires -Version 5.1

<#
.SYNOPSIS
Continues `install.cmd` after a restart: scripts/Invoke-Install.ps1 sets this up to start at the next sign-in, through a per-user RunOnce entry.

.DESCRIPTION
Runs in a window that stays open, so the result can be read. install.cmd runs as a child process for the same
reason: its exit ends only the child. Invoke-Install.ps1 registers the entry again if the run stops for another
restart. A restart still pending ends things here, before the UAC prompt, so restarts don't keep asking.

.PARAMETER Arguments
What install.cmd was run with, passed on to it unchanged.

.PARAMETER RebootPendingKey
The registry key whose existence means a restart is pending. For the tests.

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

Write-Host 'Windows restarted. Continuing the winfiles install, which asks for UAC once.'

if (Test-Path $RebootPendingKey) {
    Write-Warning 'Windows still has a restart pending. Restart, then run install.cmd again.'
    return
}

# Wi-Fi can still be connecting at sign-in, and the install's packages need winget's source.
# After the wait it goes ahead anyway: this check can fail where winget works, behind a proxy for one
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while (-not (Test-NetConnection $SourceHost -Port $SourcePort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    if ((Get-Date) -ge $deadline) {
        Write-Warning "Can't reach winget's source. Trying anyway."
        break
    }
    Start-Sleep -Seconds 5
}

& (Join-Path (Split-Path $PSScriptRoot) 'install.cmd') @Arguments
if ($LASTEXITCODE) {
    Write-Warning "install.cmd exited with code $LASTEXITCODE."
} else {
    Write-Host 'The winfiles install finished.'
}
