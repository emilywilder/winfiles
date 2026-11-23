# Shared by the Winfiles.Wsl/Wsl and Winfiles.Wsl/Distribution scripts, which dot-source it: what WSL 2 needs on
# this machine, read without running wsl.exe or needing elevation.


function Test-RestartPending {
    <#
    .SYNOPSIS
    Tests whether component servicing has a restart pending.

    .DESCRIPTION
    Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on build
    26300); only the servicing key shows that the restart is still to come.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $servicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    Test-Path -Path $servicing
}


function Test-VirtualMachinePlatform {
    <#
    .SYNOPSIS
    Tests whether the Virtual Machine Platform feature is enabled.

    .DESCRIPTION
    CIM reads the feature without elevation, unlike Microsoft.Windows/OptionalFeatureList. The vmcompute service
    would be a cheaper query, but it doesn't exist until after the restart (checked 2026-11-17 in the test VM).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'"
    $feature.InstallState -eq 1
}


function Test-Hypervisor {
    <#
    .SYNOPSIS
    Tests whether a hypervisor is running, which WSL 2 runs in.

    .DESCRIPTION
    Virtual Machine Platform starts the hypervisor at boot. With virtualization off in the firmware, or not passed
    through to a VM, the feature still reads as enabled and WSL as installed, and only installing a distribution
    fails.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool](Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
}


function Get-WslVersion {
    <#
    .SYNOPSIS
    Returns the installed WSL's version, or nothing, without running wsl.exe.

    .DESCRIPTION
    Reads the file version of the package's own wsl.exe. The inbox wsl.exe in System32, on a machine without the
    WSL package, waits 60s for a key press that would install it (seen on a fresh install, 2026-11-17). A WSL
    installed elsewhere, such as a Store package, has only its registration in AppxAllUserStore, named
    <name>_<version>_<arch>__<publisher>; read from the registry rather than Get-AppxPackage, which needs
    elevation for -AllUsers.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param()

    $wsl = Join-Path -Path $env:ProgramFiles -ChildPath 'WSL\wsl.exe'
    if (Test-Path -Path $wsl) {
        if ("$((Get-Item -LiteralPath $wsl).VersionInfo.ProductVersion)" -match '^(\d+\.\d+\.\d+)') {
            [version]$Matches[1]
        }
    } else {
        $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
        $package = Get-ChildItem -Path $store -Name -ErrorAction SilentlyContinue |
            Where-Object -FilterScript { $_ -like 'MicrosoftCorporationII.WindowsSubsystemForLinux_*' } |
            Select-Object -First 1
        if ($package -and $package -match '_(\d+\.\d+\.\d+)(\.\d+)?_') {
            [version]$Matches[1]
        }
    }
}
