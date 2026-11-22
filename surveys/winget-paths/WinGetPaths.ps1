# Shared by winget-paths.Tests.ps1, Clear-WinGetPath.ps1 and Install-WinGetPathCase.ps1, which dot-source it: the
# packages the suite installs and the checks they need. Nothing here changes the machine.


function Get-WinGetPathPackage {
    <#
    .SYNOPSIS
    Returns the survey's packages, each with its case, id, whether it has a per-user installer, and the scope
    winget picks for it.

    .DESCRIPTION
    Picked with `winget show --scope user|machine` on iris, 2026-11-17. Picks is the scope winget chose with none
    given, on every path in both contexts (winget 1.29.380, 2026-11-17).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{ Case = 'machine-only'; Id = 'WinDirStat.WinDirStat'; HasUser = $false; Picks = 'machine' }   # WiX MSI
    # one exe for either
    @{ Case = 'both'; Id = 'SumatraPDF.SumatraPDF'; HasUser = $true; Picks = 'user' }
    # Home-list packages with both scopes: gh is a portable zip per user and a WiX MSI per machine; VS Code has
    # separate user and system Inno installers; Obsidian has one Nullsoft exe for both
    @{ Case = 'both-zip-or-msi'; Id = 'GitHub.cli'; HasUser = $true; Picks = 'machine' }
    @{ Case = 'both-inno'; Id = 'Microsoft.VisualStudioCode'; HasUser = $true; Picks = 'user'; Stop = 'Code' }
    @{ Case = 'both-nullsoft'; Id = 'Obsidian.Obsidian'; HasUser = $true; Picks = 'user'; Stop = 'Obsidian' }
    @{ Case = 'user-only'; Id = 'Element.Element'; HasUser = $true; Picks = 'user'; Stop = 'Element' } # Squirrel
    # MSIX that declares Microsoft.UI.Xaml.2.6, which Install-WinGetPackage failed to install as a dependency
    # (0x8A150110, winget 1.29.380, 2026-11-03)
    @{
        Case    = 'dependency'
        Id      = 'AndrewAlanBabbitt.ChromaControl'
        HasUser = $true
        Picks   = 'user'
        Also    = 'Microsoft.UI.Xaml.2.6'
    }
    @{ Case = 'bogus'; Id = 'Winfiles.DoesNotExist'; HasUser = $true; Bogus = $true }
}


function Get-WinGetPathId {
    <#
    .SYNOPSIS
    Returns every id the suite can leave installed, dependents before what they depend on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $packages = Get-WinGetPathPackage | Where-Object -FilterScript { -not $_.Bogus }
    @($packages.Id) + @($packages | Where-Object -FilterScript { $_.Also } | ForEach-Object -Process { $_.Also })
}


function Assert-TestVm {
    <#
    .SYNOPSIS
    Throws unless this is a Hyper-V guest, since the survey installs and uninstalls real packages.
    #>
    [CmdletBinding()]
    param()

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
        throw ('This installs and uninstalls real packages, so it only runs in a Hyper-V test VM ' +
            "(this machine: $($computer.Manufacturer), $($computer.Model))")
    }
}


function Test-Elevated {
    <#
    .SYNOPSIS
    Tests whether this process holds an administrator's elevated token.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


function Get-InstalledScope {
    <#
    .SYNOPSIS
    Returns the scope winget lists a package in: user, machine, or nothing when it's in neither.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The package's id.
        [Parameter(Mandatory)]
        [string]$Id
    )

    $found = $null
    foreach ($scope in 'user', 'machine') {
        $list = @('list', '--id', $Id, '--exact', '--source', 'winget', '--scope', $scope)
        winget @list --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $found = $scope
            break
        }
    }
    $found
}
