#Requires -Version 5.1
<#
.SYNOPSIS
    Installs WSL and enables Virtual Machine Platform, ahead of `dsc config set`.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1 with no extra modules.
    `wsl --install --no-distribution` installs the WSL package and enables
    Virtual Machine Platform in one step (the winget package doesn't enable the
    feature). Enabling the feature needs a restart, which would interrupt DSC,
    so this runs before it. No distribution is installed: NixOS comes from
    dsc/wsl/wsl.dsc.yaml, after the .wslconfig it writes.
    Skips when WSL is already ready, using the same check as the prerequisites
    in dsc/resources/wsldistribution.ps1. Self-elevates through UAC if needed.
    Exits with 3010 when Windows needs a restart, so `just install` stops
    before running DSC; run it again after the restart.
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

if (Test-Wsl) {
    Write-Host "WSL $(Get-WslVersion) installed and Virtual Machine Platform enabled. Skipping..."
    return
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

if (Test-Wsl) {
    Write-Host "WSL $(Get-WslVersion) installed and Virtual Machine Platform enabled."
} else {
    # Until the restart the feature is pending, so it doesn't read as enabled
    Write-Warning 'Restart Windows, then run `just install` again: Virtual Machine Platform needs a restart to take effect.'
    exit 3010
}
