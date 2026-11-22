#Requires -Version 7.4

<#
.SYNOPSIS
Runs a command unelevated: as it is from an unelevated shell, and through `gsudo -i Medium` from an elevated one.

.DESCRIPTION
A recipe says what privilege a step needs by going through this or Invoke-AsAdmin.ps1, and the script decides
whether anything has to change, so the same recipe works from either kind of terminal. From an unelevated shell the
command runs directly, as it would without this. From an elevated one it runs under `gsudo -i Medium --direct mise
exec --`, which gives a child that isn't an administrator, at Medium integrity, with the caller's console and exit
code (checked 2026-11-18 on iris and in the test VM, docs/reference/windows.md). Scoop's installer and the per-user
winget packages need that.
The command goes through `mise exec` like the elevated system step, so it finds mise.toml's tools. gsudo has to be
on PATH when a hop is needed: run this under `mise exec`, as the recipes do through Invoke-Clean.ps1.
Everything after the script's name is the command and its arguments, and the script exits with its exit code. There
is no param() block on purpose: a command's own dash arguments (`-Out`, say) would otherwise be matched to
PowerShell's common parameters, such as -OutVariable, and fail as ambiguous. For the tests, WINFILES_ELEVATED
("true" or "false") says whether this process is elevated instead of asking Windows, and WINFILES_GSUDO is the
gsudo to run.

.EXAMPLE
./scripts/Invoke-AsUser.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Set-Winfiles.ps1 dsc/emily@iris.home.dsc.yaml

Applies emily@iris's home configuration unelevated, from either kind of shell.
#>

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'privilege.ps1')

    $command = [string[]]$args
    $gsudo = if ($env:WINFILES_GSUDO) { $env:WINFILES_GSUDO } else { 'gsudo' }
    $isElevated = if ($env:WINFILES_ELEVATED) { $env:WINFILES_ELEVATED -eq 'true' } else { Test-Elevated }

    if (-not $command) {
        [Console]::Error.WriteLine('Invoke-AsUser.ps1 needs a command to run.')
        exit 2
    }

    if (-not $isElevated) {
        & $command[0] @($command | Select-Object -Skip 1)
        exit $LASTEXITCODE
    }

    if (-not (Get-Command -Name $gsudo -ErrorAction Ignore)) {
        $message = "This shell is elevated and the command has to run unelevated, but $gsudo isn't on PATH."
        [Console]::Error.WriteLine($message)
        Write-WinfilesLog -Phase privilege -Message $message
        exit 1
    }
    Write-WinfilesLog -Phase privilege -Message "running unelevated through gsudo -i Medium: $($command -join ' ')"
    & $gsudo -i Medium --direct mise exec '--' @command
    exit $LASTEXITCODE
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
