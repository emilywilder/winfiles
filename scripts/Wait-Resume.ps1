#Requires -Version 7.4

<#
.SYNOPSIS
Holds a resume after a restart until it can go ahead: stops if Windows still has a restart pending, and otherwise
waits for the person to press Enter and for winget's source to be reachable.

.DESCRIPTION
The first step of `winfiles.ps1 resume`, which the RunOnce entry (scripts/resume.ps1) starts at the next sign-in;
the install is its next step. A restart still pending ends things here, with exit code 3010 and before the UAC
prompt, so restarts don't keep asking. Otherwise it waits for Enter before going on, since a sign-in can happen
with nobody there (the test VM signs in by itself), and a UAC prompt left unanswered is cancelled, which ends the
install. Then it waits up to -WaitSeconds for winget's source, since Wi-Fi can still be connecting at sign-in;
after that it goes ahead anyway, since this check can fail where winget works.

.EXAMPLE
./scripts/Wait-Resume.ps1

Asks for Enter, then waits for winget's source, as a resume does before it runs the install.
#>
[CmdletBinding()]
param(
    # The registry key whose existence means a servicing restart is pending (restart.ps1 reads it). For the tests.
    [string]$RebootPendingKey =
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',

    # The host whose reachability is checked before the install. For the tests.
    [string]$SourceHost = 'cdn.winget.microsoft.com',

    # The port checked on SourceHost. For the tests.
    [int]$SourcePort = 443,

    # How long to wait for SourceHost before going ahead anyway. For the tests.
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'restart.ps1')
    $Script:ServicingKey = $RebootPendingKey

    Write-Host -Object 'Windows restarted. The winfiles install can continue.'

    if (Test-BlockingRestartPending) {
        Write-Warning -Message 'Windows still has a restart pending. Restart, then run install.cmd again.'
        Write-WinfilesLog -Phase resume -Message ('stopped before the install: ' +
            'Windows still has a restart pending. Restart, then run install.cmd again')
        exit 3010
    }

    # Sign-in doesn't mean someone is there: the test VM signs in by itself (New-TestVm.ps1 -Unattended), and a
    # UAC prompt nobody answers is cancelled, which ends the install (2026-11-17). So wait for the person first
    $prompt = 'Press Enter to continue. It asks for UAC once, then runs by itself.'
    Write-Host -Object $prompt -ForegroundColor Green
    $null = Read-Host
    Write-WinfilesLog -Phase resume -Message 'continuing: Enter pressed'

    # Wi-Fi can still be connecting at sign-in, and the install's packages need winget's source.
    # After the wait it goes ahead anyway: this check can fail where winget works, behind a proxy for one
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $connection = @{
        ComputerName     = $SourceHost
        Port             = $SourcePort
        InformationLevel = 'Quiet'
        WarningAction    = 'SilentlyContinue'
    }
    while (-not (Test-NetConnection @connection)) {
        if ((Get-Date) -ge $deadline) {
            Write-Warning -Message "Can't reach winget's source. Trying anyway."
            Write-WinfilesLog -Phase resume -Message ("can't reach winget's source " +
                "(${SourceHost}:$SourcePort) after ${WaitSeconds}s, trying anyway")
            break
        }
        Start-Sleep -Seconds 5
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
