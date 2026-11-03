#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps winfiles on a fresh Windows 11 install: mise, the repo's
    tools, then `just install`.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1, since nothing else is
    installed yet. Run it unelevated: `just install` asks for UAC itself, and
    Scoop's installer refuses an elevated shell.
    1. Updates App Installer, which provides winget. A new Windows image can
       ship one too old for what follows: with 1.26.509, the WinGet PowerShell
       module fails when elevated (0x800706BA), and setting the msstore source
       explicit removes the source and fails.
       `--source winget` keeps winget away from the msstore source, which
       stops to ask for its terms on a fresh install;
       `--accept-package-agreements` accepts the licence.
    2. Installs mise with winget, unless it's already installed. winget may
       ask for UAC to install the Visual C++ runtime mise depends on.
    3. Reloads PATH for this process from the machine and user values, so
       mise is found without opening a new terminal. It only changes this
       process's PATH, never the persistent one.
    4. `mise trust` and `mise install`: just, pwsh, gsudo and DSC.
    5. `mise exec -- just install`, and exits with its exit code.
    Each step skips what's already done, so run it again after the restart
    `just install` asks for (or run `mise exec -- just install` then).

.PARAMETER HostName
    The host configuration to apply, for a machine whose computer name doesn't
    match one (a new install usually has a generated name). Defaults to the
    computer name.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-Winfiles.ps1 -HostName iris
#>
[CmdletBinding()]
param(
    [string]$HostName
)

$ErrorActionPreference = 'Stop'

function Update-ProcessPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Invoke-Native([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE) {
        Write-Error "$Command $Arguments exited with code $LASTEXITCODE"
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    throw 'Run this from an unelevated terminal: just install asks for UAC itself, and the Scoop installer refuses an elevated shell.'
}

Write-Host 'Updating App Installer with winget...'
& winget install --id Microsoft.AppInstaller --exact --source winget --accept-package-agreements
# 0x8A15002B: no newer version is available, so it's up to date
if ($LASTEXITCODE -and $LASTEXITCODE -ne -1978335189) {
    Write-Error "Updating App Installer failed with code $LASTEXITCODE"
}

# mise may be installed already, by an earlier run, with this terminal opened before it
Update-ProcessPath
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Write-Host 'mise is installed. Skipping...'
} else {
    Write-Host 'Installing mise with winget...'
    Invoke-Native winget @('install', '--id', 'jdx.mise', '--exact', '--source', 'winget', '--accept-package-agreements')
    Update-ProcessPath
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        throw 'winget installed mise, but it isn''t on PATH. Open a new terminal and run this script again.'
    }
}

Set-Location (Split-Path $PSScriptRoot)
Invoke-Native mise @('trust')
Invoke-Native mise @('install')

$justArguments = @('install')
if ($HostName) { $justArguments += $HostName }
& mise exec -- just @justArguments
exit $LASTEXITCODE
