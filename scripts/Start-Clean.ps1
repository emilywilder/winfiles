#Requires -Version 5.1

<#
.SYNOPSIS
Starts Invoke-Clean.ps1 under mise's pwsh, from Windows PowerShell 5.1, for install.cmd.

.DESCRIPTION
install.cmd has no pwsh to start: right after the bootstrap, pwsh is only in mise.toml's tools, and mise itself is
on the machine or user PATH in the registry but not in the terminal that ran the bootstrap. This reads that PATH,
finds mise, and runs `mise exec -- pwsh Invoke-Clean.ps1 <command>`, which rebuilds the environment from there.
It keeps to 5.1's syntax, and changes this process and its children only, never the persistent PATH.
Any mise configuration other than the repo's mise.toml is ignored, as in Invoke-Clean.ps1, so a global config's
tools aren't installed by this first `mise exec`. Arguments with quotes inside them don't survive 5.1 passing them
to pwsh. There's no param() block: every argument is the command, passed on as it is.

.EXAMPLE
./scripts/Start-Clean.ps1 pwsh -NoProfile -File winfiles.ps1 --clean install iris

Runs `winfiles.ps1 install iris` with nothing from this shell's environment.
#>

$ErrorActionPreference = 'Stop'
try {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User'))

    # Otherwise the call below fails as a non-terminating error and the script exits 0
    if (-not (Get-Command -Name mise -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('mise isn''t on the machine or user PATH.')
        exit 1
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath 'miseignore.ps1')
    $listing = (& mise config ls --json 2>$null) -join "`n"
    $miseToml = Join-Path -Path (Split-Path -Path $PSScriptRoot) -ChildPath 'mise.toml'
    $env:MISE_IGNORED_CONFIG_PATHS = Get-MiseIgnoredConfig -Listing $listing -Own $miseToml `
        -Ignored $env:MISE_IGNORED_CONFIG_PATHS

    $invokeClean = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Clean.ps1'
    & mise exec -- pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $invokeClean @args
    exit $LASTEXITCODE
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
