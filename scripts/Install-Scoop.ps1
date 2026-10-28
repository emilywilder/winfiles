#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Scoop, ahead of `dsc config set`.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1 with no extra modules.
    Downloads Scoop's own installer and runs it. The installer refuses to run
    elevated, and a `set` of the whole dsc/winfiles.dsc.yaml runs elevated, so
    Scoop is installed here, from a normal shell, instead of from
    dsc/packages/scoop.dsc.yaml. The installer adds the main bucket;
    the other buckets, git and the apps come from that document.
    Skips when Scoop is already installed, using the same root lookup as
    dsc/resources/scooppackagelist.ps1. The installer adds Scoop's shims
    folder to the user PATH, which is allowed for Scoop; this script doesn't
    touch PATH itself.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-Scoop.ps1
#>
[CmdletBinding()]
param(
    # URL of Scoop's install script
    [string] $InstallerUrl = 'https://get.scoop.sh'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is very slow in 5.1 with the progress bar

# Keep in step with the root lookup in dsc/resources/scooppackagelist.ps1:
# $env:SCOOP, then root_path in Scoop's config, then ~\scoop
function Get-ScoopRoot {
    $configDir = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $configFile = Join-Path $configDir 'scoop\config.json'
    $configRoot = if (Test-Path $configFile) { (Get-Content -Raw $configFile | ConvertFrom-Json).root_path }
    @($env:SCOOP, $configRoot, (Join-Path $HOME 'scoop')) | Where-Object { $_ } | Select-Object -First 1
}

function Test-Scoop {
    Test-Path (Join-Path (Get-ScoopRoot) 'apps\scoop\current\bin\scoop.ps1')
}

if (Test-Scoop) {
    Write-Host "Scoop already installed at $(Get-ScoopRoot). Skipping..."
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    throw 'Scoop refuses to install from an elevated shell. Run this from a normal (unelevated) shell.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Download to a file instead of piping into Invoke-Expression, so the installer runs as a script
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $installer = Join-Path $tempDir 'install.ps1'
    Write-Host "Downloading Scoop's installer from $InstallerUrl..."
    Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $installer
    & $installer
} finally {
    Remove-Item -Recurse -Force $tempDir
}

if (-not (Test-Scoop)) {
    throw "Scoop's installer finished but Scoop isn't at $(Get-ScoopRoot)."
}
Write-Host "Scoop installed at $(Get-ScoopRoot)."
