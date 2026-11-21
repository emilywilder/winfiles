# Shared by the scripts that stop or restart Windows, which dot-source it (Invoke-Configuration.ps1,
# Set-RestartStage.ps1, Resume-Winfiles.ps1). Runs under Windows PowerShell 5.1 too, and needs winlog.ps1 dot-sourced
# first.
#
# Get-RestartReason derives why Windows needs a restart from the machine, rather than counting changes as they're
# made: a count would be lost across the restart the install resumes after, and wouldn't see a restart that Windows
# Update or an installer asked for. Each reason is a name and whether it Blocks: a blocking reason must be restarted
# for before the install goes on (some installers refuse to run while it's pending), and a deferrable one can wait
# for a restart that's happening anyway, or for the end of the run.
# Not read: PendingFileRenameOperations. It's set by nearly every installer for files that are in use, it's still set
# after harmless ones, and nothing here waits on it. Revisit if an install step turns out to fail because of it.

$Script:ComputerNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
# A variable so Resume-Winfiles.ps1's tests can point it at a key of their own
$Script:ServicingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'


function Test-ServicingRestartPending {
    <#
    .SYNOPSIS
    Tests whether component servicing has a restart pending.

    .DESCRIPTION
    Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on build
    26300); only this key shows that the restart is still to come.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Test-Path -Path $Script:ServicingKey
}


function Test-ComputerRenamePending {
    <#
    .SYNOPSIS
    Tests whether a computer rename is waiting for the next restart.

    .DESCRIPTION
    Rename-Computer changes ComputerName\ComputerName at once, and ActiveComputerName only at the next restart. The same
    keys Winfiles/ComputerName reads (dsc/resources/computername.ps1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $pending = (Get-ItemProperty -Path "$Script:ComputerNameKey\ComputerName").ComputerName
    $active = (Get-ItemProperty -Path "$Script:ComputerNameKey\ActiveComputerName").ComputerName
    $pending -ine $active
}


function Get-RestartReason {
    <#
    .SYNOPSIS
    Returns why Windows needs a restart: zero or more objects with Name and Blocking.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (Test-ServicingRestartPending) {
        [pscustomobject]@{ Name = 'component servicing'; Blocking = $true }
    }
    if (Test-ComputerRenamePending) {
        [pscustomobject]@{ Name = 'computer rename'; Blocking = $false }
    }
}


function Test-BlockingRestartPending {
    <#
    .SYNOPSIS
    Tests whether Windows has a restart pending that has to happen before the run goes on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool]@(Get-RestartReason | Where-Object -Property Blocking)
}


function Exit-RestartPending {
    <#
    .SYNOPSIS
    Stops the run, for a restart the person does, with exit code 3010.

    .DESCRIPTION
    install.cmd answers 3010 by keeping the resume entry.
    #>
    [CmdletBinding()]
    param(
        # The run log phase.
        [Parameter(Mandatory, Position = 0)]
        [string]$Phase,

        # What's already happened, said first.
        [Parameter(Position = 1)]
        [string]$Done
    )

    Write-Warning -Message ("${Done}Windows has a restart pending. Restart. " +
        'install.cmd then continues after you sign in and press Enter; after any other install command, run it again.')
    Write-WinfilesLog -Phase $Phase -Message ('install stopped for a restart: restart Windows. ' +
        'install.cmd then continues after sign-in, once Enter is pressed; ' +
        'after any other install command, run it again')
    exit 3010
}


function Restart-Windows {
    <#
    .SYNOPSIS
    Restarts Windows after 10 seconds, for Ctrl+C, then exits with 3010.

    .DESCRIPTION
    It counts down in a Write-Progress bar that drains from full to empty, with no warning. It still exits with 3010, so
    `just install` doesn't start DSC while Windows shuts down, and the resume entry is registered. ConfirmImpact is
    Medium, so it doesn't ask, as the countdown is the chance to stop it; -WhatIf only stops for the restart.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        # The run log phase.
        [Parameter(Mandatory, Position = 0)]
        [string]$Phase,

        # What's already happened, said first if the restart fails.
        [Parameter(Position = 1)]
        [string]$Done
    )

    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart Windows')) {
        Exit-RestartPending -Phase $Phase -Done $Done
    }
    Write-WinfilesLog -Phase $Phase -Message ('install stopped: restarting Windows in 10 seconds. ' +
        'install.cmd then continues after sign-in, once Enter is pressed; ' +
        'after any other install command, run it again')
    $seconds = 10
    for ($left = $seconds; $left -gt 0; $left--) {
        $progress = @{
            Activity         = 'Restarting the computer'
            Status           = "Restarting in $left s (Ctrl+C to cancel)"
            SecondsRemaining = $left
            PercentComplete  = 100 * $left / $seconds
        }
        Write-Progress @progress
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Restarting the computer' -Completed
    try {
        # No -Force: an app holding unsaved work can still stop the restart
        Restart-Computer -ErrorAction Stop
    } catch {
        $failure = $_
        Exit-RestartPending -Phase $Phase -Done "Restarting failed ($($failure.Exception.Message)). "
    }
    exit 3010
}
