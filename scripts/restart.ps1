# Shared by the scripts that stop or restart Windows, which dot-source it (Invoke-Configuration.ps1, Set-RestartStage.ps1, Resume-Winfiles.ps1). Runs under Windows PowerShell 5.1 too, and needs winlog.ps1 dot-sourced first.
#
# Get-RestartReasons derives why Windows needs a restart from the machine, rather than counting changes as they're
# made: a count would be lost across the restart the install resumes after, and wouldn't see a restart that Windows
# Update or an installer asked for. Each reason is a name and whether it Blocks: a blocking reason must be restarted
# for before the install goes on (some installers refuse to run while it's pending), and a deferrable one can wait
# for a restart that's happening anyway, or for the end of the run.
# Not read: PendingFileRenameOperations. It's set by nearly every installer for files that are in use, it's still set
# after harmless ones, and nothing here waits on it. Revisit if an install step turns out to fail because of it.

$script:ComputerNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
# A variable so Resume-Winfiles.ps1's tests can point it at a key of their own
$script:ServicingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

# Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on build
# 26300); only this key shows that the restart is still to come
function Test-ServicingRestartPending {
    Test-Path $script:ServicingKey
}

# Rename-Computer changes ComputerName\ComputerName at once, and ActiveComputerName only at the next restart. The
# same keys Winfiles/ComputerName reads (dsc/resources/computername.ps1)
function Test-ComputerRenamePending {
    $pending = (Get-ItemProperty -Path "$script:ComputerNameKey\ComputerName").ComputerName
    $active = (Get-ItemProperty -Path "$script:ComputerNameKey\ActiveComputerName").ComputerName
    $pending -ine $active
}

# Zero or more objects with Name and Blocking
function Get-RestartReasons {
    if (Test-ServicingRestartPending) { [pscustomobject]@{ Name = 'component servicing'; Blocking = $true } }
    if (Test-ComputerRenamePending) { [pscustomobject]@{ Name = 'computer rename'; Blocking = $false } }
}

# Any reason that has to be restarted for before the run goes on
function Test-BlockingRestartPending {
    [bool]@(Get-RestartReasons | Where-Object Blocking)
}

# Stops the run, for a restart the person does. $Phase is the winlog phase and $Done what's already happened, said
# first. Exits with 3010, which install.cmd answers by registering the resume entry
function Exit-RestartPending([string]$Phase, [string]$Done) {
    Write-Warning "${Done}Windows has a restart pending. Restart. install.cmd then continues after you sign in and press Enter; after any other install command, run it again."
    Write-WinfilesLog $Phase 'install stopped for a restart: restart Windows. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again'
    exit 3010
}

# Restarts Windows after 10 seconds, for Ctrl+C, counting down in a Write-Progress bar that drains from full to empty (no warning). Still exits with 3010, so `just install`
# doesn't start DSC while Windows shuts down, and the resume entry is registered
function Restart-Windows([string]$Phase, [string]$Done) {
    Write-WinfilesLog $Phase 'install stopped: restarting Windows in 10 seconds. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again'
    $seconds = 10
    for ($left = $seconds; $left -gt 0; $left--) {
        Write-Progress -Activity 'Restarting the computer' -Status "Restarting in $left s (Ctrl+C to cancel)" -SecondsRemaining $left -PercentComplete (100 * $left / $seconds)
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Restarting the computer' -Completed
    try {
        # No -Force: an app holding unsaved work can still stop the restart
        Restart-Computer
    } catch {
        Exit-RestartPending $Phase "Restarting failed ($_). "
    }
    exit 3010
}
