# A stand-in for Microsoft.WinGet.Client, with just the two cmdlets Winfiles/WinGetPackageList uses.
# Tests put this folder first on PSModulePath, so a resource run in a child pwsh imports this instead.
# State lives in the JSON file named by $env:WINFILES_FAKE_WINGET (written by New-FakeWinGet in tests/resources/Resource.ps1):
#   installed: [{ Id, Source }]   what Get-WinGetPackage lists; a successful install adds to it
#   failing:   { <id>: <status> } ids whose install returns that status instead of Ok
#   unknown:   [<id>]             ids whose install throws, as the real cmdlet does for an id with no match
#   installs:  [{ Id, Source, Scope, Mode, MatchOption }]   every Install-WinGetPackage call, in order
# Without the variable it throws, so it can never pass for the real module by doing nothing.

# A module doesn't inherit the caller's preferences, so a missing state file would otherwise read as nothing installed
$ErrorActionPreference = 'Stop'

function Read-FakeState {
    if (-not $env:WINFILES_FAKE_WINGET) { throw 'Fake Microsoft.WinGet.Client loaded without WINFILES_FAKE_WINGET' }
    Get-Content -Raw $env:WINFILES_FAKE_WINGET | ConvertFrom-Json
}

function Get-WinGetPackage {
    @((Read-FakeState).installed) | Where-Object { $_ }
}

function Install-WinGetPackage {
    param([string]$Id, [string]$Source, [string]$MatchOption, [string]$Mode, [string]$Scope)
    $state = Read-FakeState
    $state.installs = @($state.installs) + [pscustomobject]@{
        Id = $Id; Source = $Source; Scope = $Scope; Mode = $Mode; MatchOption = $MatchOption
    }
    $status = if ($Id -in @($state.unknown)) { $null } elseif ($state.failing.$Id) { $state.failing.$Id } else { 'Ok' }
    if ($status -eq 'Ok') { $state.installed = @($state.installed) + [pscustomobject]@{ Id = $Id; Source = $Source } }
    $state | ConvertTo-Json -Depth 4 | Set-Content $env:WINFILES_FAKE_WINGET
    if (-not $status) { throw "No packages found matching input criteria: $Id" }
    [pscustomobject]@{
        Id                = $Id
        Status            = $status
        ExtendedErrorCode = if ($status -ne 'Ok') { [Exception]::new('fake installer failure') }
    }
}

Export-ModuleMember -Function Get-WinGetPackage, Install-WinGetPackage
