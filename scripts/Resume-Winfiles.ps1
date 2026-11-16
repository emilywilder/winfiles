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

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/Resume-Winfiles.ps1 iris
#>
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host 'Windows restarted. Continuing the winfiles install, which asks for UAC once.'

if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    Write-Warning 'Windows still has a restart pending. Restart, then run install.cmd again.'
    return
}

# Wi-Fi can still be connecting at sign-in, and the install's packages need winget's source.
# After the wait it goes ahead anyway: this check can fail where winget works, behind a proxy for one
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-NetConnection cdn.winget.microsoft.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
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
