#Requires -Version 7.4

<#
.SYNOPSIS
Runs a command elevated: as it is from an elevated shell, and through `gsudo` (one UAC prompt) from an unelevated one.

.DESCRIPTION
The counterpart of Invoke-AsUser.ps1. From an elevated shell the command runs directly. From an unelevated one it
runs under `gsudo --direct mise exec --`, in this console, so its output and exit code stay here and the run asks for
UAC once. The command goes through `mise exec` so the elevated process finds mise.toml's tools, as the system step always
has. gsudo has to be on PATH when a prompt is needed: run this under `mise exec`, as the recipes do through
Invoke-Clean.ps1.
Everything after the script's name is the command and its arguments, and the script exits with its exit code. There is
no param() block on purpose, for the reason Invoke-AsUser.ps1 gives. For the tests, WINFILES_ELEVATED ("true" or
"false") says whether this process is elevated instead of asking Windows, and WINFILES_GSUDO is the gsudo to run.

.EXAMPLE
./scripts/Invoke-AsAdmin.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Set-System.ps1 iris
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'privilege.ps1')

$command = [string[]]$args
$gsudo = if ($env:WINFILES_GSUDO) { $env:WINFILES_GSUDO } else { 'gsudo' }
$isElevated = if ($env:WINFILES_ELEVATED) { $env:WINFILES_ELEVATED -eq 'true' } else { Test-Elevated }

if (-not $command) {
    [Console]::Error.WriteLine('Invoke-AsAdmin.ps1 needs a command to run.')
    exit 2
}

if ($isElevated) {
    & $command[0] @($command | Select-Object -Skip 1)
    exit $LASTEXITCODE
}

if (-not (Get-Command $gsudo -ErrorAction Ignore)) {
    $message = "The command needs elevation, but $gsudo isn't on PATH."
    [Console]::Error.WriteLine($message)
    Write-WinfilesLog privilege $message
    exit 1
}
Write-WinfilesLog privilege "running elevated through gsudo (asking for UAC): $($command -join ' ')"
$asked = Get-Date
& $gsudo --direct mise exec '--' @command
$code = $LASTEXITCODE
# The time includes the command's own run, so it only shows how long the prompt waited for a command that fails at once
Write-WinfilesLog privilege "gsudo returned exit code $code after $([int]((Get-Date) - $asked).TotalSeconds)s"
exit $code
