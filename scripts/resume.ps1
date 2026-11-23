# Shared by the scripts that arm or clear the resume, which dot-source it, after winlog.ps1: restart.ps1 (which
# arms it when a run stops for a restart) and commands.ps1 (which clears it when an install starts). Runs under
# Windows PowerShell 5.1 too.
#
# The resume is a per-user RunOnce value, `winfiles`, that starts scripts/Resume-Winfiles.ps1 at the next sign-in
# with the install's arguments. Windows deletes a RunOnce value before running it, so a resume never has to remove
# its own entry; a run that stops for another restart arms it again. The entry is armed late, only by a run that is
# about to restart or ask for one, so a run that never restarts leaves nothing to undo. The arguments come from
# WINFILES_RESUME, a JSON array that winfiles.ps1 sets for a command that is `resumable` in commands.jsonc.
# Without it (`winfiles.ps1 system`, say) nothing is armed, and the person runs the command again.
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

    if ($env:WINFILES_RESUME) {
        $arguments = @(ConvertFrom-Json -InputObject $env:WINFILES_RESUME)
        $resumeScript = Join-Path -Path $PSScriptRoot -ChildPath 'Resume-Winfiles.ps1'
        $resume = ('cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit ' +
            "-File `"$resumeScript`"")
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
