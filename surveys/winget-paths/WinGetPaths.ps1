# Shared by winget-paths.Tests.ps1 and Clear-WinGetPaths.ps1, which dot-source it: the packages the suite installs and
# the checks both need. Nothing here changes the machine.

# Picked with `winget show --scope user|machine` on iris, 2026-11-17
function Get-WinGetPathPackage {
    @{ Case = 'machine-only'; Id = 'WinDirStat.WinDirStat'; HasUser = $false }        # WiX MSI, machine only
    @{ Case = 'both'; Id = 'SumatraPDF.SumatraPDF'; HasUser = $true }                 # one exe for either scope
    @{ Case = 'user-only'; Id = 'Element.Element'; HasUser = $true; Stop = 'Element' } # Squirrel; starts the app
    # MSIX that declares Microsoft.UI.Xaml.2.6, which Install-WinGetPackage failed to install as a dependency
    # (0x8A150110, winget 1.29.380, 2026-11-03)
    @{ Case = 'dependency'; Id = 'AndrewAlanBabbitt.ChromaControl'; HasUser = $true; Also = 'Microsoft.UI.Xaml.2.6' }
    @{ Case = 'bogus'; Id = 'Winfiles.DoesNotExist'; HasUser = $true; Bogus = $true }
}

# Every id the suite can leave installed, dependents before what they depend on
function Get-WinGetPathId {
    $packages = Get-WinGetPathPackage | Where-Object { -not $_.Bogus }
    @($packages.Id) + @($packages | Where-Object Also | ForEach-Object Also)
}

# These install and uninstall real packages, so anything but a Hyper-V guest is refused
function Assert-TestVm {
    $computer = Get-CimInstance Win32_ComputerSystem
    if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
        throw "This installs and uninstalls real packages, so it only runs in a Hyper-V test VM (this machine: $($computer.Manufacturer), $($computer.Model))"
    }
}

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# user, machine, or $null when winget lists it in neither scope
function Get-InstalledScope([string]$Id) {
    foreach ($scope in 'user', 'machine') {
        winget list --id $Id --exact --source winget --scope $scope --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { return $scope }
    }
}
