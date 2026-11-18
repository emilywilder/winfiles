#Requires -Version 5.1

<#
.SYNOPSIS
    Installs or updates WSL and enables Virtual Machine Platform, ahead of `dsc config set`.

.DESCRIPTION
    `just wsl-install` runs it under mise's pwsh 7, but it sticks to Windows
    PowerShell 5.1 with no extra modules, so it also runs by hand on a bare
    machine.
    `wsl --install --no-distribution` installs the WSL package and enables
    Virtual Machine Platform in one step (the winget package doesn't enable the
    feature). Enabling the feature needs a restart, which would interrupt DSC,
    so this runs before it. `just install` enables the feature first, from
    dsc/hosts/<host>/features.dsc.yaml, which declares it with the other optional
    features; here it's enabled too so the script also works on its own.
    A WSL package older than 2.4.4, the first with --from-file and --name, is
    brought up to date with `wsl --update`.
    No distribution is installed: NixOS comes from
    dsc/modules/home/wsl.dsc.yaml, after the .wslconfig it writes.
    Skips when WSL is already ready, using the same check as the prerequisites
    in dsc/resources/wsldistribution.ps1. Self-elevates through UAC if needed.
    Exits with 3010 while Windows has a restart pending, whatever caused it
    (Windows Update too), so `just install` stops before running DSC: some
    installers refuse to run then. Run it again after the restart, which
    install.cmd does by itself at the next sign-in.
    When this run installed WSL and that left the restart pending, it also
    restarts Windows itself, after 30 seconds for Ctrl+C. A restart pending on a
    machine that already had WSL only gets the warning.
    Fails, rather than asking for another restart, when WSL still isn't ready
    and no restart is pending, or when no hypervisor is running.
    The WSL installer adds its folder to the machine PATH itself; this script
    doesn't touch PATH.
    Asks Windows for the feature and the WSL version once per look. wsl.exe is
    never run to ask for the version: on a fresh install `wsl.exe --version`
    took 60s, because the inbox wsl.exe, with no WSL package, waits 60s for a
    key that would install WSL. Instead the version is the file version of
    Program Files\WSL\wsl.exe, or else the version in the WSL package's
    registration, and without either there is no WSL.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Install-Wsl.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winlog.ps1')
$minimum = [version]'2.4.4'

# Whether the feature is enabled, which it already reads as right after `wsl --install`, before the restart.
# Trade-off: the vmcompute service (as in WindowsDeveloperConfig's steps/wsl.ps1) would be a cheaper query, but
# checked 2026-11-17 in the test VM it doesn't exist until after the restart (then it's there and Stopped, in
# Windows PowerShell 5.1 and pwsh 7 alike). Used here, a run before that restart would read the feature as
# missing and run `wsl --install` again, and restart Windows again. The query took 1.0s in that run, so it isn't
# the slow step. Revisit if it's measured slow.
# Keep in step with Test-Prerequisites in dsc/resources/wsldistribution.ps1
function Test-VirtualMachinePlatform {
    (Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'").InstallState -eq 1
}

# The installed WSL's version, or nothing. Read from the file version of the package's own wsl.exe, and nothing is
# run: the inbox wsl.exe in System32, on a machine without the WSL package, prints "The Windows Subsystem for
# Linux is not installed" and waits 60s for a key press that would install it (seen on a fresh install,
# 2026-11-17: that was a 60.0s `wsl.exe --version`). The package's file doesn't exist until WSL is installed.
# Checked 2026-11-17 in the test VM, before and after `wsl --install`: Program Files\WSL\wsl.exe is absent, then
# present with ProductVersion 3.0.5.0, the same number as the uninstall entry, winget and the Appx package.
# A WSL installed somewhere else, such as a Store package, has no file there, so the package registration is the
# second source: its key under AppxAllUserStore is named <name>_<version>_<arch>__<publisher>. Read from the
# registry rather than Get-AppxPackage, which needs the Appx module (a compatibility layer in pwsh 7: 0.28s
# against 0.03s here) and elevation for -AllUsers. Checked 2026-11-17 on iris only: key
# MicrosoftCorporationII.WindowsSubsystemForLinux_3.0.5.0_x64__8wekyb3d8bbwe, readable unelevated. Not yet
# checked in the test VM; the file check is the one that was.
# Keep in step with Test-Prerequisites in dsc/resources/wsldistribution.ps1
function Get-WslVersion {
    $wsl = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (Test-Path -Path $wsl) {
        if ("$((Get-Item -LiteralPath $wsl).VersionInfo.ProductVersion)" -match '^(\d+\.\d+\.\d+)') { [version]$Matches[1] }
        return
    }
    $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
    $package = Get-ChildItem -Path $store -Name -ErrorAction SilentlyContinue |
        Where-Object { $_ -like 'MicrosoftCorporationII.WindowsSubsystemForLinux_*' } | Select-Object -First 1
    if ($package -and $package -match '_(\d+\.\d+\.\d+)(\.\d+)?_') { [version]$Matches[1] }
}

# Each query once per look, since the script used to repeat the CIM query and the version check several times
# before installing anything. Taken again only after wsl.exe has changed something.
function Get-WslState {
    $vmp = Test-VirtualMachinePlatform
    $version = Get-WslVersion
    [pscustomobject]@{ Vmp = [bool]$vmp; Version = $version; Ready = [bool]($vmp -and $version -and $version -ge $minimum) }
}

# Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on
# build 26300); only this key shows that the restart is still to come
function Test-RestartPending {
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

# Virtual Machine Platform starts the hypervisor at boot, and WSL 2 runs in it. With virtualization off in the
# firmware, or not passed through to a VM, the feature still reads as enabled and WSL as installed, and only
# installing a distribution fails, so check this once no restart is pending. Another restart wouldn't help.
function Assert-Hypervisor {
    if (-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
        throw 'Virtual Machine Platform is enabled, but no hypervisor is running, so WSL 2 can''t start, and restarting again won''t help. Turn on virtualization (Intel VT-x or AMD-V) in the BIOS/UEFI settings; in a Hyper-V VM, turn on nested virtualization (Set-VMProcessor -ExposeVirtualizationExtensions $true) while the VM is off.'
    }
}

function Exit-RestartPending([string]$Done) {
    Write-Warning "${Done}Windows has a restart pending. Restart. install.cmd then continues after you sign in and press Enter; after any other install command, run it again."
    Write-WinfilesLog wsl 'install stopped for a restart: restart Windows. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again'
    exit 3010
}

# Still exits with 3010, so `just install` doesn't start DSC while Windows shuts down
function Restart-AfterInstall {
    Write-Warning 'WSL installed. Windows has a restart pending. Restarting in 30 seconds, or press Ctrl+C to restart later. install.cmd then continues after you sign in and press Enter; after any other install command, run it again.'
    Write-WinfilesLog wsl 'install stopped: restarting Windows in 30 seconds. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again'
    Start-Sleep -Seconds 30
    try {
        # No -Force: an app holding unsaved work can still stop the restart
        Restart-Computer
    } catch {
        Exit-RestartPending "Restarting failed ($_). "
    }
    exit 3010
}

function Invoke-WslElevated([string[]]$WslArgs) {
    Write-WinfilesLog wsl "running wsl.exe $WslArgs"
    if ($isAdmin) {
        & wsl.exe @WslArgs | Out-Host
        $exitCode = $LASTEXITCODE
    } else {
        # Runs in its own elevated console window
        Write-WinfilesLog wsl 'asking for UAC: wsl.exe installs or updates WSL and enables Virtual Machine Platform, in its own window'
        $exitCode = (Start-Process wsl.exe -ArgumentList $WslArgs -Verb RunAs -Wait -PassThru).ExitCode
    }
    # Windows Installer codes for success: 3010 with a restart required, 1641 with the restart already started
    if ($exitCode -eq 1641) {
        Write-Warning "wsl.exe $WslArgs has started a restart. install.cmd then continues after you sign in and press Enter; after any other install command, run it again."
        Write-WinfilesLog wsl "install stopped: wsl.exe $WslArgs has started a restart. install.cmd then continues after sign-in, once Enter is pressed; after any other install command, run it again"
        exit 3010
    }
    if ($exitCode -notin 0, 3010) {
        throw "wsl.exe $WslArgs exited with code $exitCode"
    }
}

Write-WinfilesLog wsl 'checking WSL and Virtual Machine Platform'
$state = Get-WslState
if ($state.Ready) {
    if (Test-RestartPending) { Exit-RestartPending "WSL $($state.Version) installed and Virtual Machine Platform enabled, but " }
    Assert-Hypervisor
    Write-WinfilesLog wsl "WSL $($state.Version) installed and Virtual Machine Platform enabled, skipping"
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
# `wsl --install` isn't known to update an older WSL package (not yet checked in the test VM), so update it
# explicitly; the inbox wsl.exe, with no package, has no version
if ($state.Version -and $state.Version -lt $minimum) { Invoke-WslElevated '--update' }
$installed = -not $state.Version -or -not $state.Vmp
if ($installed) { Invoke-WslElevated '--install', '--no-distribution' }

if (Test-RestartPending) {
    # Only a restart this run caused: on a machine that already had WSL, it may be Windows Update's, and open work
    if ($installed) { Restart-AfterInstall }
    Exit-RestartPending 'WSL updated. '
}
$state = Get-WslState
if (-not $state.Ready) {
    $found = if ($state.Version) { "WSL $($state.Version)" } else { 'only the inbox WSL' }
    $feature = if ($state.Vmp) { 'enabled' } else { 'not enabled' }
    throw "wsl.exe finished, but WSL still isn't ready, and no restart is pending: this machine has $found (2.4.4 or later is needed), and Virtual Machine Platform is $feature."
}
Assert-Hypervisor
Write-WinfilesLog wsl "done: WSL $($state.Version) installed and Virtual Machine Platform enabled"
exit 0
