# Shared by winget-paths.Tests.ps1 and Clear-WinGetPaths.ps1, which dot-source it: the packages the suite installs and
# the checks both need. Nothing here changes the machine.

# Picked with `winget show --scope user|machine` on iris, 2026-11-17. Picks is the scope winget chose with none given,
# on every path in both contexts (winget 1.29.380, 2026-11-17)
function Get-WinGetPathPackage {
    @{ Case = 'machine-only'; Id = 'WinDirStat.WinDirStat'; HasUser = $false; Picks = 'machine' }   # WiX MSI
    @{ Case = 'both'; Id = 'SumatraPDF.SumatraPDF'; HasUser = $true; Picks = 'user' }               # one exe for either
    # Home-list packages with both scopes: gh is a portable zip per user and a WiX MSI per machine; VS Code has separate
    # user and system Inno installers; Obsidian has one Nullsoft exe for both
    @{ Case = 'both-zip-or-msi'; Id = 'GitHub.cli'; HasUser = $true; Picks = 'machine' }
    @{ Case = 'both-inno'; Id = 'Microsoft.VisualStudioCode'; HasUser = $true; Picks = 'user'; Stop = 'Code' }
    @{ Case = 'both-nullsoft'; Id = 'Obsidian.Obsidian'; HasUser = $true; Picks = 'user'; Stop = 'Obsidian' }
    @{ Case = 'user-only'; Id = 'Element.Element'; HasUser = $true; Picks = 'user'; Stop = 'Element' } # Squirrel
    # MSIX that declares Microsoft.UI.Xaml.2.6, which Install-WinGetPackage failed to install as a dependency
    # (0x8A150110, winget 1.29.380, 2026-11-03)
    @{
        Case = 'dependency'; Id = 'AndrewAlanBabbitt.ChromaControl'; HasUser = $true; Picks = 'user'
        Also = 'Microsoft.UI.Xaml.2.6'
    }
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
        throw ('This installs and uninstalls real packages, so it only runs in a Hyper-V test VM ' +
            "(this machine: $($computer.Manufacturer), $($computer.Model))")
    }
}

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# user, machine, or $null when winget lists it in neither scope
function Get-InstalledScope([string]$Id) {
    foreach ($scope in 'user', 'machine') {
        winget list --id $Id --exact --source winget --scope $scope --accept-source-agreements `
            --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { return $scope }
    }
}
