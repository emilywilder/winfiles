#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps winfiles on a fresh Windows 11 install: mise, the repo's
    tools, then `just install`.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1, since nothing else is
    installed yet. Run it unelevated: `just install` asks for UAC itself, and
    Scoop's installer refuses an elevated shell.
    1. Installs mise with winget, unless it's already installed.
       `--source winget` keeps winget away from the msstore source, which
       stops to ask for its terms on a fresh install;
       `--accept-package-agreements` accepts mise's licence. winget may still
       ask for UAC to install the Visual C++ runtime mise depends on.
    2. Reloads PATH for this process from the machine and user values, so
       mise is found without opening a new terminal. It only changes this
       process's PATH, never the persistent one.
    3. `mise trust` and `mise install`: just, pwsh, gsudo and DSC.
    4. `mise exec -- just install`, and exits with its exit code.
    Each step skips what's already done, so run it again after the restart
    `just install` asks for (or run `mise exec -- just install` then).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-Winfiles.ps1
#>
[CmdletBinding()]
param()

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

& mise exec -- just install
exit $LASTEXITCODE
