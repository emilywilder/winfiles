# Shared by the scripts that arm or clear the resume, which dot-source it, after winlog.ps1: restart.ps1 (which
# arms it when a run stops for a restart) and commands.ps1 (which clears it when an install starts).
#
# The resume is a per-user RunOnce value, `winfiles`, that starts `winfiles.ps1 resume <switch's arguments>`
# through scripts/Start-Winfiles.ps1 at the next sign-in. Windows deletes a RunOnce value before running it, so a
# resume never has to remove its own entry; a run that stops for another restart arms it again. The entry is armed
# late, only by a run that is about to restart or ask for one, so a run that never restarts leaves nothing to undo.
# The arguments come from WINFILES_RESUME, a JSON array that winfiles.ps1 sets for a `resumable` command given its
# resumable flag in commands.jsonc (`switch --restart`). Without it (`switch` alone, or `system`) nothing is armed,
# the run never restarts Windows itself (restart.ps1), and the person restarts and runs the command again.
# WINFILES_RUNONCE_KEY replaces the RunOnce key, for the tests: the real one would run a resume at the next
# sign-in.


function Get-ResumeKey {
    <#
    .SYNOPSIS
    Returns the registry key that holds the resume entry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:WINFILES_RUNONCE_KEY) {
        $env:WINFILES_RUNONCE_KEY
    } else {
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    }
}


function Test-ResumeRequested {
    <#
    .SYNOPSIS
    Tests whether the run asked to continue after a restart, which is also what lets it restart Windows itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool]$env:WINFILES_RESUME
}


function Register-Resume {
    <#
    .SYNOPSIS
    Arms the RunOnce entry that continues the install after a restart, when the run asked for a resume.

    .DESCRIPTION
    Does nothing without WINFILES_RESUME. A command over RunOnce's 260 characters only gets a warning, since the
    restart is still needed, and the person is told to run the install again. A value already there is replaced.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (Test-ResumeRequested) {
        $arguments = @(ConvertFrom-Json -InputObject $env:WINFILES_RESUME)
        $launcher = Join-Path -Path $PSScriptRoot -ChildPath 'Start-Winfiles.ps1'
        $repo = Split-Path -Path $PSScriptRoot
        # /D leaves the window, which stays open (-NoExit), in the repo: RunOnce starts it in System32
        $resume = ('cmd.exe /c start "winfiles" /D ' + "`"$repo`" " +
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit ' +
            "-File `"$launcher`" resume")
        foreach ($argument in $arguments) {
            $resume += " `"$argument`""
        }

        $key = Get-ResumeKey
        if ($resume.Length -gt 260) {
            Write-Warning -Message ("The repo's path is too long for a RunOnce entry, " +
                'so run install.cmd again after the restart.')
            Write-WinfilesLog -Phase resume -Message (
                ("not registered: the RunOnce entry would be $($resume.Length) characters, over 260, " +
                'so run install.cmd again after the restart'))
        } elseif ($PSCmdlet.ShouldProcess($key, 'Register the resume entry')) {
            # Not New-Item -Force, which would empty a key that exists
            if (-not (Test-Path -Path $key)) {
                [void](New-Item -Path $key)
            }
            # No `!` on the name: Windows deletes the value before running it, so a resume that fails isn't retried
            # at every sign-in
            [void](New-ItemProperty -Path $key -Name winfiles -Value $resume -Force)
            Write-WinfilesLog -Phase resume -Message ('registered the RunOnce entry, ' +
                'which continues the install at the next sign-in')
        }
    }
}


function Clear-Resume {
    <#
    .SYNOPSIS
    Removes the RunOnce entry an earlier run left, since this run decides for itself whether to restart.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $key = Get-ResumeKey
    $entry = Get-ItemProperty -Path $key -Name winfiles -ErrorAction Ignore
    if ($entry -and $PSCmdlet.ShouldProcess($key, 'Remove the resume entry')) {
        Remove-ItemProperty -Path $key -Name winfiles
        Write-WinfilesLog -Phase resume -Message 'removed the RunOnce entry an earlier run left'
    }
}
