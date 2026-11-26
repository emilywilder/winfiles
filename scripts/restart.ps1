# Shared by the scripts that stop or restart Windows, which dot-source it (Invoke-Configuration.ps1,
# Set-RestartStage.ps1, Wait-Resume.ps1). It needs winlog.ps1 dot-sourced first. It dot-sources resume.ps1, so each
# way it stops a run for a restart arms the resume when the run asked for one (`switch --restart`). A run that
# didn't ask never restarts Windows itself: it stops with 3010 and says what to do, so the person restarts when it
# suits them and runs the command again.
#
# Get-RestartReason derives why Windows needs a restart from the machine, rather than counting changes as they're
# made: a count would be lost across the restart the install resumes after, and wouldn't see a restart that Windows
# Update or an installer asked for. Each reason is a name and whether it Blocks: a blocking reason must be
# restarted for before the install goes on (some installers refuse to run while it's pending), and a deferrable one
# can wait for a restart that's happening anyway, or for the end of the run.
# Not read: PendingFileRenameOperations. It's set by nearly every installer for files that are in use, it's still
# set after harmless ones, and nothing here waits on it. Revisit if an install step turns out to fail because of
# it.

. (Join-Path -Path $PSScriptRoot -ChildPath 'resume.ps1')

$Script:ComputerNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
# A variable so Wait-Resume.ps1's tests can point it at a key of their own
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
    Rename-Computer changes ComputerName\ComputerName at once, and ActiveComputerName only at the next restart. The
    same keys Winfiles/ComputerName reads (dsc/resources/computername.ps1).
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


function Get-RerunCommand {
    <#
    .SYNOPSIS
    Returns what a person types to run this run's command again: `.\winfiles.cmd <command>`, or "the same command"
    when the runner didn't say which (WINFILES_COMMAND).

    .DESCRIPTION
    winfiles.cmd, since it runs in any terminal on a bootstrapped machine, even before the configuration has
    installed a pwsh.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:WINFILES_COMMAND) {
        "``.\winfiles.cmd $env:WINFILES_COMMAND``"
    } else {
        'the same command'
    }
}


function Exit-RestartPending {
    <#
    .SYNOPSIS
    Stops the run, for a restart the person does, with exit code 3010.

    .DESCRIPTION
    With a resume asked for (`switch --restart`), arms it first (resume.ps1), so the run continues after the person
    restarts. Otherwise it tells them to run the command again after the restart.
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

    if (Test-ResumeRequested) {
        Write-Warning -Message ("${Done}Windows has a restart pending. Restart, and the run continues " +
            'after you sign in and press Enter.')
        Write-WinfilesLog -Phase $Phase -Message ('stopped for a restart: restart Windows, ' +
            'and the run continues after sign-in, once Enter is pressed')
        Register-Resume
    } else {
        $rerun = Get-RerunCommand
        Write-Warning -Message ("${Done}Windows has a restart pending. Restart, then run $rerun again: " +
            'it carries on from here.')
        Write-WinfilesLog -Phase $Phase -Message "stopped for a restart: restart Windows, then run $rerun again"
    }
    exit 3010
}


function Restart-Windows {
    <#
    .SYNOPSIS
    Restarts Windows after 10 seconds, for Ctrl+C, then exits with 3010, when the run asked for a resume; otherwise
    stops the run for the person to restart (Exit-RestartPending).

    .DESCRIPTION
    Only a run that will continue after the restart (`switch --restart`) restarts Windows itself. It counts down in
    a Write-Progress bar that drains from full to empty, with no warning. It still exits with 3010, so
    `winfiles.ps1 switch` doesn't start DSC while Windows shuts down. The resume is armed (resume.ps1) after the
    countdown, so Ctrl+C leaves none, and before Restart-Computer, so the shutdown can't beat it. ConfirmImpact is
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

    $restart = (Test-ResumeRequested) -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart Windows')
    if (-not $restart) {
        Exit-RestartPending -Phase $Phase -Done $Done
    }
    Write-WinfilesLog -Phase $Phase -Message ('stopped: restarting Windows in 10 seconds, ' +
        'and the run continues after sign-in, once Enter is pressed')
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
    Register-Resume
    try {
        # No -Force: an app holding unsaved work can still stop the restart
        Restart-Computer -ErrorAction Stop
    } catch {
        $failure = $_
        Exit-RestartPending -Phase $Phase -Done "Restarting failed ($($failure.Exception.Message)). "
    }
    exit 3010
}
