#Requires -Version 5.1

<#
.SYNOPSIS
Runs `winfiles.ps1 install` through Start-Clean.ps1, with a RunOnce entry waiting to continue it at the next
sign-in if it stops for a restart.

.DESCRIPTION
install.cmd runs this under Windows PowerShell 5.1, so it keeps to 5.1's syntax. The install itself goes through
Start-Clean.ps1, which finds mise from the registry's PATH and starts Invoke-Clean.ps1 under mise's pwsh, since
Invoke-Clean.ps1 needs pwsh 7.3 or later.
Before the run it writes a per-user RunOnce value, `winfiles`, that starts scripts/Resume-Winfiles.ps1 with the
same arguments at the next sign-in. It's written first because writing it afterwards would race the shutdown that
Invoke-Configuration.ps1 starts. After the run it's removed unless the run stopped for a restart: 3010, or 194
through `mise exec`, which cuts an exit code to its low byte. Windows deletes a RunOnce value before running it,
and the resumed run writes it again if it stops for another restart, so declining UAC or any failure ends the
chain. Exits with the install's exit code.

.EXAMPLE
./scripts/Invoke-Install.ps1 iris

Installs iris's configurations, continuing after a restart.
#>
# No positional binding, or the first argument would go to $RunOnceKey
[CmdletBinding(PositionalBinding = $false)]
param(
    # What `winfiles.ps1 install` takes: the host, then the user.
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments,

    # The registry key that holds the entry. For the tests.
    [string]$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')

    $resumeScript = Join-Path -Path $PSScriptRoot -ChildPath 'Resume-Winfiles.ps1'
    $resume = ('cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit ' +
        "-File `"$resumeScript`"")
    foreach ($argument in $Arguments) {
        $resume += " `"$argument`""
    }

    # RunOnce's documented limit. Only the resume depends on it, so the install still goes ahead
    $registered = $resume.Length -le 260
    if (-not $registered) {
        Write-Warning -Message ("The repo's path is too long for a RunOnce entry, " +
            'so run install.cmd again after any restart.')
        Write-WinfilesLog -Phase resume -Message (
            ("not registered: the RunOnce entry would be $($resume.Length) characters, over 260, " +
            'so run install.cmd again after any restart'))
    } else {
        # Not New-Item -Force, which would empty a key that exists
        if (-not (Test-Path -Path $RunOnceKey)) {
            New-Item -Path $RunOnceKey | Out-Null
        }
        # No `!` on the name: Windows deletes the value before running it, so a resume that fails isn't retried at
        # every sign-in
        New-ItemProperty -Path $RunOnceKey -Name winfiles -Value $resume -Force | Out-Null
        Write-WinfilesLog -Phase resume -Message ('registered the RunOnce entry, ' +
            'which continues the install at the next sign-in if it stops for a restart')
    }

    # A child process, because Start-Clean.ps1 ends with `exit` and changes its own PATH. --clean tells
    # winfiles.ps1 that Start-Clean.ps1 has cleaned the environment already
    $shell = (Get-Process -Id $PID).Path
    $startClean = Join-Path -Path $PSScriptRoot -ChildPath 'Start-Clean.ps1'
    $runner = Join-Path -Path (Split-Path -Path $PSScriptRoot) -ChildPath 'winfiles.ps1'
    $install = @('pwsh', '-NoLogo', '-NoProfile', '-File', $runner, '--clean', 'install')
    & $shell -NoProfile -ExecutionPolicy Bypass -File $startClean @install @Arguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -notin 194, 3010) {
        Remove-ItemProperty -Path $RunOnceKey -Name winfiles -ErrorAction Ignore
        if ($registered) {
            Write-WinfilesLog -Phase resume -Message (
                "removed the RunOnce entry: the install ended with exit code $exitCode")
        }
    } elseif ($registered) {
        Write-WinfilesLog -Phase resume -Message (
            "kept the RunOnce entry: the install stopped for a restart (exit code $exitCode)")
    }
    exit $exitCode
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
