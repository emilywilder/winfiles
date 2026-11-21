#Requires -Version 7.4

<#
.SYNOPSIS
Applies the configuration of what Windows needs a restart for, and stops for the restart if one is then pending.

.DESCRIPTION
Meant for an elevated shell, before anything installs: Invoke-Configuration.ps1 runs it on the first batch, which holds
what reported it will need a restart (`_restartRequired`) and what that depends on, such as WSL with the optional
features. The document is tested first, and each resource reports a restart it will need as `_restartRequired`,
so what's about to need one is known before anything is applied. What differs is applied next. If Windows then has a
restart pending (restart.ps1 reads it from the machine, not from what DSC reported), it restarts by itself, after 10
seconds (counted down in a progress bar) for Ctrl+C, when this run made the restart pending, and otherwise only asks,
since it may be Windows Update's.
Either way it exits with 3010, and install.cmd continues after the restart. Otherwise it exits 0, or with dsc's exit
code when the test or the apply fails (Set-Winfiles.ps1 prints that).

.EXAMPLE
gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Set-RestartStage.ps1 <batch document>

Applies a restart batch, elevated, and restarts if it leaves a restart pending.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The document to test and apply, which has to be flat (a batch of Invoke-Configuration.ps1).
    [Parameter(Mandatory)]
    [string]$File
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'dsclog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'restart.ps1')

    # Tested before anything is applied, so a run knows what will need a restart (the resources say so from `test`)
    Write-WinfilesLog -Phase apply -Message "testing $File for what needs a restart"
    $document = Get-RunDocument -File $File -Phase apply
    if (-not $document) {
        exit 1
    }
    $json = Invoke-DscLogged -Operation test -File $document
    if ($LASTEXITCODE) {
        $message = "${File}: dsc failed with exit code $LASTEXITCODE"
        Write-Host -Object $message -ForegroundColor Red
        Write-WinfilesLog -Phase apply -Message $message
        exit $LASTEXITCODE
    }
    $results = ($json | ConvertFrom-Json).results
    $differing = @(Get-ResourceResult -Results $results | Where-Object -FilterScript { -not $_.result.inDesiredState })
    $expected = @(Get-RestartReport -Results $results)
    if ($expected) {
        $names = ($expected | ForEach-Object -Process { "$($_.Type) '$($_.Name)'" }) -join ', '
        $message = "a restart will be needed by: $names"
        Write-Host -Object $message
        Write-WinfilesLog -Phase apply -Message $message
    }

    # A restart already pending before anything is applied isn't this run's, whatever it is (Windows Update's, say)
    $pendingBefore = Test-BlockingRestartPending
    if ($differing) {
        & (Join-Path -Path $PSScriptRoot -ChildPath 'Set-Winfiles.ps1') -File $File -WhatIf:$WhatIfPreference
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
    }

    # The gate. What the machine says decides, since a restart can be pending without DSC having reported it
    if (Test-BlockingRestartPending) {
        $done = ''
        if ($differing) {
            $done = 'Applied ' + (($differing | ForEach-Object -Process { "$($_.Type) '$($_.Name)'" }) -join ', ') + '. '
        }
        # Only a restart this run caused is started for the person: otherwise it may be Windows Update's, and open
        # work
        if ($differing -and -not $pendingBefore) {
            Restart-Windows -Phase apply -Done $done -WhatIf:$WhatIfPreference
        }
        Exit-RestartPending -Phase apply -Done $done
    }
    exit 0
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
