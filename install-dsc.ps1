#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Microsoft DSC v3 on a stock Windows 11 installation.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1 with no extra modules.
    Prefers the Microsoft Store package via winget (the same package dsc.yaml
    manages, so it is not reinstalled later). Falls back to the latest
    GitHub release zip, installed per-user, if winget is unavailable or fails.
    The GitHub install is put on PATH for this process only; the persistent
    PATH is left to the PowerShell profile.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dsc.ps1
#>
[CmdletBinding()]
param(
    # Skip winget and install straight from GitHub releases
    [switch] $FromGitHub
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is very slow in 5.1 with the progress bar

$storeId = '9NVTPZWRC6KQ'
$appInstallerFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$githubInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\dsc'

function Test-Dsc {
    [bool] (Get-Command dsc -ErrorAction SilentlyContinue)
}

function Install-DscWithWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        # On a fresh install App Installer is present but winget isn't
        # registered for the user until the Store updates it
        Write-Host 'winget not found. Registering App Installer...'
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage $appInstallerFamily
        } catch {
            Write-Warning "Could not register App Installer: $_"
            return $false
        }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            return $false
        }
    }

    Write-Host 'Installing DSC from the Microsoft Store with winget...'
    winget install --id $storeId --source msstore --exact `
        --accept-package-agreements --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget exited with code $LASTEXITCODE"
        return $false
    }
    return $true
}

function Install-DscFromGitHub {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/PowerShell/DSC/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -like "*-$arch-pc-windows-msvc.zip" } | Select-Object -First 1
    if (-not $asset) {
        throw "No Windows $arch asset found in DSC release $($release.tag_name)"
    }

    Write-Host "Installing DSC $($release.tag_name) from GitHub to $githubInstallDir..."
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $zip = Join-Path $tempDir $asset.name
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
        if (Test-Path $githubInstallDir) {
            Remove-Item -Recurse -Force $githubInstallDir
        }
        Expand-Archive -Path $zip -DestinationPath $githubInstallDir
    } finally {
        Remove-Item -Recurse -Force $tempDir
    }

    # The persistent PATH is owned by the pwsh profile, so only this process is changed
    if (($env:Path -split ';') -notcontains $githubInstallDir) {
        $env:Path += ";$githubInstallDir"
    }
    Write-Warning "$githubInstallDir is not on the persistent PATH. Add it in your PowerShell profile."
}

if (Test-Dsc) {
    Write-Host "dsc already installed: $((Get-Command dsc).Source). Skipping..."
    return
}

if ($FromGitHub -or -not (Install-DscWithWinget)) {
    if (-not $FromGitHub) {
        Write-Host 'Falling back to GitHub release...'
    }
    Install-DscFromGitHub
}

if (-not (Test-Dsc)) {
    throw 'DSC was installed but dsc is not on PATH. Open a new terminal and try again.'
}
dsc --version
