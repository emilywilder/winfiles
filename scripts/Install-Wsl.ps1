#Requires -Version 5.1
<#
.SYNOPSIS
    Installs WSL and enables Virtual Machine Platform, ahead of `dsc config set`.

.DESCRIPTION
    `just wsl-install` runs it under mise's pwsh 7, but it sticks to Windows
    PowerShell 5.1 with no extra modules, so it also runs by hand on a bare
    machine.
    `wsl --install --no-distribution` installs the WSL package and enables
    Virtual Machine Platform in one step (the winget package doesn't enable the
    feature). Enabling the feature needs a restart, which would interrupt DSC,
    so this runs before it. `just install` enables the feature first, from
    dsc/features/features.dsc.yaml, which declares it with the other optional
    features; here it's enabled too so the script also works on its own.
    No distribution is installed: NixOS comes from
    dsc/wsl/wsl.dsc.yaml, after the .wslconfig it writes.
    Skips when WSL is already ready, using the same check as the prerequisites
    in dsc/resources/wsldistribution.ps1. Self-elevates through UAC if needed.
    Exits with 3010 while Windows has a restart pending, whatever caused it
    (Windows Update too), so `just install` stops before running DSC: some
    installers refuse to run then. Run it again after the restart.
    The WSL installer adds its folder to the machine PATH itself; this script
    doesn't touch PATH.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-Wsl.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Keep in step with Test-Prerequisites in dsc/resources/wsldistribution.ps1
function Test-VirtualMachinePlatform {
    (Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'").InstallState -eq 1
}

function Get-WslVersion {
    # The inbox wsl.exe doesn't know --version; the version label is localized, so match the number only.
    # Before WSL is installed it writes "not installed" to stderr. Windows PowerShell 5.1 turns redirected
    # native stderr into errors, which 'Stop' would make fatal, so keep them non-terminating here
    $ErrorActionPreference = 'Continue'
    $env:WSL_UTF8 = '1'
    $output = @(& wsl.exe --version 2>$null)
    if ($LASTEXITCODE -eq 0 -and "$($output[0])" -match '(\d+\.\d+\.\d+)') { [version]$Matches[1] }
}

function Test-Wsl {
    $version = Get-WslVersion
    (Test-VirtualMachinePlatform) -and $version -and $version -ge [version]'2.4.4'
}

# Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on
# build 26300); only this key shows that the restart is still to come
function Test-RestartPending {
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

function Exit-RestartPending([string]$Done) {
    Write-Warning "${Done}Windows has a restart pending. Restart, then run ``just install`` again."
    exit 3010
}

if (Test-Wsl) {
    if (Test-RestartPending) { Exit-RestartPending "WSL $(Get-WslVersion) installed and Virtual Machine Platform enabled, but " }
    Write-Host "WSL $(Get-WslVersion) installed and Virtual Machine Platform enabled. Skipping..."
    exit 0
}

$wslArgs = @('--install', '--no-distribution')
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Running wsl.exe $wslArgs..."
if ($isAdmin) {
    & wsl.exe @wslArgs | Out-Host
    $exitCode = $LASTEXITCODE
} else {
    # Runs in its own elevated console window
    $exitCode = (Start-Process wsl.exe -ArgumentList $wslArgs -Verb RunAs -Wait -PassThru).ExitCode
}
# 3010 is the Windows Installer code for success with a restart required
if ($exitCode -notin 0, 3010) {
    throw "wsl.exe $wslArgs exited with code $exitCode"
}

if ((Test-Wsl) -and -not (Test-RestartPending)) {
    Write-Host "WSL $(Get-WslVersion) installed and Virtual Machine Platform enabled."
    exit 0
}
Exit-RestartPending 'WSL installed. '
